import Foundation

/// Product destinations describe user content, never implementation caches.
public enum ModuleLibraryKind: String, CaseIterable, Sendable {
    case voice, screenshots, notes, tasks, vocabulary
}

public struct ModuleCapabilities: Equatable, Sendable {
    public let sidebar: Bool
    public let settings: Bool
    public let library: ModuleLibraryKind?
    public init(sidebar: Bool = true, settings: Bool = true, library: ModuleLibraryKind? = nil) {
        self.sidebar = sidebar; self.settings = settings; self.library = library
    }
}

extension ModuleManifest {
    public var capabilities: ModuleCapabilities {
        switch id {
        case BuiltinCatalog.voice: .init(library: .voice)
        case BuiltinCatalog.screenshots: .init(library: .screenshots)
        case BuiltinCatalog.memo: .init(library: .notes)
        case BuiltinCatalog.tasks: .init(library: .tasks)
        default: .init()
        }
    }

    public var summary: String {
        switch id {
        case BuiltinCatalog.voice: "随时表达，把连续讲话整理成自然段。"
        case BuiltinCatalog.screenshots: "收录截图，点按附加或拖入正在使用的应用。"
        case BuiltinCatalog.desktop: "在侧栏查看、切换和组合当前桌面的窗口。"
        case BuiltinCatalog.lyrics: "跟随音乐显示歌词，暂停后仍可就地继续播放。"
        case BuiltinCatalog.memo: "随手记下想法，保留工作中的片段。"
        case BuiltinCatalog.tasks: "记下下一步，在工作现场勾选完成。"
        case BuiltinCatalog.clock: "查看当地或指定时区的时间。"
        default: name
        }
    }
}
