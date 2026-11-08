import Foundation
import NearpaneCore
#if canImport(NearpaneVoice)
import NearpaneVoice
#endif

/// One object per domain, shared by the registry and the surface. Content never enters the Host bus.
@MainActor
public final class EmbeddedModules {
    #if canImport(NearpaneVoice)
    public let voice: VoiceModule
    #endif

    public init(support: URL) {
        #if canImport(NearpaneVoice)
        voice = VoiceModule(directory: support.appendingPathComponent("Voice", isDirectory: true))
        #endif
    }

    public var factories: [String: @MainActor () -> any HostModule] {
        var result: [String: @MainActor () -> any HostModule] = [:]
        #if canImport(NearpaneVoice)
        result[BuiltinCatalog.voice] = { [voice] in voice }
        #endif
        return result
    }

    public func finishStopping() async {
        #if canImport(NearpaneVoice)
        await voice.waitForTransition()
        #endif
    }
}
