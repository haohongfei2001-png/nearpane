import Foundation

/// Use the pinned domain engine and its no-prompt Keychain implementation, scoped
/// to one Nearpane profile. The standalone application's accounts stay separate.
public struct NearpaneVoiceCredentials: Sendable {
    private let store: KeychainCredentialStore

    public init(profileID: String) {
        store = KeychainCredentialStore(service: "com.holdsnow.nearpane.voice.byok.v1." + profileID)
    }

    public func save(_ secret: String, for model: ModelConfiguration) throws {
        try store.save(secret, configurationID: model.id, provider: model.provider)
    }
    public func remove(_ model: ModelConfiguration) throws {
        try store.delete(configurationID: model.id, provider: model.provider)
    }
    public func presence(_ model: ModelConfiguration) -> CloudCredentialPresence {
        store.presence(configurationID: model.id, provider: model.provider)
    }

    @MainActor public func controller(store recordings: SaytileStore, configuration: RecognitionConfiguration) -> AudioController {
        var dependencies = RecognitionPipelineDependencies.live
        dependencies.credential = { [store] model in
            try store.read(configurationID: model.id, provider: model.provider)
        }
        let factory = RecognitionSessionFactory(configuration: configuration, dependencies: dependencies)
        return AudioController(store: recordings, recognitionFactory: factory)
    }
}
