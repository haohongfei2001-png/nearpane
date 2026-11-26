import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import LyricCore

/// Restricted Apple/AMLL media-time profile. Not a general TTML2 layout engine.
enum TTMLReader {
    static func parse(_ text: String) throws -> ParsedLyrics {
        guard !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw invalid("TTML DTDs and entities are disabled.")
        }
        let delegate = BoundedXMLTree()
        let parser = XMLParser(data: Data(text.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let success = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard success, let root = delegate.root, root.name == "tt",
              root.namespace.isEmpty || root.namespace == "http://www.w3.org/ns/ttml" else {
            throw invalid("Invalid TTML document.")
        }
        var paragraphs: [XMLLyricNode] = []
        try validateAndCollect(root, depth: 0, paragraphs: &paragraphs)
        var laneCues: [LaneKey: [LyricDomain.Cue]] = [:]
        for (index, paragraph) in paragraphs.enumerated() {
            let cueID = "ttml-p\(index)"
            let pTimes = try times(paragraph)
            let main = CueBuilder(kind: laneKind(paragraph) ?? .lead, language: paragraph.language,
                                  agent: paragraph.agent, start: pTimes.start, end: pTimes.end,
                                  preserveSpace: paragraph.preserveSpace)
            var extras: [CueBuilder] = []
            try collect(paragraph, into: main, timing: nil, extras: &extras)
            if let cue = try main.finish(id: cueID, linked: nil) {
                laneCues[main.key, default: []].append(cue)
            }
            for (extraIndex, extra) in extras.enumerated() {
                if let cue = try extra.finish(id: "\(cueID)-x\(extraIndex)", linked: cueID) {
                    laneCues[extra.key, default: []].append(cue)
                }
            }
        }
        let keys = laneCues.keys.sorted { $0.stableID < $1.stableID }
        let lanes = keys.map { key in
            LyricDomain.Lane(id: key.stableID, kind: key.kind, languageBCP47: key.language,
                cues: laneCues[key, default: []].sorted {
                    ($0.sourceStartMS ?? Int64.max) < ($1.sourceStartMS ?? Int64.max)
                })
        }
        return ParsedLyrics(lanes: lanes)
    }

    private static func validateAndCollect(_ node: XMLLyricNode, depth: Int,
                                           paragraphs: inout [XMLLyricNode]) throws {
        guard depth <= ParserLimits.depth else { throw invalid("TTML is nested too deeply.") }
        if let timeBase = node.attribute("timeBase"), timeBase != "media" {
            throw LyricDomain.SourceFailure.unsupportedTimingProfile
        }
        if let container = node.attribute("timeContainer"), container != "par" {
            throw LyricDomain.SourceFailure.unsupportedTimingProfile
        }
        if node.attribute("frameRate") != nil || node.attribute("tickRate") != nil
            || node.attribute("clockMode") != nil || node.attribute("dropMode") != nil {
            throw LyricDomain.SourceFailure.unsupportedTimingProfile
        }
        // Validate grouping bounds even though Apple/AMLL p/span values are media-absolute.
        if ["body", "div", "p", "span"].contains(node.name) { _ = try times(node) }
        if node.name == "p" {
            guard paragraphs.count < ParserLimits.cues else { throw invalid("Too many TTML cues.") }
            paragraphs.append(node)
        }
        for part in node.content {
            if case let .child(child) = part { try validateAndCollect(child, depth: depth + 1, paragraphs: &paragraphs) }
        }
    }

    private static func time(_ raw: String) throws -> Int64 {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains(":") {
            if value.split(separator: ":").count > 3 { throw LyricDomain.SourceFailure.unsupportedTimingProfile }
            return try LyricTime.clockMS(value)
        }
        if value.hasSuffix("ms") { return try LyricTime.decimalMS(String(value.dropLast(2)), multiplier: 1) }
        if value.hasSuffix("s") { return try LyricTime.decimalMS(String(value.dropLast()), multiplier: 1_000) }
        if value.hasSuffix("m") { return try LyricTime.decimalMS(String(value.dropLast()), multiplier: 60_000) }
        if value.hasSuffix("h") { return try LyricTime.decimalMS(String(value.dropLast()), multiplier: 3_600_000) }
        if value.hasSuffix("f") || value.hasSuffix("t") { throw LyricDomain.SourceFailure.unsupportedTimingProfile }
        return try LyricTime.decimalMS(value)
    }

    private static func times(_ node: XMLLyricNode) throws -> (start: Int64?, end: Int64?) {
        let start = try node.attribute("begin").map(time)
        var end = try node.attribute("end").map(time)
        if let duration = node.attribute("dur") {
            let base: Int64
            if let start { base = start }
            else if node.name == "body" || node.name == "div" { base = 0 }
            else { throw LyricDomain.SourceFailure.unsupportedTimingProfile }
            let durationEnd = try checkedAdd(base, time(duration))
            end = end.map { min($0, durationEnd) } ?? durationEnd
        }
        if let start { try validateTimes(start: start, end: end) }
        // Paragraph end without begin is permitted when an explicit child start supplies it.
        return (start, end)
    }

    private static func laneKind(_ node: XMLLyricNode) -> LyricDomain.LaneKind? {
        switch node.attribute("role") {
        case "x-bg", "background": return .background
        case "x-translation", "translation": return .translation
        case "x-roman", "x-romanization", "romanization": return .romanization
        case "x-ruby", "ruby": return .ruby
        default: return nil
        }
    }

    private static func collect(_ node: XMLLyricNode, into builder: CueBuilder,
                                timing inherited: (start: Int64, end: Int64?)?,
                                extras: inout [CueBuilder]) throws {
        var timing = inherited
        if node.name == "span", let start = try times(node).start {
            timing = (start, try times(node).end)
        }
        for part in node.content {
            switch part {
            case let .text(text): builder.append(text, timing: timing)
            case let .child(child):
                if child.name == "br" { builder.append("\n", timing: timing); continue }
                guard child.name == "span" else { continue }
                if let role = laneKind(child), role != builder.kind {
                    let ownTimes = try times(child)
                    let extra = CueBuilder(kind: role, language: child.language ?? builder.language,
                        agent: child.agent ?? builder.agent, start: ownTimes.start ?? builder.start,
                        end: ownTimes.end ?? builder.end, preserveSpace: child.preserveSpace)
                    try collect(child, into: extra, timing: nil, extras: &extras)
                    extras.append(extra)
                } else { try collect(child, into: builder, timing: timing, extras: &extras) }
            }
        }
    }

    private struct LaneKey: Hashable {
        let kind: LyricDomain.LaneKind
        let language: String?
        let agent: String?
        var stableID: String { "\(kind.rawValue):\(language ?? "und"):\(agent ?? "main")" }
    }
    private final class CueBuilder {
        let kind: LyricDomain.LaneKind
        let language: String?
        let agent: String?
        let start: Int64?
        let end: Int64?
        let preserveSpace: Bool
        var text = ""
        var fragments: [(text: String, offset: Int, start: Int64, end: Int64?)] = []
        var key: LaneKey { .init(kind: kind, language: language, agent: agent) }
        init(kind: LyricDomain.LaneKind, language: String?, agent: String?, start: Int64?, end: Int64?, preserveSpace: Bool) {
            self.kind = kind; self.language = language; self.agent = agent
            self.start = start; self.end = end; self.preserveSpace = preserveSpace
        }
        func append(_ raw: String, timing: (start: Int64, end: Int64?)?) {
            var value = raw
            if !preserveSpace {
                // Pretty-print indentation is not a lyric. An explicit single space is retained.
                if value.contains("\n") && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
                value = value.replacingOccurrences(of: "[\\t\\r\\n ]+", with: " ", options: .regularExpression)
                if text.hasSuffix(" "), value.hasPrefix(" ") { value.removeFirst() }
            }
            guard !value.isEmpty else { return }
            let offset = text.utf16.count
            text += value
            if let timing {
                if let last = fragments.last, last.start == timing.start, last.end == timing.end,
                   last.offset + last.text.utf16.count == offset {
                    fragments[fragments.count - 1].text += value
                } else { fragments.append((value, offset, timing.start, timing.end)) }
            }
        }
        func finish(id: String, linked: String?) throws -> LyricDomain.Cue? {
            let trimmed = preserveSpace ? text : text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let prefix: Int = {
                guard !preserveSpace, let first = text.firstIndex(where: { !$0.isWhitespace }) else { return 0 }
                return first.utf16Offset(in: text)
            }()
            var tokens: [LyricDomain.Token] = []
            for (index, fragment) in fragments.enumerated() {
                let low = max(prefix, fragment.offset)
                let high = min(prefix + trimmed.utf16.count, fragment.offset + fragment.text.utf16.count)
                guard high > low else { continue }
                let range = NSRange(location: low - prefix, length: high - low)
                guard let swiftRange = Range(range, in: trimmed) else { throw invalid("Invalid TTML text boundaries.") }
                tokens.append(.init(id: "\(id)-w\(index)", text: String(trimmed[swiftRange]),
                    rangeInCue: .init(location: range.location, length: range.length),
                    sourceStartMS: fragment.start, sourceEndMS: fragment.end))
            }
            let realStart = start ?? tokens.map(\.sourceStartMS).min()
            var realEnd = end
            if realEnd == nil, !tokens.isEmpty, tokens.allSatisfy({ $0.sourceEndMS != nil }),
               tokens.reduce(0, { $0 + $1.rangeInCue.length }) == trimmed.utf16.count {
                realEnd = tokens.compactMap(\.sourceEndMS).max()
            }
            return .init(id: id, text: trimmed, sourceStartMS: realStart, sourceEndMS: realEnd,
                         tokens: tokens, linkedCueID: linked, agentID: agent)
        }
    }
}

private final class XMLLyricNode {
    enum Part { case text(String), child(XMLLyricNode) }
    let name: String
    let namespace: String
    let attributes: [String: String]
    var content: [Part] = []
    let language: String?
    let agent: String?
    let preserveSpace: Bool
    init(name: String, namespace: String, attributes: [String: String], parent: XMLLyricNode?) {
        self.name = name; self.namespace = namespace; self.attributes = attributes
        language = attributes["xml:lang"] ?? attributes["lang"] ?? parent?.language
        agent = attributes.first(where: { $0.key == "agent" || $0.key.hasSuffix(":agent") })?.value ?? parent?.agent
        preserveSpace = attributes["xml:space"].map { $0 == "preserve" } ?? parent?.preserveSpace ?? false
    }
    func attribute(_ local: String) -> String? {
        attributes[local] ?? attributes.first(where: { $0.key.hasSuffix(":" + local) })?.value
    }
}

private final class BoundedXMLTree: NSObject, XMLParserDelegate {
    var root: XMLLyricNode?
    var stack: [XMLLyricNode] = []
    var nodes = 0
    var failure: LyricDomain.SourceFailure?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        nodes += 1
        guard stack.count < ParserLimits.depth, nodes <= ParserLimits.nodes else {
            failure = invalid("TTML size or nesting limit exceeded."); parser.abortParsing(); return
        }
        // Refuse ambiguous attributes such as begin and an unrelated prefix:begin together.
        let localKeys = attributeDict.keys.map { String($0.split(separator: ":").last ?? "") }
        guard Set(localKeys).count == localKeys.count else {
            failure = invalid("Ambiguous TTML attributes."); parser.abortParsing(); return
        }
        let node = XMLLyricNode(name: elementName, namespace: namespaceURI ?? "", attributes: attributeDict, parent: stack.last)
        if let parent = stack.last { parent.content.append(.child(node)) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.content.append(.text(string)) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else {
            failure = invalid("Invalid TTML CDATA."); parser.abortParsing(); return
        }
        stack.last?.content.append(.text(text))
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        failure = invalid("External XML entities are disabled."); parser.abortParsing(); return nil
    }
}
