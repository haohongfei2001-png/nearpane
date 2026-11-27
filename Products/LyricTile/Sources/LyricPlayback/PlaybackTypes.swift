import Foundation
import LyricCore

public enum PlayerID: String, CaseIterable, Codable, Sendable {
    case appleMusic, spotify, qqMusic, netease
    public var bundleID: String {
        switch self {
        case .appleMusic: "com.apple.Music"
        case .spotify: "com.spotify.client"
        case .qqMusic: "com.tencent.QQMusicMac"
        case .netease: "com.netease.163music"
        }
    }
    public var displayName: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .qqMusic: LyricLocalization.text("QQ 音乐", "QQ Music")
        case .netease: LyricLocalization.text("网易云音乐", "NetEase Cloud Music")
        }
    }
    var usesAppleEvents: Bool { self == .appleMusic || self == .spotify }
    init?(bundleID: String) {
        guard let match = Self.allCases.first(where: { $0.bundleID == bundleID }) else { return nil }
        self = match
    }
}

public struct TransportCapabilities: Sendable, Equatable, Codable {
    public var canPlay: Bool
    public var canPause: Bool
    public var canNext: Bool
    public var canPrevious: Bool
    public var canSeek: Bool
    public init(canPlay: Bool = false, canPause: Bool = false, canNext: Bool = false,
                canPrevious: Bool = false, canSeek: Bool = false) {
        self.canPlay = canPlay; self.canPause = canPause; self.canNext = canNext
        self.canPrevious = canPrevious; self.canSeek = canSeek
    }
    func allows(_ command: TransportCommand) -> Bool {
        switch command {
        case .play: canPlay
        case .pause: canPause
        case .next: canNext
        case .previous: canPrevious
        case .seek: canSeek
        }
    }
}

public struct PlaybackSnapshot: Sendable, Equatable {
    public let player: PlayerID?
    public let selection: LyricDomain.Selection?
    public let anchor: LyricDomain.PlaybackAnchor?
    public let state: LyricDomain.PlaybackState
    public let capabilities: TransportCapabilities
    public let artwork: Data?
    public let statusMessage: String?
    public let requiresAuthorization: Bool
    public init(player: PlayerID?, selection: LyricDomain.Selection?, anchor: LyricDomain.PlaybackAnchor?,
                state: LyricDomain.PlaybackState, capabilities: TransportCapabilities = .init(),
                artwork: Data? = nil, statusMessage: String? = nil, requiresAuthorization: Bool = false) {
        self.player = player; self.selection = selection; self.anchor = anchor; self.state = state
        self.capabilities = capabilities; self.artwork = artwork; self.statusMessage = statusMessage
        self.requiresAuthorization = requiresAuthorization
    }
    public static let empty = PlaybackSnapshot(player: nil, selection: nil, anchor: nil, state: .stopped)
}

public enum TransportCommand: Sendable, Equatable {
    case play, pause, next, previous, seek(milliseconds: Int64)
    var name: String {
        switch self { case .play: "play"; case .pause: "pause"; case .next: "next"; case .previous: "previous"; case .seek: "seek" }
    }
    var remoteCommandID: Int? {
        switch self { case .play: 0; case .pause: 1; case .next: 4; case .previous: 5; case .seek: nil }
    }
}

public enum PlaybackError: Error, LocalizedError, Sendable, Equatable {
    case unavailable(String), authorizationDenied, playerExited, selectionChanged
    case unsupported, ambiguousSession, sourceNotCurrent, commandInProgress
    case malformedPayload, outputLimit, timeout, notConfirmed(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .authorizationDenied: LyricLocalization.text("请在系统设置的“隐私与安全性 → 自动化”允许 LyricTile 连接播放器。", "Allow LyricTile to connect to your player in System Settings → Privacy & Security → Automation.")
        case .playerExited: LyricLocalization.text("播放器已退出。", "The player has quit.")
        case .selectionChanged: LyricLocalization.text("歌曲或播放来源已改变，请重试。", "The track or playback source has changed. Try again.")
        case .unsupported: LyricLocalization.text("当前播放器或歌曲不提供此项控制。", "This control is unavailable for the current player or track.")
        case .ambiguousSession: LyricLocalization.text("播放器存在多个媒体会话，暂时无法确认控制目标。", "The player has multiple media sessions. The control target could not be confirmed.")
        case .sourceNotCurrent: LyricLocalization.text("系统当前媒体来源已改变，请返回原播放器操作。", "The system media source has changed. Use the original player to continue.")
        case .commandInProgress: LyricLocalization.text("正在确认上一个播放操作。", "Confirming the previous playback action.")
        case .malformedPayload: LyricLocalization.text("播放器返回的数据无法识别。", "The player returned unreadable data.")
        case .outputLimit: LyricLocalization.text("播放器数据超过安全大小限制。", "The player returned too much data.")
        case .timeout: LyricLocalization.text("播放器没有及时响应。", "The player did not respond in time.")
        case .notConfirmed(let reason): LyricLocalization.text("尚未确认操作结果：\(reason)", "The action could not be confirmed: \(reason)")
        }
    }
}

struct PlayerProcess: Sendable, Equatable {
    let player: PlayerID
    let pid: Int32
    let startMicros: UInt64
    let version: String
    var build: String = "unknown"
    var identity: String { "\(pid):\(startMicros)" }
}

struct PlayerObservation: Sendable {
    let process: PlayerProcess
    var mediaPID: Int32
    var mediaProcessStart: UInt64
    var title: String?
    var artist: String?
    var album: String?
    var platformID: String?
    var durationMS: Int64?
    var positionMS: Int64?
    var state: LyricDomain.PlaybackState
    var rate: Double
    var stamp: LyricDomain.MonotonicStamp
    var capabilities: TransportCapabilities
    var artwork: Data?
    var artworkURL: URL?
    var sourceIsCurrent: Bool
    var quality: LyricDomain.ClockQuality = .coarseSourceAnchor
    var expectedErrorMS: Int64? = nil
    var restricted: Bool = false
    var clockNeedsReanchor: Bool = false
    var hasRecording: Bool { title?.isEmpty == false || platformID?.isEmpty == false }
    func projectedPosition(at now: LyricDomain.MonotonicStamp) -> Int64? {
        guard let positionMS, now.clockDomainID == stamp.clockDomainID, now.nanoseconds >= stamp.nanoseconds else { return nil }
        let elapsed = Double(now.nanoseconds - stamp.nanoseconds) / 1_000_000
        let value = Double(positionMS) + (state == .playing ? elapsed * rate : 0)
        return MediaTime.clampedMilliseconds(value, duration: durationMS)
    }
}

enum MediaTime {
    // Music seconds, Spotify duration milliseconds, adapter microseconds.
    static func seconds(_ value: Double?) -> Int64? {
        guard let value else { return nil }; return clampedMilliseconds(value * 1000)
    }
    static func micros(_ value: Int64?) -> Int64? {
        guard let value, value >= 0 else { return nil }; return value / 1000
    }
    static func clampedMilliseconds(_ value: Double, duration: Int64? = nil) -> Int64? {
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return nil }
        let result = Int64(value.rounded(.down))
        return duration.map { min(result, $0) } ?? result
    }
    static func seekMicros(_ milliseconds: Int64) throws -> String {
        guard milliseconds >= 0 else { throw PlaybackError.unsupported }
        let (micros, overflow) = milliseconds.multipliedReportingOverflow(by: 1000)
        guard !overflow else { throw PlaybackError.unsupported }
        return String(micros)
    }
}
