import Foundation
import Testing
@testable import NearpaneVoice
import SaytileKit

private final class MemoryVoiceKeys: VoiceCredentialAccess {
    var values = [UUID: String]()
    var failFor: CloudProvider?
    var unavailable = false
    var presenceChecks = 0

    func save(_ secret: String, for model: ModelConfiguration) throws {
        if model.provider == failFor { throw CocoaError(.fileWriteNoPermission) }
        values[model.id] = secret
    }
    func remove(_ model: ModelConfiguration) throws { values.removeValue(forKey: model.id) }
    func presence(_ model: ModelConfiguration) -> CloudCredentialPresence {
        presenceChecks += 1
        return unavailable ? .unavailable(-1) : (values[model.id] == nil ? .missing : .saved)
    }
}

@MainActor struct VoiceRecognitionProfileTests {
    private func root() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(ProcessInfo.processInfo.environment["NEARPANE_TEST_DIRECTORY"] ?? ".build/test-data")
            .appendingPathComponent("voice-settings-" + UUID().uuidString)
    }

    @Test func newAndRestrictedHostsRemainLocalAndNeverInspectSavedKeys() throws {
        let dir = root()
        let keys = MemoryVoiceKeys()
        let profile = VoiceRecognitionProfile(directory: dir, credentials: keys)
        #expect(!profile.enabled && !profile.needsCleanup)
        #expect(try !profile.configurationForInput().cloudEnabled)
        #expect(keys.presenceChecks == 0 && keys.values.isEmpty)
        #expect(VoiceModule(directory: dir, requireExistingPermissions: true, allowAPISettings: true).recognitionProfile == nil)
        #expect(VoiceModule(directory: dir).recognitionProfile == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func invalidOrPartialConsentNeverPublishesAuthorizationAndPartialKeySavesAreRolledBack() throws {
        let dir = root()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryVoiceKeys()
        let profile = VoiceRecognitionProfile(directory: dir, credentials: keys)
        for (language, workspace, consent) in [(LanguagePreference.auto, "", true), (.chinese, "", true), (.english, "", false)] {
            #expect(throws: (any Error).self) {
                try profile.enable(language: language, workspace: workspace, region: "cn-beijing",
                                   expertKey: "test-expert", fusionKey: "test-fusion", consent: consent)
            }
        }
        keys.failFor = .openAIResponses
        #expect(throws: (any Error).self) {
            try profile.enable(language: .english, workspace: "", region: "",
                               expertKey: "test-expert", fusionKey: "test-fusion", consent: true)
        }
        #expect(keys.values.isEmpty && !profile.needsCleanup)
        #expect(!VoiceRecognitionProfile(directory: dir, credentials: keys).enabled)
    }

    @Test func explicitProfileGrantSurvivesRestartRefusesMissingKeysAndNeverFollowsACopiedDirectory() throws {
        let dir = root(), copy = root()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: copy)
        }
        let keys = MemoryVoiceKeys()
        let profile = VoiceRecognitionProfile(directory: dir, credentials: keys)
        let config = try profile.enable(language: .chinese, workspace: "test-workspace", region: "cn-beijing",
                                        expertKey: "synthetic-expert-key", fusionKey: "synthetic-fusion-key", consent: true)
        #expect(config.activeModels.map(\.provider) == [.openAIResponses, .qwenMessage])
        #expect(config.models.allSatisfy { $0.cloudConsent && $0.credentialGeneration != nil })
        #expect(!config.automaticRecovery)
        let file = dir.appendingPathComponent("nearpane-voice-api.json")
        let metadata = try String(contentsOf: file, encoding: .utf8)
        #expect(!metadata.contains("synthetic-expert-key") && !metadata.contains("synthetic-fusion-key"))
        let restored = VoiceRecognitionProfile(directory: dir, credentials: keys)
        #expect(try restored.configurationForInput() == config)
        keys.unavailable = true
        #expect(throws: (any Error).self) { try restored.configurationForInput() }
        keys.unavailable = false
        try FileManager.default.copyItem(at: dir, to: copy)
        let foreign = VoiceRecognitionProfile(directory: copy, credentials: keys)
        #expect(!foreign.enabled && foreign.issue != nil)
        #expect(try !foreign.configurationForInput().cloudEnabled)
        try foreign.disable()
        #expect(!keys.values.isEmpty)
        try restored.disable()
        #expect(keys.values.isEmpty && !VoiceRecognitionProfile(directory: dir, credentials: keys).needsCleanup)
    }

    @Test func reconfiguredCredentialsCannotAuthorizePreviousRecordingsThroughTheDomainContract() async throws {
        let dir = root()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryVoiceKeys()
        let profile = VoiceRecognitionProfile(directory: dir, credentials: keys)
        let store = try SaytileStore(directory: dir)
        let record = try await store.createRecording()
        let config = try profile.enable(language: .chineseEnglishMixed, workspace: "", region: "",
                                        expertKey: "test-1", fusionKey: "test-2", consent: true)
        #expect(try await !VoiceRecognitionProfile.retryConfiguration(config, for: record.id, in: store).cloudEnabled)
        try await store.authorizeCloudRecovery(recordingID: record.id, configuration: config)
        #expect(try await VoiceRecognitionProfile.retryConfiguration(config, for: record.id, in: store) == config)
        try profile.disable()
        let updated = try profile.enable(language: .chineseEnglishMixed, workspace: "", region: "",
                                         expertKey: "test-3", fusionKey: "test-4", consent: true)
        #expect(try await !VoiceRecognitionProfile.retryConfiguration(updated, for: record.id, in: store).cloudEnabled)
        try await store.close()
    }

    @Test func settingsOnlyReconfigureTheExistingInputAndRevokeWithoutStartingOrPausingIt() async throws {
        let dir = root()
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryVoiceKeys()
        let profile = VoiceRecognitionProfile(directory: dir, credentials: keys)
        var devices = [ScriptedInput]()
        let module = VoiceModule(openStore: { try SaytileStore(directory: dir) }, recognitionProfile: profile) { _, update in
            let input = ScriptedInput(update)
            devices.append(input)
            return input
        }
        try module.start()
        await module.waitForTransition()
        #expect(devices.isEmpty)
        await module.toggle(requestPermission: false)
        await #expect(throws: (any Error).self) {
            try await module.enableAPI(language: .english, workspace: "", region: "", expertKey: "test-a",
                                       fusionKey: "test-b", consent: true)
        }
        #expect(!profile.enabled && keys.values.isEmpty)
        await module.toggle(requestPermission: false)
        try await module.enableAPI(language: .english, workspace: "", region: "", expertKey: "test-a",
                                   fusionKey: "test-b", consent: true)
        let input = try #require(devices.first)
        #expect(module.capture == .paused && input.configurations == [true])
        await module.toggle(requestPermission: false)
        try await module.disableAPI()
        #expect(module.capture == .listening && !profile.enabled && keys.values.isEmpty)
        #expect(devices.count == 1 && input.revocations == 1 && input.configurations == [true, false])
        #expect(input.permissionRequests == [false, false])
        module.stop()
        await module.waitForTransition()
    }
}
