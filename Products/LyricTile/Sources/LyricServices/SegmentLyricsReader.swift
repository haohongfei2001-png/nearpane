import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import LyricCore

/// Already-decoded QRC / YRC only. No platform cache access or ciphertext decryption.
enum SegmentLyricsReader {
    static func parse(_ input: String, format: LyricDomain.Format) throws -> ParsedLyrics {
        let text: String
        if format == .qrcPlaintext && input.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            guard !input.localizedCaseInsensitiveContains("<!DOCTYPE"),
                  !input.localizedCaseInsensitiveContains("<!ENTITY") else { throw invalid("QRC XML entities are disabled.") }
            let delegate = QRCContentDelegate()
            let xml = XMLParser(data: Data(input.utf8))
            xml.shouldResolveExternalEntities = false
            xml.delegate = delegate
            guard xml.parse(), let content = delegate.content, delegate.failure == nil else {
                throw delegate.failure ?? invalid("The QRC XML has no lyric content.")
            }
            text = content
        } else { text = input }
        let marker = try NSRegularExpression(pattern: format == .yrcPlaintext
            ? #"\(([0-9]+),([0-9]+),([0-9]+)\)"# : #"\(([0-9]+),([0-9]+)\)"#)
        var cues: [LyricDomain.Cue] = []
        for (lineIndex, line) in text.components(separatedBy: .newlines).enumerated() {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let fields = line[line.index(after: line.startIndex)..<close].split(separator: ",")
            guard fields.count == 2, let start = Int64(fields[0]), let duration = Int64(fields[1]),
                  start >= 0, duration >= 0 else { continue }
            guard cues.count < ParserLimits.cues else { throw invalid("Too many segment lyric lines.") }
            let body = String(line[line.index(after: close)...])
            let string = body as NSString
            let matches = marker.matches(in: body, range: NSRange(location: 0, length: string.length))
            guard !matches.isEmpty, matches.count <= ParserLimits.tokens else {
                throw invalid("A timed QRC/YRC line contains no valid word timings.")
            }
            let id = "segment-\(lineIndex)"
            var joined = ""
            var tokens: [LyricDomain.Token] = []
            var previousEnd = 0
            for (index, match) in matches.enumerated() {
                guard let wordStart = Int64(string.substring(with: match.range(at: 1))),
                      let wordDuration = Int64(string.substring(with: match.range(at: 2))) else {
                    throw invalid("Invalid word timestamp.")
                }
                let wordText: String
                if format == .yrcPlaintext {
                    if index == 0 && match.range.location != 0 { throw invalid("Untimed text before YRC words.") }
                    let from = NSMaxRange(match.range)
                    let to = index + 1 < matches.count ? matches[index + 1].range.location : string.length
                    wordText = string.substring(with: NSRange(location: from, length: to - from))
                } else {
                    wordText = string.substring(with: NSRange(location: previousEnd, length: match.range.location - previousEnd))
                }
                previousEnd = NSMaxRange(match.range)
                if !wordText.isEmpty {
                    tokens.append(.init(id: "\(id)-w\(index)", text: wordText,
                        rangeInCue: .init(location: joined.utf16.count, length: wordText.utf16.count),
                        sourceStartMS: wordStart, sourceEndMS: try checkedAdd(wordStart, wordDuration)))
                    joined += wordText
                }
            }
            if format == .qrcPlaintext && previousEnd != string.length {
                throw invalid("Untimed text after QRC words.")
            }
            cues.append(.init(id: id, text: joined, sourceStartMS: start,
                sourceEndMS: try checkedAdd(start, duration), tokens: tokens, linkedCueID: nil, agentID: nil))
        }
        guard !cues.isEmpty else { throw invalid("No decoded QRC/YRC lyric lines were found.") }
        return ParsedLyrics(lanes: [.init(id: "lead", kind: .lead, languageBCP47: nil,
            cues: cues.sorted { ($0.sourceStartMS ?? 0) < ($1.sourceStartMS ?? 0) })])
    }
}

private final class QRCContentDelegate: NSObject, XMLParserDelegate {
    var content: String?
    var depth = 0
    var failure: LyricDomain.SourceFailure?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        depth += 1
        if depth > ParserLimits.depth {
            failure = invalid("QRC XML nesting limit exceeded."); parser.abortParsing(); return
        }
        if let text = attributeDict["LyricContent"] {
            if content != nil { failure = invalid("Multiple QRC lyric payloads."); parser.abortParsing() }
            else { content = text }
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        depth -= 1
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        failure = invalid("External entities are disabled."); parser.abortParsing(); return nil
    }
}
