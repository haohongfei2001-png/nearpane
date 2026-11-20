import AppKit
import Security

/// Routes only the adapter present in the pinned release. Other known origins cannot inherit its writer.
enum DraftBrowser: String, CaseIterable, Codable {
    case chrome = "com.google.Chrome"
    case edge = "com.microsoft.edgemac"
    case safari = "com.apple.Safari"
}
enum DraftService: String, CaseIterable, Codable {
    case chatGPT = "chatgpt.com"
    case claude = "claude.ai"
    case gemini = "gemini.google.com"
    case deepSeek = "chat.deepseek.com"
}
struct DraftCapability: Equatable {
    let browser: DraftBrowser
    let service: DraftService
    var writerID: String? { browser == .chrome && service == .chatGPT ? "chatgpt-web" : nil }
    static func route(browserID: String, url: URL) -> Self? {
        guard let browser = DraftBrowser(rawValue: browserID), url.scheme == "https", url.user == nil, url.password == nil,
            url.port == nil,
            let host = url.host, let service = DraftService(rawValue: host)
        else { return nil }
        return Self(browser: browser, service: service)
    }
    func acceptsSelectedDraft(_ url: URL) -> Bool {
        guard Self.route(browserID: browser.rawValue, url: url) == self, writerID != nil else { return false }
        return url.path.isEmpty || url.path == "/"
            || url.path.range(of: #"^/c/[A-Za-z0-9-]+/?$"#, options: .regularExpression) != nil
    }
}

/// Reported only after a PID/window/tab read. A single passive snapshot cannot prove upload or count send events.
struct DraftSurface: Codable, Equatable, Sendable {
    let service: String
    let accountControl, loginControl: Bool
    let authenticated, blankEditorAtFreshRoute: Bool?
    let editorPresent, uniqueEditor: Bool
    let ownedFileControl: Bool?
    let modal: Bool
    let pickerAccepted, attachmentRendered, uploadComplete: Bool?
    let sendEvents: Int?
}

struct DraftAddress: Codable, Equatable, Sendable {
    let browser: DraftBrowser
    let pid: Int32
    let processBirth: UInt64
    let windowID: String
    let tabID: String?
}
struct DraftBoundSurface: Codable, Equatable, Sendable {
    let address: DraftAddress
    let surface: DraftSurface
}
enum DraftCapabilityFailure: Error {
    case indexedTab(DraftAddress?)
    case noWriter(DraftCapability, DraftBoundSurface)
    case loginRequired(DraftBoundSurface)
    case readUnavailable(DraftBrowser)
    var notice: String {
        switch self {
        case .indexedTab: "此版本无法稳定绑定 Safari 的标签页，截图已保留。"
        case .loginRequired: "当前草稿页面显示需要登录，截图已保留。"
        case .noWriter(let route, _): "当前版本尚未启用 " + route.browser.name + " 的 " + route.service.rawValue + " 草稿附加。"
        case .readUnavailable(let browser): "未取得 " + browser.name + " 当前草稿的只读能力，截图已保留。"
        }
    }
}

extension DraftBrowser {
    var name: String {
        switch self {
        case .chrome: "Chrome"
        case .edge: "Edge"
        case .safari: "Safari"
        }
    }
    var hasStableTabID: Bool { self != .safari }
    func signed(pid: pid_t) -> Bool {
        let signer: String
        switch self {
        case .chrome: signer = #"anchor apple generic and certificate leaf[subject.OU] = "EQHXZ8M8AV""#
        case .edge: signer = #"anchor apple generic and certificate leaf[subject.OU] = "UBF8T346G9""#
        case .safari: signer = "anchor apple"
        }
        var requirement: SecRequirement?
        var process: SecCode?
        let rule = signer + " and identifier \"" + rawValue + "\""
        return SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess
            && SecCodeCopyGuestWithAttributes(
                nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary, [], &process) == errSecSuccess
            && process.map { SecCodeCheckValidity($0, [], requirement) == errSecSuccess } == true
    }
}
extension DraftCapability {
    func readOnlyScript(guardSource: String) -> String {
        // A typed enum supplies the supported host literal.
        "(" + guardSource + ")(null,{action:'inspectCapabilities',host:'" + service.rawValue + "'})"
    }
}
