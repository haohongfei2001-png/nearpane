import Foundation
import NearpaneCore
#if canImport(NearpaneVoice)
import NearpaneVoice
import NearpaneTray
#endif

/// One object per domain, shared by the registry and the surface. Content never enters the Host bus.
@MainActor
public final class EmbeddedModules {
    #if canImport(NearpaneVoice)
    public let voice: VoiceModule
    public let tray: TrayModule
    #endif

    public init(support: URL, testSession: URL? = nil) {
        #if canImport(NearpaneVoice)
        tray = TrayModule(existingRoot: support.deletingLastPathComponent().appendingPathComponent("Riftlet", isDirectory: true), testSession: testSession)
        voice = VoiceModule(directory: support.appendingPathComponent("Voice", isDirectory: true))
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

    public func makeHost(store: any ConfigurationStore) -> HostSession {
        let host = HostSession(store: store, provider: UnavailableDesktopProvider(), coreFactories: factories)
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
        #if canImport(NearpaneVoice)
        await voice.waitForTransition()
        await tray.finishStopping()
        #endif
    }
}
