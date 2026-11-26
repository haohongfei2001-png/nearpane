import Foundation
import LyricCore

/// Original implementation of the documented LRC / LRCX grammars; no legacy provider code.
enum LRCReader {
    private struct Attachment {
        let timestamps: [Int64]
        let tag: String
        let body: String
    }

    static func parse(_ text: String, format: LyricDomain.Format) throws -> ParsedLyrics {
        let rows = text.components(separatedBy: .newlines)
        guard rows.count <= ParserLimits.cues * 4 else { throw invalid("Too many LRC rows.") }
        var cues: [LyricDomain.Cue] = []
        var extras: [String: [LyricDomain.Cue]] = [:]
        var attachments: [Attachment] = []
        var timing = LyricDomain.SourceTiming(sourceAdvanceMS: 0, interpretation: .absent, rawOffset: nil)
        for (rowNumber, row) in rows.enumerated() {
            var remaining = row[...]
            var timestamps: [Int64] = []
            while remaining.first == "[", let close = remaining.firstIndex(of: "]") {
                let tag = String(remaining[remaining.index(after: remaining.startIndex)..<close])
                let isTimestamp = (tag.first?.isNumber == true || tag.hasPrefix("-") || tag.hasPrefix("+")) && tag.contains(":")
                guard isTimestamp else { break }
                timestamps.append(try LyricTime.clockMS(tag))
                remaining = remaining[remaining.index(after: close)...]
            }
            if timestamps.isEmpty {
                if row.lowercased().hasPrefix("[offset:"), row.hasSuffix("]") {
                    let raw = String(row.dropFirst(8).dropLast()).trimmingCharacters(in: .whitespaces)
                    guard let value = Int64(raw) else { throw invalid("Invalid LRC offset.") }
                    timing = .init(sourceAdvanceMS: value, interpretation: .normalizedKnownFormat, rawOffset: raw)
                }
                continue // Untimed metadata/comment lines are not fabricated timed cues.
            }
            if format == .lrcx, remaining.first == "[", let close = remaining.firstIndex(of: "]") {
                let tag = String(remaining[remaining.index(after: remaining.startIndex)..<close])
                if tag == "tt" || tag == "ro" || tag == "fu" || tag == "tr" || tag.hasPrefix("tr:") {
                    attachments.append(.init(timestamps: timestamps, tag: tag,
                                             body: String(remaining[remaining.index(after: close)...])))
                    continue
                }
            }
            var lyricText = String(remaining)
            var inlineTranslation: String?
            if format == .lrcx, lyricText.hasSuffix("】"), let open = lyricText.lastIndex(of: "【") {
                inlineTranslation = String(lyricText[lyricText.index(after: open)..<lyricText.index(before: lyricText.endIndex)])
                lyricText = String(lyricText[..<open])
            }
            let enhanced = try enhancedSegments(lyricText)
            for (occurrence, stamp) in timestamps.enumerated() {
                guard cues.count < ParserLimits.cues else { throw invalid("Too many LRC cues.") }
                let cueID = "lrc-\(rowNumber)-\(occurrence)"
                let delta = stamp - timestamps[0]
                let tokens = try enhanced.tokens.enumerated().map { index, segment in
                    LyricDomain.Token(id: "\(cueID)-w\(index)", text: segment.text,
                        rangeInCue: .init(location: segment.location, length: segment.text.utf16.count),
                        sourceStartMS: try checkedAdd(segment.start, delta),
                        sourceEndMS: try segment.end.map { try checkedAdd($0, delta) })
                }
                let end = try enhanced.end.map { try checkedAdd($0, delta) }
                cues.append(.init(id: cueID, text: enhanced.text, sourceStartMS: stamp,
                                  sourceEndMS: end, tokens: tokens, linkedCueID: nil, agentID: nil))
                if let translation = inlineTranslation, !translation.isEmpty {
                    extras["tr", default: []].append(.init(id: "\(cueID)-tr", text: translation,
                        sourceStartMS: stamp, sourceEndMS: end, tokens: [], linkedCueID: cueID, agentID: nil))
                }
            }
        }
        guard !cues.isEmpty else { throw invalid("No valid LRC timestamps were found.") }
        for (attachmentIndex, attachment) in attachments.enumerated() {
            for index in cues.indices where attachment.timestamps.contains(cues[index].sourceStartMS ?? -1) {
                let cue = cues[index]
                if attachment.tag == "tt" {
                    cues[index] = try attachWordBoundaries(attachment.body, to: cue)
                } else {
                    let body: String
                    if attachment.tag == "ro" || attachment.tag == "fu" {
                        body = try rangeAttachmentText(attachment.body, cue: cue)
                    } else { body = attachment.body }
                    extras[attachment.tag, default: []].append(.init(id: "\(cue.id)-a\(attachmentIndex)",
                        text: body, sourceStartMS: cue.sourceStartMS, sourceEndMS: cue.sourceEndMS,
                        tokens: [], linkedCueID: cue.id, agentID: nil))
                }
            }
        }
        cues.sort { ($0.sourceStartMS ?? 0) < ($1.sourceStartMS ?? 0) }
        var lanes = [LyricDomain.Lane(id: "lead", kind: .lead, languageBCP47: nil, cues: cues)]
        for tag in extras.keys.sorted() {
            let language = tag.hasPrefix("tr:") ? String(tag.dropFirst(3)) : nil
            let kind: LyricDomain.LaneKind = tag == "ro" ? .romanization : (tag == "fu" ? .ruby : .translation)
            lanes.append(.init(id: tag, kind: kind, languageBCP47: language,
                cues: extras[tag, default: []].sorted { ($0.sourceStartMS ?? 0) < ($1.sourceStartMS ?? 0) }))
        }
        return ParsedLyrics(lanes: lanes, timing: timing)
    }

    private struct Segment { let text: String; let location: Int; let start: Int64; let end: Int64? }
    private static func enhancedSegments(_ input: String) throws
        -> (text: String, tokens: [Segment], end: Int64?) {
        var output = ""
        var tokens: [Segment] = []
        var cursor = input.startIndex
        var activeStart: Int64?
        var activeLocation = 0
        var segmentText = ""
        var lastMarker: Int64?
        while cursor < input.endIndex {
            if input[cursor] == "<", let close = input[cursor...].firstIndex(of: ">") {
                let raw = String(input[input.index(after: cursor)..<close])
                if raw.first?.isNumber == true && raw.contains(":") {
                    let stamp = try LyricTime.clockMS(raw)
                    if let previous = lastMarker, stamp < previous { throw invalid("Enhanced LRC times go backwards.") }
                    if let start = activeStart, !segmentText.isEmpty {
                        tokens.append(.init(text: segmentText, location: activeLocation, start: start, end: nil))
                    }
                    segmentText = ""; activeStart = stamp; lastMarker = stamp
                    activeLocation = output.utf16.count
                    cursor = input.index(after: close)
                    continue
                }
            }
            let character = input[cursor]
            output.append(character)
            if activeStart != nil { segmentText.append(character) }
            cursor = input.index(after: cursor)
        }
        var explicitEnd: Int64?
        if let start = activeStart {
            if !segmentText.isEmpty {
                tokens.append(.init(text: segmentText, location: activeLocation, start: start, end: nil))
            } else if let last = tokens.popLast() {
                explicitEnd = start
                tokens.append(.init(text: last.text, location: last.location, start: last.start, end: start))
            }
        }
        return (output, tokens, explicitEnd)
    }

    private static func angleParts(_ input: String) throws -> [String] {
        var rest = input[...]
        var parts: [String] = []
        while !rest.isEmpty {
            guard rest.first == "<", let end = rest.firstIndex(of: ">") else {
                throw invalid("Malformed LRCX attachment.")
            }
            parts.append(String(rest[rest.index(after: rest.startIndex)..<end]))
            rest = rest[rest.index(after: end)...]
            guard parts.count <= ParserLimits.tokens else { throw invalid("Too many LRCX boundaries.") }
        }
        return parts
    }

    private static func attachWordBoundaries(_ raw: String, to cue: LyricDomain.Cue) throws -> LyricDomain.Cue {
        var marks: [(time: Int64, index: Int)] = []
        var explicitEnd: Int64?
        for part in try angleParts(raw) {
            let fields = part.split(separator: ",", omittingEmptySubsequences: false)
            if fields.count == 1, let duration = Int64(fields[0]), duration >= 0 {
                explicitEnd = try checkedAdd(cue.sourceStartMS ?? 0, duration)
            } else if fields.count == 2, let time = Int64(fields[0]), time >= 0, let index = Int(fields[1]), index >= 0 {
                marks.append((try checkedAdd(cue.sourceStartMS ?? 0, time), index))
            } else { throw invalid("Invalid LRCX word boundary.") }
        }
        var tokens: [LyricDomain.Token] = []
        for (index, mark) in marks.enumerated() {
            let next = index + 1 < marks.count ? marks[index + 1] : nil
            let endIndex = next?.index ?? cue.text.utf16.count
            guard endIndex >= mark.index, endIndex <= cue.text.utf16.count,
                  next == nil || next!.time >= mark.time else { throw invalid("Unordered LRCX boundaries.") }
            guard endIndex > mark.index else { continue }
            let range = NSRange(location: mark.index, length: endIndex - mark.index)
            guard let swiftRange = Range(range, in: cue.text) else { throw invalid("Invalid LRCX UTF-16 range.") }
            tokens.append(.init(id: "\(cue.id)-tt\(index)", text: String(cue.text[swiftRange]),
                rangeInCue: .init(location: range.location, length: range.length), sourceStartMS: mark.time,
                sourceEndMS: next?.time ?? explicitEnd))
        }
        return .init(id: cue.id, text: cue.text, sourceStartMS: cue.sourceStartMS,
                     sourceEndMS: explicitEnd ?? cue.sourceEndMS, tokens: tokens, linkedCueID: cue.linkedCueID,
                     agentID: cue.agentID)
    }

    private static func rangeAttachmentText(_ raw: String, cue: LyricDomain.Cue) throws -> String {
        guard raw.first == "<" else { return raw }
        return try angleParts(raw).map { part in
            let fields = part.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 3, let start = Int(fields[1]), let end = Int(fields[2]),
                  start >= 0, end >= start, end <= cue.text.utf16.count else {
                throw invalid("Invalid LRCX annotation range.")
            }
            return String(fields[0])
        }.joined(separator: " ")
    }
}
