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

    let windowPreviews: WindowContentPreview
    public func stopWindowContentPreview() {
        windowPreviews.currentDesktop?.invalidate()
        windowPreviews.gallery.clear(); windowPreviews.clear()
    }
    /// Aggregate counters only. Reading this snapshot cannot request pixels or operate windows.
    public var windowPreviewMetrics: [String: NSNumber] {
        let gallery = windowPreviews.gallery
        return ["captureRequests": NSNumber(value: gallery.captureRequests + windowPreviews.pickerCaptureRequests),
                "capturesInFlight": NSNumber(value: gallery.capturesInFlight + windowPreviews.pickerInFlight),
                "cacheEntries": NSNumber(value: windowPreviews.cacheCount),
                "chargedPixelBytes": NSNumber(value: windowPreviews.cacheBytes),
                "activeStreams": 0] // Both capture paths use SCScreenshotManager one-shots.
    }
    public func desktopWindowsChanged() { windowPreviews.currentDesktop?.changed() }

    @MainActor public func updateRelaunchBlock() async -> String? {
        #if canImport(NearpaneVoice)
        if await tray.updateRequiresTrayToFinish() { return "请等待截图或草稿附加操作结束，再继续安装。" }
        if voice.updateRequiresVoiceToFinish { return "请先暂停收音，并等待语音处理或播放结束，再继续安装。" }
        #endif
        if workRect?.updateRequiresManagementToFinish == true {
            return "请在窗口管理中停止管理并完成恢复，再继续安装。"
        }
        return nil
    }

    public let workRect: CandidateWorkRect?
    public let candidate: Bool
    public init(support: URL, testSession: URL? = nil, candidate: Bool = false, boundDraft: Bool = false) {
        windowPreviews = WindowContentPreview(readOverview: testSession == nil ? NativeDesktopProvider.packagedReader(overview: true) : nil,
            permitsGalleryWindow: { _ in testSession == nil })
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
        var result: [String: @MainActor () -> any HostModule] = [:]
        #if canImport(NearpaneVoice)
        result[BuiltinCatalog.screenshots] = { [tray] in tray }
        result[BuiltinCatalog.voice] = { [voice] in voice }
        #endif
        return result
    }

    public func makeHost(store: any ConfigurationStore, provider: any DesktopObservationProvider = UnavailableDesktopProvider()) -> HostSession {
        let host = HostSession(store: store, provider: provider, includeSampleModules: !candidate, coreFactories: factories)
        workRect?.connect(to: host)
        if let feed = windowPreviews.currentDesktop { workRect?.desktopTiling.connect(feed) }
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
        await workRect?.finish()
        stopWindowContentPreview()
        #if canImport(NearpaneVoice)
        await voice.waitForTransition()
        await tray.finishStopping()
        #endif
    }
}
