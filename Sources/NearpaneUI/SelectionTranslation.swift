import AppKit
import ApplicationServices
import NaturalLanguage
import NearpaneCore
import SwiftUI
#if canImport(Translation)
import Translation
#endif

@MainActor public final class SelectionTranslation: NSObject {
    private let inbox: TranslationInbox
    private var notebook: SidebarNotebook?
    private var generation: UUID?
    private var worker: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?
    private var bubble: NSPanel?
    private var liveOrigins = [UUID: NSRunningApplication]()
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
        if generation != nil { liveOrigins.removeAll() }
        close()
        notebook = nil; generation = nil
    }

    @objc public func translateNearpaneSelection(_ pasteboard: NSPasteboard, userData: String?,
                                                error outputError: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let source = pasteboard.string(forType: .string) else {
            outputError.pointee = "请选择文字后再查询。" as NSString; return
        }
        do {
            let request = try TranslationRequest(source, generation: inbox.target())
            LocalToolStage.serviceCallback.emit(request.id, hash: request.hash)
            try inbox.append(request)
            LocalToolStage.requestQueued.emit(request.id, hash: request.hash)
            if let origin = NSWorkspace.shared.frontmostApplication { liveOrigins[request.id] = origin }
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
                liveOrigins.removeValue(forKey: next.id)
            }
        }
    }

    func waitForRequests() async { await worker?.value }

    private func process(_ request: TranslationRequest, notebook: SidebarNotebook) async -> Bool {
        var consumed = true
        let id = request.id
        let hint = liveOrigins[id]
        func present(_ text: String) {
            guard let hint, !hint.isTerminated, NSWorkspace.shared.frontmostApplication == hint else { return }
            let exact = Self.selectionBounds(for: request.source, owner: hint.processIdentifier)
            guard !hint.isTerminated, NSWorkspace.shared.frontmostApplication == hint else { return }
            let anchor = exact ?? NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 1, height: 1))
            (exact == nil ? LocalToolStage.anchorPointer : .anchorSelection).emit(id)
            show(text, at: anchor, id: id)
        }
        dismissal?.cancel()
        present("正在查询…")
        #if canImport(Translation)
        if #available(macOS 26, *) {
            let language = NLLanguageRecognizer.dominantLanguage(for: request.source)?.rawValue ?? "en"
            let target = language.hasPrefix("zh") ? "en" : "zh-Hans"
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
                LocalToolStage.modelMissing.emit(id)
                present("请先在 macOS 翻译设置中下载所需语言。")
            default:
                LocalToolStage.modelUnsupported.emit(id)
                present("当前系统不支持这组语言的本地翻译。")
            }
        } else { LocalToolStage.modelUnsupported.emit(id); present("当前系统不支持本地翻译。") }
        #else
        LocalToolStage.modelUnsupported.emit(id); present("当前系统不支持本地翻译。")
        #endif
        guard !Task.isCancelled else { return false }
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.close()
        }
        return consumed
    }

    private static func selectionBounds(for text: String, owner: pid_t) -> NSRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.18)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        var actual: pid_t = 0
        guard AXUIElementGetPid(element, &actual) == .success, actual == owner else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.18)
        var selected: CFTypeRef?, range: CFTypeRef?, bounds: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              selected as? String == text,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success, let range,
              AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), !rect.isEmpty, let primary = NSScreen.screens.first else { return nil }
        return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private func show(_ text: String, at rect: NSRect, id: UUID) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) else { LocalToolStage.panelUnavailable.emit(id); close(); return }
        let view = NSHostingView(rootView: Text(text).font(.system(size: 14)).padding(10)
            .frame(maxWidth: 280).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("nearpane-translation-content-" + id.uuidString))
        let size = view.fittingSize
        let visible = screen.visibleFrame
        let x = min(max(rect.minX, visible.minX), visible.maxX - size.width)
        let below = rect.minY - size.height - 5
        let y = below >= visible.minY ? below : min(rect.maxY + 5, visible.maxY - size.height)
        let panel = bubble ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true; panel.hidesOnDeactivate = true; panel.level = .popUpMenu; panel.ignoresMouseEvents = true
        panel.contentView = view
        panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: true)
        bubble = panel
        panel.orderFrontRegardless()
        if panel.isVisible, panel.windowNumber > 0, !panel.isKeyWindow, panel.styleMask.contains(.nonactivatingPanel), visible.intersects(panel.frame) {
            let content = LocalToolStage.digest(Data(text.utf8))
            let receipt = "panel-v1|\(id.uuidString)|\(getpid())|\(panel.windowNumber)|\(content)"
            LocalToolStage.panelVisible.emit(id, hash: LocalToolStage.digest(Data(receipt.utf8)))
        }
        else { LocalToolStage.panelUnavailable.emit(id) }
    }

    func close() { bubble?.orderOut(nil); bubble = nil }
}
