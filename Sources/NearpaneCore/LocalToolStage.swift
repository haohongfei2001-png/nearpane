import CryptoKit
import Foundation
import OSLog

/// Only fixed stage names, a correlation ID, content digests and monotonic time leave a tool.
public enum LocalToolStage: String, Sendable {
    case serviceRegistered, serviceCallback, requestQueued, hostReceived, modelInstalled, modelMissing, modelUnsupported
    case serviceOriginBound, serviceCallerUnverified, serviceSelectionUnverified, anchorFeedbackPointer
    case feedbackPointerUnavailable, feedbackPointerRevoked
    case translated, translationFailed, anchorSelection, anchorPointer, panelVisible, panelUnavailable, wordCommitted, wordReopened
    case firstPCM, voiceStarted, voicePaused, voiceInterrupted, voiceRecordingLinked, voiceAudioPersisted
    case voiceFinal, voiceRecoverable, voiceDiscarded, voiceUnverified

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func emit(_ id: UUID, hash: String? = nil) {
        let digest = hash.flatMap { $0.count == 64 && $0.allSatisfy(\.isHexDigit) ? $0 : nil } ?? "-"
        let uptime = ProcessInfo.processInfo.systemUptime
        Self.log.notice("toolStage id=\(id.uuidString, privacy: .public) stage=\(rawValue, privacy: .public) hash=\(digest, privacy: .public) uptime=\(uptime, privacy: .public)")
    }
    private static let log = Logger(subsystem: "com.holdsnow.nearpane.alpha", category: "LocalToolStage")
}
