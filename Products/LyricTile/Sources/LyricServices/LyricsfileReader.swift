import Foundation
import LyricCore
import Yams

enum LyricsfileReader {
    static func parse(_ text: String) throws -> ParsedLyrics {
        try YAMLPreflight.check(text)
        let parser: Yams.Parser
        let root: Node
        do {
            parser = try Yams.Parser(yaml: text, encoding: .utf8)
            guard let parsed = try parser.singleRoot() else { throw invalid("Empty Lyricsfile.") }
            root = parsed
        } catch let error as LyricDomain.SourceFailure { throw error }
        catch { throw invalid("Invalid YAML or duplicate mapping keys.") }
        // Keep the parser alive: its anchor table owns Yams' weak anchor references.
        return try withExtendedLifetime(parser) {
            var nodeCount = 0
            try validateYAML(root, depth: 0, count: &nodeCount)
            let top = try mapping(root)
            guard try requiredString(top, "version") == "1.0" else {
                throw LyricDomain.SourceFailure.unsupportedFormat
            }
            guard let metadataNode = top["metadata"] else { throw invalid("Missing Lyricsfile metadata.") }
            let metadata = try mapping(metadataNode)
            _ = try requiredString(metadata, "title")
            _ = try requiredString(metadata, "artist")
            _ = try optionalString(metadata, "album")
            if let duration = try optionalInt(metadata, "duration_ms"), duration < 0 {
                throw invalid("Negative recording duration.")
            }
            let language = try optionalString(metadata, "language")
            let offset = try optionalInt(metadata, "offset_ms")
            let instrumental = try optionalBool(metadata, "instrumental") ?? false
            let plain = try optionalString(top, "plain")
            var cues: [LyricDomain.Cue] = []
            if let lines = top["lines"], lines.tag.rawValue != Tag.Name.null.rawValue {
                guard let sequence = lines.sequence else { throw invalid("Lyricsfile lines must be a sequence.") }
                guard sequence.count <= ParserLimits.cues else { throw invalid("Too many Lyricsfile lines.") }
                for (lineIndex, lineNode) in sequence.enumerated() {
                    let line = try mapping(lineNode)
                    let lineText = try requiredString(line, "text")
                    let start = try requiredInt(line, "start_ms")
                    let end = try optionalInt(line, "end_ms")
                    let id = "lyricsfile-\(lineIndex)"
                    var tokens: [LyricDomain.Token] = []
                    var joined = ""
                    var joinedUTF16Count = 0
                    if let words = line["words"], words.tag.rawValue != Tag.Name.null.rawValue {
                        guard let sequence = words.sequence else { throw invalid("Lyricsfile words must be a sequence.") }
                        guard sequence.count <= ParserLimits.tokens else { throw invalid("Too many word timings.") }
                        for (index, wordNode) in sequence.enumerated() {
                            let word = try mapping(wordNode)
                            let wordText = try requiredString(word, "text")
                            tokens.append(.init(id: "\(id)-w\(index)", text: wordText,
                                rangeInCue: .init(location: joinedUTF16Count, length: wordText.utf16.count),
                                sourceStartMS: try requiredInt(word, "start_ms"),
                                sourceEndMS: try optionalInt(word, "end_ms")))
                            joined += wordText
                            joinedUTF16Count += wordText.utf16.count
                        }
                        if !tokens.isEmpty && joined != lineText {
                            throw invalid("Word text does not reconstruct the Lyricsfile line exactly.")
                        }
                    }
                    cues.append(.init(id: id, text: lineText, sourceStartMS: start, sourceEndMS: end,
                                      tokens: tokens, linkedCueID: nil, agentID: nil))
                }
            }
            let timing = LyricDomain.SourceTiming(sourceAdvanceMS: offset == nil ? 0 : nil,
                interpretation: offset == nil ? .absent : .unresolved, rawOffset: offset.map(String.init))
            if instrumental {
                guard cues.isEmpty, plain?.isEmpty != false else {
                    throw invalid("Instrumental Lyricsfile contains vocal text.")
                }
                return ParsedLyrics(lanes: [], timing: timing, instrumental: true)
            }
            if !cues.isEmpty {
                cues.sort { ($0.sourceStartMS ?? 0) < ($1.sourceStartMS ?? 0) }
                return ParsedLyrics(lanes: [.init(id: "lead", kind: .lead, languageBCP47: language, cues: cues)], timing: timing)
            }
            guard let plain else { throw invalid("Lyricsfile contains neither synchronized nor plain lyrics.") }
            var result = try PlainReader.parse(plain)
            result.timing = timing
            return result
        }
    }

    private static func validateYAML(_ node: Node, depth: Int, count: inout Int) throws {
        count += 1
        guard depth <= ParserLimits.depth, count <= ParserLimits.nodes else {
            throw invalid("YAML nesting or node limit exceeded.")
        }
        guard node.anchor == nil else { throw invalid("YAML anchors and aliases are disabled.") }
        switch node {
        case .alias: throw invalid("YAML aliases are disabled.")
        case .scalar:
            guard [Tag.Name.str, .int, .bool, .null].map(\.rawValue).contains(node.tag.rawValue) else {
                throw invalid("Lyricsfile allows only strings, integers, booleans and null scalars.")
            }
        case let .sequence(sequence):
            guard node.tag.rawValue == Tag.Name.seq.rawValue else { throw invalid("Custom YAML tags are disabled.") }
            for child in sequence { try validateYAML(child, depth: depth + 1, count: &count) }
        case let .mapping(mapping):
            guard node.tag.rawValue == Tag.Name.map.rawValue else { throw invalid("Custom YAML tags are disabled.") }
            var keys: Set<String> = []
            for pair in mapping {
                guard pair.key.tag.rawValue == Tag.Name.str.rawValue, let key = pair.key.string, keys.insert(key).inserted else {
                    throw invalid("Lyricsfile keys must be unique strings.")
                }
                try validateYAML(pair.value, depth: depth + 1, count: &count)
            }
        }
    }
    private static func mapping(_ node: Node) throws -> Node.Mapping {
        guard let mapping = node.mapping else { throw invalid("Expected a YAML mapping.") }
        return mapping
    }
    private static func requiredString(_ map: Node.Mapping, _ key: String) throws -> String {
        guard let node = map[key], node.tag.rawValue == Tag.Name.str.rawValue, let value = node.string else {
            throw invalid("\(key) must be a string.")
        }
        return value
    }
    private static func optionalString(_ map: Node.Mapping, _ key: String) throws -> String? {
        guard let node = map[key], node.tag.rawValue != Tag.Name.null.rawValue else { return nil }
        return try requiredString(map, key)
    }
    private static func requiredInt(_ map: Node.Mapping, _ key: String) throws -> Int64 {
        guard let node = map[key], node.tag.rawValue == Tag.Name.int.rawValue, let value = node.int else {
            throw invalid("\(key) must be an integer.")
        }
        return Int64(value)
    }
    private static func optionalInt(_ map: Node.Mapping, _ key: String) throws -> Int64? {
        guard let node = map[key], node.tag.rawValue != Tag.Name.null.rawValue else { return nil }
        return try requiredInt(map, key)
    }
    private static func optionalBool(_ map: Node.Mapping, _ key: String) throws -> Bool? {
        guard let node = map[key], node.tag.rawValue != Tag.Name.null.rawValue else { return nil }
        guard node.tag.rawValue == Tag.Name.bool.rawValue, let value = node.bool else { throw invalid("\(key) must be a boolean.") }
        return value
    }
}

/// A bounded lexical safety pass before Yams builds a tree. Actual YAML interpretation is Yams'.
/// Quoted/block strings remain data; aliases, complex keys and excessive containers are rejected.
private enum YAMLPreflight {
    static func check(_ source: String) throws {
        var quote: UInt8?
        var escaped = false
        var flowDepth = 0
        var indentStack = [0]
        var blockIndent: Int?
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let bytes = Array(line.utf8)
            let indent = bytes.prefix { $0 == 32 }.count
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let block = blockIndent {
                if indent > block { continue }
                blockIndent = nil
            }
            if quote == nil && flowDepth == 0 && !trimmed.hasPrefix("#") {
                while indentStack.count > 1 && indent < indentStack.last! { indentStack.removeLast() }
                if indent > indentStack.last! { indentStack.append(indent) }
                if trimmed.hasPrefix("? ") || trimmed.hasPrefix("%TAG") { throw invalid("Complex YAML keys/tags are unsupported.") }
                var compactSequences = 0
                var rest = trimmed[...]
                while rest.hasPrefix("- ") {
                    compactSequences += 1
                    rest = rest.dropFirst(2).drop(while: { $0 == " " })
                }
                guard indentStack.count + compactSequences <= ParserLimits.depth else { throw invalid("YAML nesting limit exceeded.") }
            }
            var index = 0
            var visible = ""
            while index < bytes.count {
                let byte = bytes[index]
                if let currentQuote = quote {
                    if currentQuote == 34 && escaped { escaped = false; index += 1; continue }
                    if currentQuote == 34 && byte == 92 { escaped = true; index += 1; continue }
                    if byte == currentQuote {
                        if currentQuote == 39 && index + 1 < bytes.count && bytes[index + 1] == 39 {
                            index += 2; continue
                        }
                        quote = nil
                    }
                    index += 1; continue
                }
                let boundary = index == 0 || [UInt8(32), 9, 58, 44, 91, 123, 45].contains(bytes[index - 1])
                if byte == 35 && (index == 0 || bytes[index - 1] == 32 || bytes[index - 1] == 9) { break }
                if (byte == 34 || byte == 39) && boundary { quote = byte; index += 1; continue }
                if (byte == 38 || byte == 42) && boundary && index + 1 < bytes.count,
                   ![UInt8(32), 9, 44, 93, 125].contains(bytes[index + 1]) {
                    throw invalid("YAML anchors and aliases are disabled; quote literal text containing these tokens.")
                }
                if byte == 91 || byte == 123 { flowDepth += 1 }
                if byte == 93 || byte == 125 { flowDepth -= 1 }
                guard flowDepth >= 0, flowDepth + indentStack.count <= ParserLimits.depth else {
                    throw invalid("YAML flow nesting limit exceeded.")
                }
                if byte < 128 { visible.append(Character(UnicodeScalar(byte))) }
                index += 1
            }
            if quote == nil && flowDepth == 0,
               visible.range(of: #"(^|[:\-]\s*)[|>][1-9+\-]*\s*$"#, options: .regularExpression) != nil {
                blockIndent = indent
            }
        }
    }
}
