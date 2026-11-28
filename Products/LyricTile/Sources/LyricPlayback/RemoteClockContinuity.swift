import Foundation
import LyricCore

/// Wall time is only used to translate an external NSDate anchor. Never let a
/// wall-clock jump turn an unchanged source anchor into a jump to the track end.
struct RemoteClockContinuity: Sendable {
    private var previousWall: TimeInterval?
    private var previousMono: LyricDomain.MonotonicStamp?
    private var lastSourceTimestamp: Int64?
    private var rejectedTimestamp: Int64?
    private var freshTimestampAfter: TimeInterval?

    mutating func invalidate(wall: Date) {
        rejectedTimestamp = lastSourceTimestamp
        freshTimestampAfter = wall.timeIntervalSince1970 - 0.1
    }
    mutating func accepts(sourceTimestampMicros: Int64?, state: LyricDomain.PlaybackState,
                          now: LyricDomain.MonotonicStamp, wall: Date) -> Bool {
        if let previousWall, let previousMono {
            if previousMono.clockDomainID != now.clockDomainID || now.nanoseconds < previousMono.nanoseconds {
                invalidate(wall: wall)
            } else {
                let monoDelta = Double(now.nanoseconds - previousMono.nanoseconds) / 1_000_000_000
                let wallDelta = wall.timeIntervalSince1970 - previousWall
                if abs(wallDelta - monoDelta) > 0.5 { invalidate(wall: wall) }
            }
        }
        previousWall = wall.timeIntervalSince1970; previousMono = now
        defer { lastSourceTimestamp = sourceTimestampMicros }
        guard let freshTimestampAfter else { return true }
        // Paused/buffering observations use the supplied elapsed value directly;
        // there is no wall-time extrapolation. Retain the barrier for resumption.
        guard state == .playing else { return true }
        guard let sourceTimestampMicros, sourceTimestampMicros != rejectedTimestamp else { return false }
        let seconds = Double(sourceTimestampMicros) / 1_000_000
        guard seconds >= freshTimestampAfter, seconds <= wall.timeIntervalSince1970 + 0.1 else { return false }
        self.freshTimestampAfter = nil; rejectedTimestamp = nil
        return true
    }
}
