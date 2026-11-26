import AppKit
import Foundation
import LyricPlayback

public struct LyricSettings: Codable, Equatable, Sendable {
    public enum Appearance: String, Codable, CaseIterable, Sendable { case automatic, light, dark }
    public var appearance: Appearance = .automatic
    public var largeText = false
    public var showTranslation = false
    public var onlineLyrics = true
    public var hideWhenIdle = true
    public var showInFullScreen = false
    public var coordinateTiles = true
    public var preferredPlayer: String?
    public var preferredDisplayUUID: String?
    public var completedWelcome = false
    public init() {}

    public var player: PlayerID? { preferredPlayer.flatMap(PlayerID.init(rawValue:)) }
    public static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: "LyricTile.settings.v1"),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }
    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "LyricTile.settings.v1") }
    }
}

public enum LyricAuxiliaryPage: String, Identifiable, Sendable {
    case welcome, settings, candidates, adjustment, source, fullLyrics
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .welcome: "欢迎使用 LyricTile"
        case .settings: "LyricTile 设置"
        case .candidates: "选择歌词版本"
        case .adjustment: "歌词时间校准"
        case .source: "歌词来源"
        case .fullLyrics: "完整歌词"
        }
    }
}

public enum LyricPalette {
    public static func primary(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.945, green: 0.945, blue: 0.953, alpha: 1)
             : NSColor(srgbRed: 0.153, green: 0.165, blue: 0.192, alpha: 1)
    }
    public static func secondary(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.761, green: 0.776, blue: 0.812, alpha: 1)
             : NSColor(srgbRed: 0.396, green: 0.416, blue: 0.451, alpha: 1)
    }
}
