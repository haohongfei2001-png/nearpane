import AppKit
import ApplicationServices
import NaturalLanguage
import NearpaneCore
import SwiftUI
#if canImport(Translation)
import Translation
#endif

struct TranslationResultContent: View {
    let text: String
    let request: UUID

    var body: some View {
        Text(text).font(.system(size: 14)).padding(10)
            .frame(maxWidth: 280).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("nearpane-translation-content-" + request.uuidString)
    }
}

@MainActor public final class SelectionTranslation: NSObject {
    private let inbox: TranslationInbox
    private var notebook: SidebarNotebook?
    private var generation: UUID?
    private var worker: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?
    private var bubble: NSPanel?
    private struct PresentationContext {
        let origin: TranslationSelectionOrigin?
        let feedback: TranslationFeedbackPointer?
        @MainActor var foreground: SelectionForeground? { origin?.owner ?? feedback?.foreground }
    }
    private var presentations = [UUID: PresentationContext]()
    private var visibleForeground: SelectionForeground?
    private var visibleRequest: UUID?
    private var feedbackWatch: Task<Void, Never>?
    private var binding = UUID()

    public init(support: URL) { inbox = TranslationInbox(support: support) }

    public func register() {
        NSApp.servicesProvider = self
        LocalToolStage.serviceRegistered.emit(binding)
    }

    func bind(notebook: SidebarNotebook, generation: UUID) {
        detach()
        self.notebook = notebook
        self.generation = generation
        if let prior = notebook.contents.words.first, let id = prior.requestID, let saved = try? notebook.diskWord(for: id) {
            LocalToolStage.wordReopened.emit(id, hash: LocalToolStage.digest(Data(saved.translation.utf8)))
        }
        drain()
    }

    func detach() {
        binding = UUID()
        worker?.cancel(); worker = nil
        dismissal?.cancel(); dismissal = nil
        if generation != nil { presentations.removeAll() }
        close()
        notebook = nil; generation = nil
    }

    @objc public func translateNearpaneSelection(_ pasteboard: NSPasteboard, userData: String?,
                                                error outputError: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let peer = TranslationCaller.atCallback(to: self)
        guard let source = pasteboard.string(forType: .string) else {
            outputError.pointee = "请选择文字后再查询。" as NSString; return
        }
        let pointer = TranslationFeedbackPointer.capture()
        do {
            let request = try TranslationRequest(source, generation: inbox.target())
            LocalToolStage.serviceCallback.emit(request.id, hash: request.hash)
            try inbox.append(request)
            LocalToolStage.requestQueued.emit(request.id, hash: request.hash)
            let origin = peer.flatMap { TranslationSelectionOrigin.capture(peer: $0, source: source) }
            presentations[request.id] = .init(origin: origin, feedback: pointer)
            if origin != nil {
                LocalToolStage.serviceOriginBound.emit(request.id)
            } else {
                (peer == nil ? LocalToolStage.serviceCallerUnverified : .serviceSelectionUnverified).emit(request.id)
                if pointer == nil { LocalToolStage.feedbackPointerUnavailable.emit(request.id) }
            }
            drain()
        } catch { outputError.pointee = "无法保存翻译请求。请选择不超过 64 KiB 的文字，并核对资料目录。" as NSString }
    }

    private func drain() {
        guard worker == nil, let notebook, let generation else { return }
        let epoch = binding
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if binding == epoch { worker = nil } }
            while !Task.isCancelled, binding == epoch, let next = try? inbox.pending(for: generation).first {
                LocalToolStage.hostReceived.emit(next.id, hash: next.hash)
                if let saved = try? notebook.diskWord(for: next.id) {
                    LocalToolStage.wordReopened.emit(next.id, hash: LocalToolStage.digest(Data(saved.translation.utf8)))
                } else if !(await process(next, notebook: notebook)) { return }
                guard !Task.isCancelled, epoch == binding else { return }
                do { try inbox.finish(next) } catch { return }
                presentations.removeValue(forKey: next.id)
            }
        }
    }

    func waitForRequests() async { await worker?.value }

    private func process(_ request: TranslationRequest, notebook: SidebarNotebook) async -> Bool {
        var consumed = true
        let id = request.id
        func present(_ text: String) {
            if let context = presentations[id], let origin = context.origin,
               let placement = origin.placement(for: request.source, pointer: context.feedback) {
                let rect: NSRect, pointer: TranslationFeedbackPointer?
                switch placement {
                case .selection(let selected):
                    rect = selected
                    pointer = nil
                    LocalToolStage.anchorSelection.emit(id)
                case .pointer(let point):
                    rect = NSRect(origin: point, size: NSSize(width: 1, height: 1))
                    pointer = context.feedback
                    LocalToolStage.anchorPointer.emit(id)
                }
                show(text, at: rect, id: id, foreground: origin.owner, feedback: pointer)
                return
            }
            if let context = presentations[id], context.origin == nil,
               let pointer = context.feedback, TranslationFeedbackPointer.capture() == pointer {
                LocalToolStage.anchorFeedbackPointer.emit(id)
                show(text, at: NSRect(origin: pointer.point, size: NSSize(width: 1, height: 1)),
                     id: id, foreground: pointer.foreground, feedback: pointer)
                return
            }
            if presentations.removeValue(forKey: id)?.feedback != nil { LocalToolStage.feedbackPointerRevoked.emit(id) }
            close()
            LocalToolStage.panelUnavailable.emit(id)
        }
        dismissal?.cancel()
        present("正在查询…")
        let detectedLanguage = NLLanguageRecognizer.dominantLanguage(for: request.source)?.rawValue
        let language = detectedLanguage ?? "en"
        let target = language.hasPrefix("zh") ? "en" : "zh-Hans"
        func modelUnavailable(_ stage: LocalToolStage, message: String) {
            stage.emit(id)
            if let detectedLanguage, let saved = notebook.savedTranslation(for: request.source, from: detectedLanguage, to: target) {
                LocalToolStage.savedWordMatched.emit(id)
                present("单词本 · 已保存的译文\n" + saved)
            } else { present(message) }
        }
        #if canImport(Translation)
        if #available(macOS 26, *) {
            let from = Locale.Language(identifier: language), to = Locale.Language(identifier: target)
            let available = await LanguageAvailability().status(from: from, to: to)
            guard !Task.isCancelled else { return false }
            switch available {
            case .installed:
                LocalToolStage.modelInstalled.emit(id)
                do {
                    let translated = try await TranslationSession(installedSource: from, target: to).translate(request.source).targetText
                    try Task.checkCancellation()
                    guard !translated.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    let hash = LocalToolStage.digest(Data(translated.utf8))
                    LocalToolStage.translated.emit(id, hash: hash)
                    let system = ProcessInfo.processInfo.operatingSystemVersion
                    let framework = Bundle(identifier: "com.apple.Translation")?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                    let version = "Apple.Translation/" + (framework ?? "macOS-\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")
                    do {
                        _ = try notebook.commit(request, answer: translated, from: language, to: target, provider: version)
                        LocalToolStage.wordCommitted.emit(id, hash: hash)
                        present(translated)
                    } catch { consumed = false; present(translated + "\n单词本保存失败") }
                } catch {
                    guard !Task.isCancelled else { return false }
                    LocalToolStage.translationFailed.emit(id)
                    present("本机翻译未完成。")
                }
            case .supported:
                modelUnavailable(.modelMissing, message: "请先在 macOS 翻译设置中下载所需语言。")
            default:
                modelUnavailable(.modelUnsupported, message: "当前系统不支持这组语言的本地翻译。")
            }
        } else { modelUnavailable(.modelUnsupported, message: "当前系统不支持本地翻译。") }
        #else
        modelUnavailable(.modelUnsupported, message: "当前系统不支持本地翻译。")
        #endif
        guard !Task.isCancelled else { return false }
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.close()
        }
        return consumed
    }

    /// Workspace notifications only revoke proofs. A previously frontmost app never becomes a requester.
    public func foregroundChanged(to pid: pid_t?) {
        guard !presentations.isEmpty || visibleForeground != nil else { return }
        let now = SelectionForeground.read(pid)
        presentations = presentations.filter { id, context in
            if context.foreground == now { return true }
            if context.feedback != nil { LocalToolStage.feedbackPointerRevoked.emit(id) }
            return false
        }
        if visibleForeground != now { close() }
    }
    public func invalidateSelectionContext() {
        presentations.removeAll()
        close()
    }

    private func show(_ text: String, at rect: NSRect, id: UUID, foreground: SelectionForeground,
                      feedback: TranslationFeedbackPointer? = nil) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) else { LocalToolStage.panelUnavailable.emit(id); close(); return }
        let view = NSHostingView(rootView: TranslationResultContent(text:text, request:id))
        let size = view.fittingSize
        let visible = screen.visibleFrame
        guard size.width <= visible.width, size.height <= visible.height else { LocalToolStage.panelUnavailable.emit(id); close(); return }
        let x = min(max(rect.minX, visible.minX), visible.maxX - size.width)
        let below = rect.minY - size.height - 5
        let preferredY = below >= visible.minY ? below : rect.maxY + 5
        let y = min(max(preferredY, visible.minY), visible.maxY - size.height)
        let panel = bubble ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true; panel.hidesOnDeactivate = true; panel.level = .popUpMenu; panel.ignoresMouseEvents = true
        guard SelectionForeground.read(NSWorkspace.shared.frontmostApplication?.processIdentifier) == foreground,
              feedback == nil || TranslationFeedbackPointer.capture() == feedback else {
            if feedback != nil { LocalToolStage.feedbackPointerRevoked.emit(id) }
            presentations.removeValue(forKey: id)
            close()
            LocalToolStage.panelUnavailable.emit(id)
            return
        }
        feedbackWatch?.cancel()
        panel.contentView = view
        panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: true)
        bubble = panel
        visibleForeground = foreground
        visibleRequest = id
        panel.orderFrontRegardless()
        if panel.isVisible, panel.windowNumber > 0, !panel.isKeyWindow, panel.styleMask.contains(.nonactivatingPanel), visible.intersects(panel.frame) {
            let content = LocalToolStage.digest(Data(text.utf8))
            let receipt = "panel-v1|\(id.uuidString)|\(getpid())|\(panel.windowNumber)|\(content)"
            LocalToolStage.panelVisible.emit(id, hash: LocalToolStage.digest(Data(receipt.utf8)))
        }
        else { LocalToolStage.panelUnavailable.emit(id) }
        if let feedback {
            // Only metadata is sampled, and only during this brief user-requested panel.
            feedbackWatch = Task { [weak self] in
                let deadline = ContinuousClock.now + .seconds(8)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(125)) } catch { return }
                    guard let self, visibleRequest == id else { return }
                    if TranslationFeedbackPointer.capture() != feedback {
                        LocalToolStage.feedbackPointerRevoked.emit(id)
                        presentations.removeValue(forKey: id)
                        close()
                        return
                    }
                    if ContinuousClock.now >= deadline { close(); return }
                }
            }
        }
    }

    func close() {
        feedbackWatch?.cancel()
        feedbackWatch = nil
        if let visibleRequest { LocalToolStage.panelUnavailable.emit(visibleRequest) }
        bubble?.orderOut(nil)
        bubble = nil
        visibleRequest = nil
        visibleForeground = nil
    }
}
