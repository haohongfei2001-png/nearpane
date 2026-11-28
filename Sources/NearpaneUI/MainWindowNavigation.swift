import Foundation
import NearpaneCore
import Observation

enum MainWindowSection: String, CaseIterable, Identifiable {
    case modules, library, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .modules: "模块"
        case .library: "仓库"
        case .settings: "设置"
        }
    }
    var symbol: String {
        switch self {
        case .modules: "square.grid.2x2"
        case .library: "tray.full"
        case .settings: "slider.horizontal.3"
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case modules, module, voice, tray, lyrics, windowManagement, windowRules, desktop
    case voiceArchive, screenshotArchive, memoArchive, tasksArchive, wordArchive
    case general, dimensions, displays, permissions, data, app, diagnostics
    var id: Self { self }
    var section: MainWindowSection {
        switch self {
        case .modules, .module, .voice, .tray, .lyrics, .windowManagement, .windowRules, .desktop: .modules
        case .voiceArchive, .screenshotArchive, .memoArchive, .tasksArchive, .wordArchive: .library
        default: .settings
        }
    }
    var label: String {
        switch self {
        case .modules: "模块"
        case .module: "模块详情"
        case .voice: "语音"
        case .tray: "截图"
        case .lyrics: "歌词"
        case .windowManagement, .windowRules, .desktop: "空间调度"
        case .voiceArchive: "语音"
        case .screenshotArchive: "截图"
        case .memoArchive, .tasksArchive: "随手记"
        case .wordArchive: "单词本"
        case .general: "通用"
        case .dimensions: "外观与布局"
        case .displays: "显示器与位置"
        case .permissions: "权限"
        case .data: "资料管理"
        case .app: "关于与更新"
        case .diagnostics: "开发诊断"
        }
    }
    var navigationLabel: String { label }
    var symbol: String {
        switch self {
        case .modules, .module: "square.grid.2x2"
        case .voice, .voiceArchive: "waveform"
        case .tray, .screenshotArchive: "photo.on.rectangle"
        case .lyrics: "music.note"
        case .windowManagement, .desktop: "rectangle.on.rectangle"
        case .windowRules: "list.bullet"
        case .memoArchive, .tasksArchive: "note.text"
        case .wordArchive: "character.book.closed"
        case .general: "gearshape"
        case .dimensions: "slider.horizontal.3"
        case .displays: "display"
        case .permissions: "hand.raised"
        case .data: "externaldrive"
        case .app: "info.circle"
        case .diagnostics: "wrench.and.screwdriver"
        }
    }
}

/// Navigation has no window ownership. Every entry point selects a route in the
/// Host's retained main window; switching sections preserves the last content page.
@Observable @MainActor public final class SettingsNavigation {
    var page = SettingsPage.modules {
        didSet {
            if page.section == .library { lastLibrary = page }
            if page.section == .settings { lastSettings = page }
        }
    }
    private var lastLibrary = SettingsPage.voiceArchive
    private var lastSettings = SettingsPage.general
    private var genericModuleID: String?
    private(set) var lyricsPage = "settings"
    public private(set) var notebookFilter = "all"
    public private(set) var selectedNotebookRecordID: UUID?
    /// Repeating a sidebar deep link must refocus that record even after local list selection changed.
    public private(set) var notebookNavigationRevision: UInt64 = 0
    var section: MainWindowSection { page.section }
    public var routeID: String { page.rawValue }
    public var selectedPageIdentifier: String { page.rawValue }
    public var selectedSectionIdentifier: String { section.rawValue }
    public var moduleID: String? {
        switch page {
        case .voice: BuiltinCatalog.voice
        case .tray: BuiltinCatalog.screenshots
        case .lyrics: BuiltinCatalog.lyrics
        case .windowManagement, .windowRules, .desktop: BuiltinCatalog.desktop
        case .module: genericModuleID
        default: nil
        }
    }
    public init() {}
    func select(_ section: MainWindowSection) {
        switch section {
        case .modules: showModules()
        case .library: showLibrary()
        case .settings: page = lastSettings
        }
    }
    public func showModules() { page = .modules }
    public func showLibrary() { page = lastLibrary }
    public func showAppearance() { page = .dimensions }
    public func showDisplays() { page = .displays }
    public func showVoiceArchive() { page = .voiceArchive }
    public func showScreenshotArchive() { page = .screenshotArchive }
    public func showGeneral() { page = .general }
    public func showPermissions() { page = .permissions }
    public func showData() { page = .data }
    public func showApplicationServices() { page = .app }
    public func showDesktop() { page = .desktop }
    public func showWindowManagement() { page = .windowManagement }
    public func showNotebookLibrary(_ kind: String = "all", recordID: UUID? = nil) {
        if kind == "words" || kind == "vocabulary" {
            page = .wordArchive
            return
        }
        // Sidebar details reuse the same route rather than opening a module window.
        notebookNavigationRevision &+= 1
        let linkedID = kind.hasPrefix("record:") ? UUID(uuidString: String(kind.dropFirst("record:".count))) : nil
        selectedNotebookRecordID = recordID ?? linkedID
        switch kind {
        case "notes": notebookFilter = "notes"
        case "tasks", "pending", "unfinished": notebookFilter = "unfinished"
        case "completed": notebookFilter = "completed"
        default: notebookFilter = "all"
        }
        // An exact record must stay reachable even if its kind/completion has changed.
        if selectedNotebookRecordID != nil { notebookFilter = "all" }
        page = .memoArchive
    }
    public func showNotebookRecord(_ id: UUID) { showNotebookLibrary(recordID: id) }
    public func showModule(_ id: String) {
        switch id {
        case BuiltinCatalog.voice: page = .voice
        case BuiltinCatalog.screenshots: page = .tray
        case BuiltinCatalog.lyrics: showLyrics()
        case BuiltinCatalog.desktop: page = .windowManagement
        default: genericModuleID = id == BuiltinCatalog.tasks ? BuiltinCatalog.memo : id; page = .module
        }
    }
    public func showModule(id: String) { showModule(id) }
    public func showLyrics(_ detail: String = "settings") {
        let allowed = ["settings", "welcome", "fullLyrics", "source", "adjustment", "candidates"]
        lyricsPage = allowed.contains(detail) ? detail : "settings"
        page = .lyrics
    }
}

enum ModulePresentation {
    static func title(_ manifest: ModuleManifest) -> String {
        switch manifest.id {
        case BuiltinCatalog.voice: "语音"
        case BuiltinCatalog.screenshots: "截图"
        case BuiltinCatalog.lyrics: "歌词"
        case BuiltinCatalog.desktop: "空间调度"
        default: manifest.name
        }
    }
    static func brand(_ id: String) -> String? {
        switch id {
        case BuiltinCatalog.voice: "Saytile"
        case BuiltinCatalog.screenshots: "Riftlet"
        case BuiltinCatalog.lyrics: "LyricTile"
        case BuiltinCatalog.desktop: "Spaces"
        case BuiltinCatalog.memo: "Notes"
        default: nil
        }
    }
    static func status(_ state: ModuleState) -> String? {
        switch state {
        case .enabling: "正在启动"
        case .permissionRequired: "需要授权"
        case .suspended: "已暂停"
        case .degraded: "暂不可用"
        default: nil
        }
    }
}
