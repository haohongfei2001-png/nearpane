import Foundation

/// One monotonic clock domain per process. Re-created after launch; never persisted.
public enum PlaybackClock {
    public static let domainID = UUID()

    public static func now() -> LyricDomain.MonotonicStamp {
        let nanos = ProcessInfo.processInfo.systemUptime * 1_000_000_000
        return .init(nanoseconds: UInt64(max(0, nanos)), clockDomainID: domainID)
    }
}

public enum LyricTimelineError: Error, Equatable, Sendable {
    case differentClockDomains
    case timeWentBackwards
    case invalidPosition
    case differentRecording
    case arithmeticOverflow
}

/// Unicode normalization for matching only. Never use it to replace displayed lyric text.
public enum RecordingText {
    public static func normalize(_ value: String) -> String {
        let folded = value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
        return folded.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
        }.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
