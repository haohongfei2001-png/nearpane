import Foundation
import LyricCore

enum PlaybackSourcePolicy {
    static func choose(preferred: PlayerID?, previous: PlayerID?, currentSource: PlayerID?,
                       observations: [PlayerID: PlayerObservation], available: Set<PlayerID>,
                       transitions: [PlayerID: UInt64]) -> PlayerID? {
        if let preferred { return preferred }
        let playing = PlayerID.allCases.filter { observations[$0]?.state == .playing && observations[$0]?.quality != .stale }
        if let currentSource, playing.contains(currentSource) { return currentSource }
        let latest = playing.map { transitions[$0] ?? 0 }.max() ?? 0
        if let previous, playing.contains(previous), (transitions[previous] ?? 0) == latest { return previous }
        if let best = playing.first(where: { (transitions[$0] ?? 0) == latest }) { return best }
        if let previous, available.contains(previous) { return previous }
        return PlayerID.allCases.first { observations[$0]?.hasRecording == true }
            ?? PlayerID.allCases.first { available.contains($0) }
    }
}

struct PlaybackSelectionTracker: Sendable {
    private(set) var selection: LyricDomain.Selection?
    private var processIdentity: String?
    private var lastObservation: PlayerObservation?
    private var generation: UInt64 = 0
    mutating func clear() { selection = nil; processIdentity = nil; lastObservation = nil }
    mutating func update(_ observation: PlayerObservation) -> LyricDomain.Selection? {
        guard observation.hasRecording, observation.state != .stopped else { clear(); return nil }
        let processChanged = processIdentity != observation.process.identity || selection?.playerBundleID != observation.process.player.bundleID
            || lastObservation.map { $0.mediaPID != observation.mediaPID || $0.mediaProcessStart != observation.mediaProcessStart } == true
        let recordingChanged = lastObservation.map { !Self.sameRecording($0, observation) } ?? true
        var identity = observation
        if !processChanged, !recordingChanged, let previous = lastObservation {
            // Sparse refreshes may omit metadata that already identified this
            // recording. Keep that evidence until an actual transition, so an
            // omitted ID cannot hide the next track's different ID.
            if identity.title?.isEmpty != false { identity.title = previous.title }
            if identity.artist?.isEmpty != false { identity.artist = previous.artist }
            if identity.album?.isEmpty != false { identity.album = previous.album }
            if identity.platformID?.isEmpty != false { identity.platformID = previous.platformID }
            if identity.durationMS == nil { identity.durationMS = previous.durationMS }
        }
        if processChanged || recordingChanged || selection == nil {
            generation &+= 1
            let session = processChanged ? UUID() : (selection?.sessionID ?? UUID())
            selection = LyricDomain.Selection(playerBundleID: observation.process.player.bundleID,
                sessionID: session, generation: generation, recording: Self.recording(identity))
        } else if let old = selection {
            // Preserve fingerprint and generation when optional metadata arrives.
            let enriched = Self.recording(identity, fingerprint: old.recording.fingerprint)
            selection = LyricDomain.Selection(playerBundleID: old.playerBundleID,
                sessionID: old.sessionID, generation: old.generation, recording: enriched)
        }
        processIdentity = observation.process.identity; lastObservation = identity
        return selection
    }
    static func sameRecording(_ lhs: PlayerObservation, _ rhs: PlayerObservation) -> Bool {
        guard lhs.process == rhs.process, lhs.mediaPID == rhs.mediaPID,
              lhs.mediaProcessStart == rhs.mediaProcessStart else { return false }
        if let a = lhs.platformID, let b = rhs.platformID, !a.isEmpty, !b.isEmpty, a != b { return false }
        for (a, b) in [(lhs.title, rhs.title), (lhs.artist, rhs.artist), (lhs.album, rhs.album)] {
            if let a, let b, !a.isEmpty, !b.isEmpty, normalized(a) != normalized(b) { return false }
        }
        if let a = lhs.durationMS, let b = rhs.durationMS, abs(a - b) > 2000 { return false }
        // Complete metadata disappearing must not retain an old recording.
        return lhs.hasRecording && rhs.hasRecording
    }
    static func matches(_ lhs: LyricDomain.Selection?, _ rhs: LyricDomain.Selection) -> Bool {
        lhs?.sessionID == rhs.sessionID && lhs?.generation == rhs.generation && lhs?.playerBundleID == rhs.playerBundleID
    }
    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    private static func recording(_ observation: PlayerObservation, fingerprint: String? = nil) -> LyricDomain.RecordingIdentity {
        let source = observation.process.player.bundleID
        let platformID = observation.platformID.flatMap { $0.isEmpty ? nil : $0 }
        let parts = [observation.title ?? "", observation.artist ?? "", observation.album ?? "", observation.durationMS.map(String.init) ?? ""]
        let key = platformID.map { "id:\($0)" } ?? "metadata:" + parts.map { "\($0.utf8.count):\(normalized($0))" }.joined(separator: "|")
        let id = fingerprint ?? "\(source):\(key)"
        let title = observation.title ?? ""
        let text = title + " " + (observation.album ?? "")
        let tags = ["live", "remix", "remaster", "acoustic", "instrumental", "sped up", "slowed", "现场", "伴奏", "翻唱", "重制"].filter { tag in
            if tag.unicodeScalars.allSatisfy({ $0.isASCII }) {
                return text.range(of: "(?i)(?<![a-z])" + NSRegularExpression.escapedPattern(for: tag) + "(?![a-z])", options: .regularExpression) != nil
            }
            return text.contains(tag)
        }
        let ids = platformID.map { [LyricDomain.PlatformTrackID(namespace: source + ".playerTrack", value: $0)] } ?? []
        return LyricDomain.RecordingIdentity(fingerprint: id, platformIDs: ids, isrc: nil,
            title: observation.title, artists: observation.artist.map { [$0] } ?? [], album: observation.album,
            durationMS: observation.durationMS, versionTags: tags)
    }
}

enum TransportRoutePolicy {
    static func validate(_ command: TransportCommand, expected: LyricDomain.Selection,
                         current: LyricDomain.Selection?, observation: PlayerObservation,
                         now: LyricDomain.MonotonicStamp = PlaybackClock.now()) throws {
        guard PlaybackSelectionTracker.matches(current, expected) else { throw PlaybackError.selectionChanged }
        guard observation.process.startMicros != 0, observation.mediaProcessStart != 0 else { throw PlaybackError.playerExited }
        guard now.clockDomainID == observation.stamp.clockDomainID,
              now.nanoseconds >= observation.stamp.nanoseconds,
              now.nanoseconds - observation.stamp.nanoseconds <= 8_000_000_000,
              observation.quality != .stale else { throw PlaybackError.unavailable("播放状态已过期") }
        guard observation.process.player.usesAppleEvents || observation.sourceIsCurrent else { throw PlaybackError.sourceNotCurrent }
        guard observation.capabilities.allows(command) else { throw PlaybackError.unsupported }
        if case .seek(let ms) = command {
            guard ms >= 0, observation.positionMS != nil, observation.quality != .unavailable,
                  let duration = observation.durationMS, duration > 0, ms <= duration else { throw PlaybackError.unsupported }
        }
    }
}

enum CommandReadback {
    static func confirms(_ command: TransportCommand, before: PlayerObservation, after: PlayerObservation,
                         sentAt: LyricDomain.MonotonicStamp) -> Bool {
        guard before.process == after.process, before.mediaPID == after.mediaPID,
              before.mediaProcessStart == after.mediaProcessStart,
              after.quality != .stale,
              sentAt.clockDomainID == after.stamp.clockDomainID,
              after.stamp.nanoseconds >= sentAt.nanoseconds,
              after.process.player.usesAppleEvents || after.sourceIsCurrent else { return false }
        let same = PlaybackSelectionTracker.sameRecording(before, after)
        switch command {
        case .play: return same && after.state == .playing
        case .pause: return same && after.state == .paused
        case .next: return !same && after.hasRecording
        case .previous:
            return (!same && after.hasRecording) || (same && (before.positionMS ?? 0) > 3000 && (after.positionMS ?? Int64.max) < 1500)
        case .seek(let target):
            guard same, let position = after.positionMS,
                  before.state != .paused || after.state == .paused else { return false }
            let elapsed = Double(after.stamp.nanoseconds - sentAt.nanoseconds) / 1_000_000
            let projected = Double(target) + (after.state == .playing ? elapsed * after.rate : 0)
            guard let expected = MediaTime.clampedMilliseconds(projected, duration: after.durationMS) else { return false }
            let tolerance: Int64 = after.process.player.usesAppleEvents ? 700 : 1500
            return abs(position - expected) <= tolerance
        }
    }
}

