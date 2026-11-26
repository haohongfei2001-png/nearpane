import Foundation
import CryptoKit
import LyricCore

public struct LyricParser: LyricDocumentParsing {
    public init() {}

    public func parse(_ bytes: Data, format: LyricDomain.Format,
                      recording: LyricDomain.RecordingIdentity,
                      source: LyricDomain.SourceProvenance) throws -> LyricDomain.Document {
        guard bytes.count <= ParserLimits.bytes else { throw invalid("Lyrics exceed 2 MiB.") }
        guard let decoded = String(data: bytes, encoding: .utf8) else {
            throw invalid("Lyrics must be valid UTF-8.")
        }
        let text = decoded.hasPrefix("\u{feff}") ? String(decoded.dropFirst()) : decoded
        let parsed: ParsedLyrics
        switch format {
        case .lrc, .lrcx, .enhancedLRC: parsed = try LRCReader.parse(text, format: format)
        case .plainText: parsed = try PlainReader.parse(text)
        case .ttmlAppleAMLL: parsed = try TTMLReader.parse(text)
        case .lyricsfileV1Draft: parsed = try LyricsfileReader.parse(text)
        case .qrcPlaintext, .yrcPlaintext: parsed = try SegmentLyricsReader.parse(text, format: format)
        }
        try parsed.validate()
        let tokens = parsed.lanes.contains { $0.cues.contains { !$0.tokens.isEmpty } }
        let timed = parsed.lanes.contains { $0.cues.contains { $0.sourceStartMS != nil } }
        return .init(id: UUID(), schemaVersion: 1, contentHash: ContentDigest.sha256(bytes),
                     recording: recording, source: source, originalFormat: format,
                     timingLevel: tokens ? .token : (timed ? .line : .none),
                     sourceTiming: parsed.timing, lanes: parsed.lanes, instrumental: parsed.instrumental)
    }
}

enum ParserLimits {
    static let bytes = 2 * 1024 * 1024
    static let depth = 32
    static let cues = 10_000
    static let tokens = 100_000
    static let nodes = 500_000
}

enum ContentDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }
}

func invalid(_ reason: String) -> LyricDomain.SourceFailure { .invalidDocument(reason: reason) }

struct ParsedLyrics {
    var lanes: [LyricDomain.Lane]
    var timing = LyricDomain.SourceTiming(sourceAdvanceMS: 0, interpretation: .absent, rawOffset: nil)
    var instrumental = false

    func validate() throws {
        var cueIDs: Set<String> = []
        var tokenIDs: Set<String> = []
        var cueCount = 0
        var tokenCount = 0
        for lane in lanes {
            for cue in lane.cues {
                cueCount += 1
                guard cueCount <= ParserLimits.cues, cueIDs.insert(cue.id).inserted else {
                    throw invalid("Too many or duplicate lyric cues.")
                }
                try validateTimes(start: cue.sourceStartMS, end: cue.sourceEndMS)
                let boundaries = Set(cue.text.indices.map { $0.utf16Offset(in: cue.text) } + [cue.text.utf16.count])
                for token in cue.tokens {
                    tokenCount += 1
                    guard tokenCount <= ParserLimits.tokens, tokenIDs.insert(token.id).inserted else {
                        throw invalid("Too many or duplicate lyric tokens.")
                    }
                    try validateTimes(start: token.sourceStartMS, end: token.sourceEndMS)
                    let range = token.rangeInCue
                    let end = range.location.addingReportingOverflow(range.length)
                    guard range.location >= 0, range.length >= 0, !end.overflow,
                          boundaries.contains(range.location), boundaries.contains(end.partialValue),
                          let swiftRange = Range(NSRange(location: range.location, length: range.length), in: cue.text),
                          String(cue.text[swiftRange]) == token.text else {
                        throw invalid("A token does not match complete Unicode graphemes in its line.")
                    }
                }
            }
        }
        guard instrumental || cueCount > 0 else { throw invalid("No lyric content was found.") }
        if instrumental && lanes.contains(where: { $0.cues.contains { !$0.text.isEmpty } }) {
            throw invalid("An instrumental declaration cannot contain vocal lyrics.")
        }
    }
}

func validateTimes(start: Int64?, end: Int64?) throws {
    if let start, start < 0 { throw invalid("Negative source timestamp.") }
    if let end {
        guard let start, end >= start else { throw invalid("Source end precedes its start.") }
    }
}

func checkedAdd(_ left: Int64, _ right: Int64) throws -> Int64 {
    let result = left.addingReportingOverflow(right)
    guard !result.overflow else { throw invalid("Timestamp overflow.") }
    return result.partialValue
}

enum PlainReader {
    static func parse(_ text: String) throws -> ParsedLyrics {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        guard lines.count <= ParserLimits.cues else { throw invalid("Too many lines.") }
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw invalid("The text file is empty.")
        }
        return ParsedLyrics(lanes: [.init(id: "lead", kind: .lead, languageBCP47: nil,
            cues: lines.enumerated().map { index, line in
                .init(id: "plain-\(index)", text: line, sourceStartMS: nil, sourceEndMS: nil,
                      tokens: [], linkedCueID: nil, agentID: nil)
            })])
    }
}

enum LyricTime {
    /// Decimal parsing avoids floating-point drift and rejects NaN/overflow/exponents.
    static func decimalMS(_ value: String, multiplier: Int64 = 1_000) throws -> Int64 {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = parts.first, !whole.isEmpty,
              whole.allSatisfy(\.isNumber), let integral = Int64(whole), integral >= 0 else {
            throw invalid("Invalid decimal timestamp.")
        }
        let base = integral.multipliedReportingOverflow(by: multiplier)
        guard !base.overflow else { throw invalid("Timestamp overflow.") }
        guard parts.count == 2 else { return base.partialValue }
        let fraction = parts[1]
        guard !fraction.isEmpty, fraction.allSatisfy(\.isNumber), fraction.count <= 9 else {
            throw invalid("Invalid timestamp fraction.")
        }
        let divisor = (0..<fraction.count).reduce(Int64(1)) { value, _ in value * 10 }
        guard let numerator = Int64(fraction) else { throw invalid("Invalid timestamp fraction.") }
        let product = numerator.multipliedReportingOverflow(by: multiplier)
        guard !product.overflow else { throw invalid("Timestamp overflow.") }
        return try checkedAdd(base.partialValue, product.partialValue / divisor)
    }

    static func clockMS(_ value: String) throws -> Int64 {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { throw invalid("Unsupported clock timestamp.") }
        let second = try decimalMS(String(parts.last!))
        guard second < 60_000, let minutes = Int64(parts[parts.count - 2]), minutes >= 0 else {
            throw invalid("Invalid clock minutes or seconds.")
        }
        let minuteMS = minutes.multipliedReportingOverflow(by: 60_000)
        guard !minuteMS.overflow else { throw invalid("Timestamp overflow.") }
        var total = try checkedAdd(minuteMS.partialValue, second)
        if parts.count == 3 {
            guard minutes < 60, let hours = Int64(parts[0]), hours >= 0 else { throw invalid("Invalid clock hours.") }
            let hourMS = hours.multipliedReportingOverflow(by: 3_600_000)
            guard !hourMS.overflow else { throw invalid("Timestamp overflow.") }
            total = try checkedAdd(hourMS.partialValue, total)
        }
        return total
    }
}
