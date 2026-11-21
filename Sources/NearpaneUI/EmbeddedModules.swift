import AppKit
import Foundation
import NearpaneCore
#if canImport(NearpaneVoice)
import NearpaneVoice
import NearpaneTray
import AppKit
#endif

/// One object per domain, shared by the registry and the surface. Content never enters the Host bus.
@MainActor
public final class EmbeddedModules {
    #if canImport(NearpaneVoice)
    public let voice: VoiceModule
    public let tray: TrayModule
    let voicePasteboard: NSPasteboard
    #endif

    let notebook: SidebarNotebook
    private weak var translation: SelectionTranslation?
    public func bindSelectionService(_ service: SelectionTranslation, generation: UUID) {
        translation = service
        service.bind(notebook: notebook, generation: generation)
    }
    var voiceCompact: Bool {
        #if canImport(NearpaneVoice)
        voice.panelIsCompact
        #else
        false
        #endif
    }
    var trayRowCount: Int {
        #if canImport(NearpaneTray)
        tray.rowCount
        #else
        1
        #endif
    }
    let windowPreviews: WindowContentPreview
    public func stopWindowContentPreview(spaceChanged: Bool = false, reason: String = "lifecycle") {
        windowPreviews.currentDesktop?.invalidate(preservingOriginalWindows: spaceChanged, reason: reason)
        windowPreviews.gallery.clear(); windowPreviews.clear()
    }
    /// Aggregate counters only. Reading this snapshot cannot request pixels or operate windows.
    public var windowPreviewMetrics: [String: NSNumber] {
        let gallery = windowPreviews.gallery
        return ["captureRequests": NSNumber(value: gallery.captureRequests + windowPreviews.pickerCaptureRequests),
                "capturesInFlight": NSNumber(value: gallery.capturesInFlight + windowPreviews.pickerInFlight),
                "cacheEntries": NSNumber(value: windowPreviews.cacheCount),
                "visibleDisplays": NSNumber(value: windowPreviews.visibleDisplays.count),
                "gallerySessions": NSNumber(value: gallery.activeCaptureLoops),
                "windowManagementBusy": NSNumber(value: workRect?.updateRequiresManagementToFinish ?? false),
                "chargedPixelBytes": NSNumber(value: windowPreviews.cacheBytes),
                "activeStreams": NSNumber(value: gallery.activeStreamCount),
                "deliveredFrames": NSNumber(value: gallery.deliveredFrameCount)]
    }
    public func desktopWindowsChanged() { windowPreviews.currentDesktop?.changed() }

    @MainActor public func updateRelaunchBlock() async -> String? {
        #if canImport(NearpaneVoice)
        if await tray.updateRequiresTrayToFinish() { return "请等待截图或草稿附加操作结束，再继续安装。" }
        if voice.updateRequiresVoiceToFinish { return "请先暂停收音，并等待语音处理或播放结束，再继续安装。" }
        #endif
        if windowPreviews.currentDesktop?.stageEngine.holdsDispatch == true {
            return "窗口可见性仍由当前会话持有，恢复读回后才可继续安装。"
        }
        if workRect?.updateRequiresManagementToFinish == true {
            return "请在窗口管理中停止管理并完成恢复，再继续安装。"
        }
        return nil
    }

    public let workRect: CandidateWorkRect?
    public let candidate: Bool
    public init(support: URL, testSession: URL? = nil, candidate: Bool = false, boundDraft: Bool = false) {
        notebook = SidebarNotebook(directory: support)
        windowPreviews = WindowContentPreview(readOverview: testSession == nil ? NativeDesktopProvider.packagedReader(overview: true) : nil,
            stageGroupProfile: support, permitsGalleryWindow: { _ in testSession == nil })
        self.candidate = candidate
        workRect = candidate ? CandidateWorkRect(support: support.deletingLastPathComponent()) : nil
        #if canImport(NearpaneVoice)
        voicePasteboard = testSession.map { NSPasteboard(name: .init("com.holdsnow.nearpane.acceptance." + $0.lastPathComponent)) } ?? .general
        tray = TrayModule(existingRoot: support.deletingLastPathComponent().appendingPathComponent("Riftlet", isDirectory: true), testSession: testSession, localOnly: testSession != nil && candidate && !boundDraft,
                         productAttachments: candidate && testSession == nil)
        voice = VoiceModule(directory: support.appendingPathComponent("Voice", isDirectory: true),
                            requireExistingPermissions: testSession != nil, allowAPISettings: candidate,
                            allowManualInsertion: candidate && testSession == nil)
        #endif
    }

    public var factories: [String: @MainActor () -> any HostModule] {
        var result: [String: @MainActor () -> any HostModule] = [
            BuiltinCatalog.memo: { NotebookModule() }, BuiltinCatalog.tasks: { NotebookModule() }
        ]
        #if canImport(NearpaneVoice)
        result[BuiltinCatalog.screenshots] = { [tray] in tray }
        result[BuiltinCatalog.voice] = { [voice] in voice }
        #endif
        return result
    }

    public func makeHost(store: any ConfigurationStore, provider: any DesktopObservationProvider = UnavailableDesktopProvider()) -> HostSession {
        let host = HostSession(store: store, provider: provider, includeSampleModules: !candidate, coreFactories: factories)
        workRect?.connect(to: host)
        if let feed = windowPreviews.currentDesktop {
            workRect?.desktopTiling.connect(feed)
            feed.stageEngine.management = workRect
            workRect?.stageEngine = feed.stageEngine
        }
        #if canImport(NearpaneVoice)
        voice.openingFailed = { [weak host, weak voice] in
            if let voice { host?.registry.reportFailure(BuiltinCatalog.voice, from: voice) }
        }
        #endif
        return host
    }

    public func setInteractionHidden(_ hidden: Bool) {
        #if canImport(NearpaneTray)
        tray.surfaceHidden(hidden)
        #endif
    }

    public func finishStopping() async {
        translation?.detach()
        await windowPreviews.currentDesktop?.stageEngine.release()
        await workRect?.finish()
        stopWindowContentPreview()
        #if canImport(NearpaneVoice)
        await voice.waitForTransition()
        await tray.finishStopping()
        #endif
    }
}
