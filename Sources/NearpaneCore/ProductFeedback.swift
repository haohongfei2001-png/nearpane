import Foundation

public enum ProductFeedbackKind: String, Codable, CaseIterable, Sendable {
    case problem, suggestion

    public var label: String { self == .problem ? "遇到问题" : "改进建议" }
}

public enum ProductFeedbackArea: String, Codable, CaseIterable, Sendable {
    case general, voice, screenshots, windows, appearance, updates

    public var label: String {
        switch self {
        case .general: return "整体体验"
        case .voice: return "语音与文字"
        case .screenshots: return "截图与附件"
        case .windows: return "窗口与工作空间"
        case .appearance: return "外观与交互"
        case .updates: return "更新与资料导入"
        }
    }
}

public enum ProductFeedbackError: Error, Equatable {
    case empty, tooLong, stalePreview, unavailable
}

public struct ProductFeedbackContent: Equatable, Sendable {
    public var kind: ProductFeedbackKind = .problem
    public var area: ProductFeedbackArea = .general
    public var text = ""
    public var includeSystemVersion = false

    public init() {}

    /// The shared receiver accepts a fixed v1 envelope. Product and component
    /// are immutable leading fields in its previewed text, without a new schema.
    public func body(systemVersion: String) -> String {
        let system = includeSystemVersion ? Self.numericVersion(systemVersion) : "not-included"
        return "product=Nearpane\ncomponent=\(area.rawValue)\nmacOS=\(system)\n\n" + text
    }

    public func preview(appVersion: String, systemVersion: String, revision: Int64) throws -> ProductFeedbackPreview {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProductFeedbackError.empty }
        let body = body(systemVersion: systemVersion)
        guard body.unicodeScalars.count <= 4000, body.utf8.count <= 16384 else { throw ProductFeedbackError.tooLong }
        return ProductFeedbackPreview(body: body, appVersion: Self.numericVersion(appVersion), kind: kind, revision: revision)
    }

    public static func restore(body: String, kind: ProductFeedbackKind) -> Self {
        var content = Self()
        content.kind = kind
        let lines = body.components(separatedBy: "\n")
        guard lines.count >= 5, lines[0] == "product=Nearpane", lines[1].hasPrefix("component="),
              let area = ProductFeedbackArea(rawValue: String(lines[1].dropFirst("component=".count))),
              lines[2].hasPrefix("macOS="), lines[3].isEmpty else {
            content.text = body
            return content
        }
        content.area = area
        content.includeSystemVersion = lines[2] != "macOS=not-included"
        content.text = lines.dropFirst(4).joined(separator: "\n")
        return content
    }

    static func numericVersion(_ value: String) -> String {
        value.range(of: #"^[0-9]{1,4}(\.[0-9]{1,4}){0,3}$"#, options: .regularExpression) != nil ? value : "0"
    }
}

public struct ProductFeedbackPreview: Equatable, Sendable {
    public let body: String
    public let appVersion: String
    public let kind: ProductFeedbackKind
    public let revision: Int64
}
