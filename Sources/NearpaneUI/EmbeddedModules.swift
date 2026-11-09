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

    public let workRect: CandidateWorkRect?
    public let candidate: Bool
    public init(support: URL, testSession: URL? = nil, candidate: Bool = false, boundDraft: Bool = false) {
        self.candidate = candidate
        workRect = candidate && testSession == nil ? CandidateWorkRect(support: support.deletingLastPathComponent()) : nil
        #if canImport(NearpaneVoice)
        voicePasteboard = testSession.map { NSPasteboard(name: .init("com.holdsnow.nearpane.acceptance." + $0.lastPathComponent)) } ?? .general
        tray = TrayModule(existingRoot: support.deletingLastPathComponent().appendingPathComponent("Riftlet", isDirectory: true), testSession: testSession, localOnly: candidate && !(boundDraft && testSession != nil))
        voice = VoiceModule(directory: support.appendingPathComponent("Voice", isDirectory: true), requireExistingPermissions: testSession != nil)
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
        let host = HostSession(store: store, provider: provider, coreFactories: factories)
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
        #if canImport(NearpaneVoice)
        await voice.waitForTransition()
        await tray.finishStopping()
        #endif
    }
}
