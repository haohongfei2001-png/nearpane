import CryptoKit
import Foundation
import NearpaneCore
import Observation
import SaytileKit

protocol VoiceCredentialAccess {
    func save(_ secret: String, for model: ModelConfiguration) throws
    func remove(_ model: ModelConfiguration) throws
    func presence(_ model: ModelConfiguration) -> CloudCredentialPresence
}
extension NearpaneVoiceCredentials: VoiceCredentialAccess {}

/// Only a user-created grant in this profile generation can select the API pipeline.
@MainActor @Observable
final class VoiceRecognitionProfile {
    private struct Grant: Codable {
        let format: Int
        let profile: String
        var enabled: Bool
        let language: LanguagePreference
        let workspace: String
        let region: String
        let expert: UUID
        let fusion: UUID

        func configuration() throws -> RecognitionConfiguration {
            var result = RecognitionConfiguration()
            guard language != .auto,
                  let provider = ASRModelRegistry.provider(for: language),
                  var asr = result.models.first(where: { $0.provider == provider }),
                  var core = result.models.first(where: { $0.purpose == .textFusion }),
                  expert != fusion else { throw AudioFailure.message("语音授权信息无效，请清除后重新配置。") }
            asr.id = expert
            core.id = fusion
            asr.credentialGeneration = expert
            core.credentialGeneration = fusion
            asr.cloudConsent = true
            core.cloudConsent = true
            asr.enabled = true
            if provider == .qwenMessage {
                asr.workspaceID = workspace
                asr.region = region
            }
            result.languagePreference = language
            result.models = [asr, core]
            result.cloudEnabled = true
            // Only a deliberate retry may send an authorized, previously failed recording.
            result.automaticRecovery = false
            try result.validateForCloud()
            return result
        }
    }

    private let directory: URL
    private let profileID: String
    private let credentials: any VoiceCredentialAccess
    private let file: URL
    private var grant: Grant?
    private(set) var issue: String?
    var enabled: Bool { grant?.enabled == true && issue == nil }
    var needsCleanup: Bool { grant != nil || issue != nil }
    var language: LanguagePreference? { grant?.language }

    static func identifier(for directory: URL) -> String {
        // Foundation can change /private/tmp to /tmp only after a path exists.
        // Normalize the existing parent before deriving the first-run Keychain scope.
        var parent = directory
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: parent.path), !parent.path.isEmpty, parent.path != "/" {
            suffix.append(parent.lastPathComponent)
            parent.deleteLastPathComponent()
        }
        let path = suffix.reversed().reduce(parent.standardizedFileURL) { $0.appendingPathComponent($1) }
        return SHA256.hash(data: Data(path.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    init(directory: URL, credentials: any VoiceCredentialAccess) {
        self.directory = directory
        self.profileID = Self.identifier(for: directory)
        self.credentials = credentials
        file = directory.appendingPathComponent("nearpane-voice-api.json")
        do {
            try ProfileLease.checkPath(file)
            let bytes = try Data(contentsOf: file)
            let saved = try JSONDecoder().decode(Grant.self, from: bytes)
            guard saved.format == 1, saved.profile == profileID else { throw CocoaError(.fileReadCorruptFile) }
            _ = try saved.configuration()
            grant = saved
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A new or selectively imported profile starts in local mode.
        } catch { issue = "此资料的 API 授权无法验证，已停用。可清除授权后重新配置。" }
    }

    func configurationForInput() throws -> RecognitionConfiguration {
        guard let grant, enabled else { return RecognitionConfiguration() }
        let config = try grant.configuration()
        for model in config.activeModels {
            let presence = credentials.presence(model)
            guard presence.isSaved else {
                throw AudioFailure.message(model.provider.label + "：" + presence.label + "。请检查钥匙串，或在语音设置中切回本机。")
            }
        }
        return config
    }

    static func retryConfiguration(_ selected: RecognitionConfiguration, for id: UUID,
                                   in store: SaytileStore) async throws -> RecognitionConfiguration {
        guard selected.cloudEnabled else { return selected }
        if try await store.permitsAutomaticCloudRecovery(recordingID: id, configuration: selected) { return selected }
        // Consent to new recordings does not grant access to previously saved audio.
        var local = selected
        local.cloudEnabled = false
        return local
    }

    func enable(language: LanguagePreference, workspace: String, region: String, expertKey: String,
                fusionKey: String, consent: Bool) throws -> RecognitionConfiguration {
        guard !needsCleanup, consent else { throw AudioFailure.message("请先核对两项服务的处理范围并明确授权。") }
        guard !expertKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !fusionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudCredentialError.empty }
        var next = Grant(format: 1, profile: profileID, enabled: false, language: language, workspace: workspace,
                         region: region, expert: UUID(), fusion: UUID())
        let config = try next.configuration()
        // A crash after either key is created leaves a disabled, cleanable grant.
        try persist(next)
        grant = next
        do {
            for model in config.models {
                try credentials.save(model.purpose == .textFusion ? fusionKey : expertKey, for: model)
            }
            next.enabled = true
            try persist(next)
            grant = next
            return config
        } catch {
            let setupError = error
            try disable()
            throw setupError
        }
    }

    func disable() throws {
        if var old = grant {
            old.enabled = false
            grant = old
            // Even on a disk error, attempt to invalidate both Keychain accounts.
            var failure: Error?
            do { try persist(old) } catch { failure = error }
            for model in try old.configuration().models {
                do { try credentials.remove(model) } catch { failure = error }
            }
            if let failure {
                issue = "API 已在本次运行停用。请重试清除授权，确认钥匙串与资料均已更新。"
                throw failure
            }
        }
        try ProfileLease.checkPath(file)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        grant = nil
        issue = nil
    }

    private func persist(_ value: Grant) throws {
        try ProfileLease.checkPath(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try ProfileLease.checkPath(file)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
    }
}
