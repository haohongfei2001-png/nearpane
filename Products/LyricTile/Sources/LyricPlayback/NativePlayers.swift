import Foundation
import LyricCore
#if os(macOS)
import AppKit
import CPlayerBridge
#endif

final class AppleEventClient: @unchecked Sendable {
    static let revision = "holdsnow-appleevents-v1"
    private let queue = DispatchQueue(label: "com.holdsnow.lyrictile.apple-events", qos: .utility)
    func read(_ process: PlayerProcess, artwork: Bool = false) async throws -> PlayerObservation {
        #if os(macOS)
        let data: Data = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: LTPReadPlayer(process.pid, process.player == .spotify, artwork)) }
        }
        let received = PlaybackClock.now()
        let response = try JSONDecoder().decode(BridgeResponse.self, from: data)
        try response.checkError()
        let state = LyricDomain.PlaybackState(rawValue: response.state ?? "unknown") ?? .unknown
        let duration = process.player == .spotify
            ? response.duration.flatMap { MediaTime.clampedMilliseconds($0) }
            : MediaTime.seconds(response.duration)
        var position = MediaTime.seconds(response.positionSeconds)
        if state == .playing, let sampled = response.sampleEpochMicros, let raw = position {
            let age = Date().timeIntervalSince1970 - Double(sampled) / 1_000_000
            if age >= 0, age <= 2 { position = MediaTime.clampedMilliseconds(Double(raw) + age * 1000, duration: duration) }
            else { position = nil }
        }
        let artworkData = response.artworkBase64.flatMap { Data(base64Encoded: $0) }
        // Scripts can declare a route while an individual ad/stream cannot execute
        // it. Readback failures revoke that operation for the current recording.
        let hasTrack = response.title?.isEmpty == false || response.trackID?.isEmpty == false
        let restricted = (response.trackID ?? response.spotifyURL ?? "").hasPrefix("spotify:ad:")
        let capabilities = TransportCapabilities(canPlay: state != .unknown,
            canPause: state != .unknown, canNext: hasTrack && !restricted, canPrevious: hasTrack && !restricted,
            canSeek: position != nil && (duration ?? 0) > 0 && hasTrack && !restricted)
        return PlayerObservation(process: process, mediaPID: process.pid, mediaProcessStart: process.startMicros,
            title: response.title, artist: response.artist, album: response.album,
            platformID: response.persistentID ?? response.trackID ?? response.spotifyURL,
            durationMS: duration, positionMS: position, state: state, rate: state == .playing ? 1 : 0,
            stamp: received, capabilities: capabilities,
            artwork: artworkData.flatMap { $0.count <= 8 * 1024 * 1024 ? $0 : nil },
            artworkURL: response.artworkURL.flatMap { URL(string: $0) }, sourceIsCurrent: false,
            quality: position == nil ? .unavailable : .coarseSourceAnchor, restricted: restricted)
        #else
        throw PlaybackError.unavailable(LyricLocalization.text("Apple Events 需要 macOS。", "Apple Events requires macOS."))
        #endif
    }
    func send(_ command: TransportCommand, to process: PlayerProcess) async throws {
        #if os(macOS)
        guard process.startMicros != 0, LTPProcessStartMicros(process.pid) == process.startMicros else { throw PlaybackError.playerExited }
        let seconds: Double
        if case .seek(let milliseconds) = command {
            guard milliseconds >= 0 else { throw PlaybackError.unsupported }; seconds = Double(milliseconds) / 1000
        } else { seconds = 0 }
        let data: Data = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: LTPCommandPlayer(process.pid, process.player == .spotify, command.name, seconds)) }
        }
        let response = try JSONDecoder().decode(BridgeResponse.self, from: data)
        try response.checkError()
        guard response.accepted == true else { throw PlaybackError.notConfirmed(LyricLocalization.text("播放器没有确认接收", "The player did not confirm the command.")) }
        #else
        throw PlaybackError.unavailable(LyricLocalization.text("Apple Events 需要 macOS。", "Apple Events requires macOS."))
        #endif
    }
    func release() async {
        #if os(macOS)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { LTPReleasePlayers(); continuation.resume() }
        }
        #endif
    }
}

private struct BridgeResponse: Decodable, Sendable {
    var errorCode: Int?
    var error: String?
    var accepted: Bool?
    var state: String?
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    var positionSeconds: Double?
    var sampleEpochMicros: Int64?
    var persistentID: String?
    var trackID: String?
    var spotifyURL: String?
    var artworkURL: String?
    var artworkBase64: String?
    func checkError() throws {
        guard let errorCode else { return }
        switch errorCode {
        case -1743: throw PlaybackError.authorizationDenied
        case -600: throw PlaybackError.playerExited
        case -1712: throw PlaybackError.timeout
        case -1708: throw PlaybackError.unsupported
        case -10001: throw PlaybackError.selectionChanged
        default: throw PlaybackError.unavailable(error ?? "Apple Events error \(errorCode)")
        }
    }
}

enum EnvironmentSignal: Sendable { case playersChanged, playbackChanged, sleep, wake }

@MainActor enum PlayerEnvironment {
    static func systemBuild() -> String {
        #if os(macOS)
        return LTPSystemBuild()
        #else
        return "unsupported"
        #endif
    }
    static func running() -> [PlayerProcess] {
        #if os(macOS)
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let bundle = app.bundleIdentifier, let id = PlayerID(bundleID: bundle) else { return nil }
            let bundleInfo = app.bundleURL.flatMap(Bundle.init(url:))
            let version = bundleInfo?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = bundleInfo?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            return PlayerProcess(player: id, pid: app.processIdentifier, startMicros: LTPProcessStartMicros(app.processIdentifier), version: version, build: build)
        }
        #else
        return []
        #endif
    }
    static func processStart(_ pid: Int32) -> UInt64 {
        #if os(macOS)
        return LTPProcessStartMicros(pid)
        #else
        return 0
        #endif
    }
    static func open(_ player: PlayerID) async {
        #if os(macOS)
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).first {
            running.activate(); return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        #endif
    }
}

@MainActor final class PlaybackEnvironmentObserver {
    #if os(macOS)
    private var workspaceTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    #endif
    init(sink: @escaping @Sendable (EnvironmentSignal) -> Void) {
        #if os(macOS)
        let center = NSWorkspace.shared.notificationCenter
        for (name, signal) in [(NSWorkspace.didLaunchApplicationNotification, EnvironmentSignal.playersChanged),
                               (NSWorkspace.didTerminateApplicationNotification, .playersChanged),
                               (NSWorkspace.willSleepNotification, .sleep), (NSWorkspace.didWakeNotification, .wake)] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in sink(signal) })
        }
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            distributedTokens.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in sink(.playbackChanged) })
        }
        #endif
    }
    func stop() {
        #if os(macOS)
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        for token in distributedTokens { DistributedNotificationCenter.default().removeObserver(token) }
        workspaceTokens.removeAll(); distributedTokens.removeAll()
        #endif
    }
}
