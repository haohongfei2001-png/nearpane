import Foundation

/// The release channel is part of the signed App. User preferences belong to
/// Sparkle's persistent settings and cannot replace this channel or its key.
public enum ApplicationUpdatePolicy {
    public static let feedURL = "https://github.com/haohongfei2001-png/nearpane/releases/latest/download/appcast.xml"
    public static let checkInterval: TimeInterval = 86_400

    public static func configurationProblem(_ info: [String: Any]) -> String? {
        guard info["CFBundleIdentifier"] as? String == "com.holdsnow.nearpane.alpha" else {
            return "当前应用身份不支持此更新通道。"
        }
        guard info["SUFeedURL"] as? String == feedURL,
              let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32,
              bytes.contains(where: { $0 != 0 }) else {
            return "Nearpane 更新发布通道尚未就绪。此版本可继续使用，正式更新可用后将开放检查。"
        }
        guard info["SURequireSignedFeed"] as? Bool == true,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SUSignedFeedFailureExpirationInterval"] as? Int == 0,
              info["SUAllowsAutomaticUpdates"] as? Bool == false,
              info["SUAutomaticallyUpdate"] as? Bool == false,
              info["SUScheduledCheckInterval"] as? Double == checkInterval else {
            return "更新配置不完整，请使用完整的 Nearpane 安装包。"
        }
        return nil
    }

    public static func accepts(currentVersion: String, currentBuild: String,
                               candidateVersion: String, candidateBuild: String,
                               feedSignatureValid: Bool) -> Bool {
        guard feedSignatureValid,
              let current = version(currentVersion), let candidate = version(candidateVersion),
              let oldBuild = number(currentBuild), let newBuild = number(candidateBuild) else { return false }
        return current.lexicographicallyPrecedes(candidate) && newBuild > oldBuild
    }

    private static func version(_ text: String) -> [UInt]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        let result = parts.compactMap { number(String($0)) }
        guard result.count == parts.count else { return nil }
        return result + Array(repeating: 0, count: 3 - result.count)
    }

    private static func number(_ text: String) -> UInt? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              text.count == 1 || text.first != "0" else { return nil }
        return UInt(text)
    }
}

/// Sparkle's UI session may end while its independent installer is still alive.
/// Only an explicit download cancellation can release a pre-install admission.
public struct UpdateInstallationAdmission: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, downloadAccepted, installerAccepted }
    public private(set) var phase: Phase = .idle
    public init() {}

    public mutating func acceptDownload() {
        if phase == .idle { phase = .downloadAccepted }
    }
    public mutating func acceptInstallation() { phase = .installerAccepted }
    public mutating func cancelDownload() {
        if phase == .downloadAccepted { phase = .idle }
    }
    public func permitsProfileSwitch(sessionInProgress: Bool, installationDeferred: Bool) -> Bool {
        phase == .idle && !sessionInProgress && !installationDeferred
    }
}
