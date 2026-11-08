#if canImport(RiftletCore) && canImport(SaytileKit)
import AppKit
import CryptoKit
import NearpaneCore
import NearpaneUI
import RiftletCore
import SaytileKit

/// Both CLI modes address only fresh, marked fixtures in this checkout's ignored build folder.
struct NativeAcceptanceSession {
    let directory: URL
    var support: URL { directory.appendingPathComponent("support") }

    private struct Marker: Codable, Equatable {
        let version: Int
        let session: UUID
        let executableSHA256: String
    }

    init(id: String, prepare: Bool) throws {
        guard let uuid = UUID(uuidString: id), id == uuid.uuidString.lowercased(),
              Bundle.main.bundleURL.pathExtension == "app", let executable = Bundle.main.executableURL else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: fm.currentDirectoryPath)
        guard fm.fileExists(atPath: repo.appendingPathComponent("Dependencies/domains.lock.json").path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let parent = repo.appendingPathComponent("build/native-acceptance")
        directory = parent.appendingPathComponent(id)
        let markerURL = directory.appendingPathComponent("session.json")
        let bytes = try Data(contentsOf: executable, options: .mappedIfSafe)
        let marker = Marker(version: 1, session: uuid, executableSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        if prepare {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            guard parent.resolvingSymlinksInPath().path == parent.path, mkdir(directory.path, 0o700) == 0 else {
                throw CocoaError(.fileWriteFileExists)
            }
            let library = support.appendingPathComponent("Riftlet")
            try fm.createDirectory(at: library, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data().write(to: library.appendingPathComponent("instance.lock"), options: .withoutOverwriting)
            _ = try QueueStore(databaseURL: library.appendingPathComponent("queue.sqlite"))
            try JSONEncoder().encode(marker).write(to: markerURL, options: .withoutOverwriting)
        } else {
            for url in [directory, markerURL, support, support.appendingPathComponent("Nearpane"), support.appendingPathComponent("Riftlet")] {
                guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw CocoaError(.fileReadNoPermission) }
            }
            guard try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL)) == marker else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }
}

/// Observes the actual panel inside the separately invoked acceptance app. Never records text, audio, URLs or screen pixels.
@MainActor final class NativeAcceptanceProbe {
    private let sink: FileHandle
    private var timer: Timer?
    private var notifications: [NSObjectProtocol] = []
    private var last: State?
    private var lastTime = -Double.infinity
    private struct State: Encodable, Equatable {
        let visible, key, active, layoutMatches, hasTranscript, trayConnected, voiceEnabled: Bool
        let voice: String
        let recordings: [UUID]
        let trayCount: Int
        let trayIDs: String
        let pid, windowID: Int
    }
    private struct Event: Encodable {
        let kind: String
        let time, uptime: Double
        let state: State
    }
    init(session: NativeAcceptanceSession, host: HostSession, modules: EmbeddedModules, surface: EdgeWindowController) throws {
        let url = session.directory.appendingPathComponent("events-" + UUID().uuidString.lowercased() + ".jsonl")
        try Data().write(to: url, options: .withoutOverwriting)
        sink = try FileHandle(forWritingTo: url)
        let sample: @MainActor (String) -> Void = { [weak self, weak host, weak modules, weak surface] kind in
            guard let self, let host, let modules, let window = surface?.window else { return }
            let expected = SurfacePlacement.resolve(screens: SystemScreens.geometry(), preferredID: host.configuration.preferredDisplayID,
                                                    edge: host.configuration.edge)
            let layoutMatches = expected.map { abs(window.frame.width - $0.width) <= 1 && abs(window.frame.height - $0.height) <= 1
                && abs(window.frame.minX - $0.x) <= 1 && abs(window.frame.minY - $0.y) <= 1 } ?? false
            let voice: String
            switch modules.voice.capture {
            case .paused: voice = "paused"
            case .starting: voice = "starting"
            case .listening: voice = "standby"
            case .speaking: voice = "speaking"
            case .interrupted: voice = "interrupted"
            }
            let ids = modules.tray.visibleIDs
            let fingerprint = SHA256.hash(data: Data(ids.map(\.uuidString).joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
            self.record(kind, State(visible: window.isVisible, key: window.isKeyWindow, active: NSApp.isActive, layoutMatches: layoutMatches,
                hasTranscript: !modules.voice.transcript.isEmpty, trayConnected: modules.tray.connected, voiceEnabled: modules.voice.active,
                voice: voice, recordings: modules.voice.openRecordingIDs, trayCount: ids.count, trayIDs: fingerprint,
                pid: Int(ProcessInfo.processInfo.processIdentifier), windowID: window.windowNumber))
        }
        modules.voice.acceptanceEvent = sample
        sample("opened")
        for (name, object, kind) in [(NSWindow.didBecomeKeyNotification, surface.window as AnyObject?, "panelBecameKey"),
                                     (NSApplication.didBecomeActiveNotification, NSApp as AnyObject?, "appActivated")] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
                MainActor.assumeIsolated { sample(kind) }
            })
        }
        let timer = Timer(timeInterval: 0.3, repeats: true) { _ in MainActor.assumeIsolated { sample("sample") } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func record(_ kind: String, _ state: State) {
        let now = ProcessInfo.processInfo.systemUptime
        guard kind != "sample" || state != last || now - lastTime >= 5 else { return }
        do {
            var bytes = try JSONEncoder().encode(Event(kind: kind, time: Date().timeIntervalSince1970, uptime: now, state: state))
            bytes.append(10)
            try sink.write(contentsOf: bytes)
            last = state
            lastTime = now
        } catch { timer?.invalidate(); NSLog("Native acceptance evidence write failed") }
    }
    func finish() {
        timer?.invalidate()
        notifications.forEach(NotificationCenter.default.removeObserver)
        if let last { record("drained", last) }
        try? sink.close()
    }
}
#endif
