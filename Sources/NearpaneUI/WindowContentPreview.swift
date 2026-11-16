import AppKit
import NearpaneCore
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// A still is opt-in, held only in memory and never used as an action identity.
struct PreviewWindowBinding: Equatable {
    let session: UUID
    let topology: String
    let display: String
    let membership: WindowMembership
    let currentRecord: SpaceRecord?
    let pid: pid_t
    let birth: UInt64
    let number: CGWindowID
    let bounds: SurfaceRect

    init?(_ snapshot: DesktopSnapshot, window: WindowObservation) {
        guard window.canWitnessCurrentSpace, let m = window.metadata, let birth = m.launchMicroseconds,
              let screen = snapshot.displays.first(where: { $0.id == window.displayID }), let usable = screen.usable,
              m.globalFrame.x >= screen.frame.x + usable.x, m.globalFrame.y >= screen.frame.y + usable.y,
              m.globalFrame.x + m.globalFrame.width <= screen.frame.x + usable.x + usable.width,
              m.globalFrame.y + m.globalFrame.height <= screen.frame.y + usable.y + usable.height else { return nil }
        let currents = snapshot.scopes.filter { $0.displayID == screen.id }.flatMap(\.records).filter(\.isCurrent)
        guard currents.count <= 1 else { return nil }
        currentRecord = currents.first
        membership = window.membership
        session = snapshot.sessionID; topology = snapshot.topologyFingerprint; display = screen.id
        pid = m.pid; self.birth = birth; number = m.number; bounds = m.globalFrame
    }

    func confirms(_ pair: AdmissionPair, id: ManagedWindowID) -> Bool {
        guard id.pid == pid, id.launch == birth, id.number == number,
              pair.first.liveObservation != nil, pair.first.liveObservation == pair.second.liveObservation else { return false }
        return [pair.first, pair.second].allSatisfy { sample in
            guard sample.id == id, sample.permission, sample.selectionContinuity, sample.role == .ordinary,
                  sample.onScreen == true, sample.layer == 0, sample.minimized == false, sample.fullscreen == false,
                  sample.display == display, sample.cgFrame == bounds, sample.axFrame == bounds else { return false }
            return true
        }
    }

    func window(in snapshot: DesktopSnapshot?, now: Date = Date(),
                uptime: Double = ProcessInfo.processInfo.systemUptime) -> WindowObservation? {
        guard let snapshot, snapshot.isStructurallyValid, snapshot.nativeIsFresh(now: now, uptime: uptime),
              snapshot.native?.windowLimitReached == false, snapshot.native?.accessibility == .available else { return nil }
        let same = snapshot.windows.filter { $0.metadata?.number == number }
        guard same.count == 1, let window = same.first, PreviewWindowBinding(snapshot, window: window) == self else { return nil }
        return window
    }
}

/// The signed helper holds the original AX element and rejects every writing command on this pipe.
@MainActor private final class PreviewIdentityWitness {
    let target: PreviewWindowBinding
    private let handle: OrdinaryWindowAX

    init?(target: PreviewWindowBinding, bundle: String) async {
        let app = AdmissionApplication(pid: target.pid, launch: target.birth, bundle: bundle, name: "")
        guard let directory = try? OrdinaryWindowDirectory(app, previewWindow: target.number),
              let choices = try? await directory.choices(initial: true), choices.count == 1,
              let choice = choices.first, choice.number == target.number, let handle = directory.handles[choice.id],
              let pair = try? await handle.prepare(), target.confirms(pair, id: handle.id) else { return nil }
        self.target = target
        self.handle = handle
    }

    func verify() async -> Bool {
        guard let pair = try? await handle.verify(expected: target.bounds) else { return false }
        return target.confirms(pair, id: handle.id)
    }
}

@MainActor @Observable final class WindowContentPreview {
    private(set) var choosing = false
    private(set) var notice = ""
    private(set) var binding: PreviewWindowBinding?
    private(set) var image: CGImage?
    private(set) var revision: UInt64?
    var active: Bool { operation != nil }
    private var observer: WindowPickerObserver?
    private weak var host: HostSession?
    private var witness: PreviewIdentityWitness?
    private var expiry: Task<Void, Never>?
    private(set) var operation: UUID?
    private(set) var visibleDisplays: Set<String> = []

    func setVisible(_ visible: Bool, on display: String) {
        guard visibleDisplays.contains(display) != visible else { return }
        if visible {
            visibleDisplays.insert(display)
        } else {
            visibleDisplays.remove(display)
            if active && (binding == nil || binding?.display == display) { clear() }
        }
    }

    /// The native picker and the later capture callback share this revocable operation.
    func beginSelection() -> UUID? {
        guard !visibleDisplays.isEmpty else { return nil }
        clear()
        let id = UUID()
        operation = id
        return id
    }

    private func permits(_ target: PreviewWindowBinding, host: HostSession) -> Bool {
        guard visibleDisplays.contains(target.display), host.isRunning, !host.configuration.surfaceHidden,
              host.registry.preferences.contains(where: { $0.id == BuiltinCatalog.desktop && $0.enabled }),
              Self.sessionAvailable(), target.window(in: host.bus.desktop) != nil else { return false }
        return true
    }

    func choose(host: HostSession) {
        guard observer == nil, host.isRunning, !host.configuration.surfaceHidden else { return }
        if #available(macOS 15.2, *) {
            guard let op = beginSelection() else { return }
            self.host = host
            let observer = WindowPickerObserver { [weak self] filter in
                guard let self, self.operation == op else { return }
                guard let filter else { self.clear(); return }
                guard self.choosing else { return }
                self.choosing = false
                self.notice = "正在读取所选窗口…"
                Task { await self.capture(filter, operation: op) }
            }
            self.observer = observer
            let picker = SCContentSharingPicker.shared
            var config = SCContentSharingPickerConfiguration()
            config.allowedPickerModes = [.singleWindow]
            config.allowsChangingSelectedContent = false
            if let bundle = Bundle.main.bundleIdentifier { config.excludedBundleIDs = [bundle] }
            picker.defaultConfiguration = config
            picker.add(observer)
            choosing = true
            picker.isActive = true
            picker.present(using: .window)
        }
    }

    private func endPicking() {
        if let observer {
            SCContentSharingPicker.shared.remove(observer)
            SCContentSharingPicker.shared.isActive = false
            self.observer = nil
        }
        choosing = false
    }

    func clear(_ message: String = "") {
        operation = nil
        expiry?.cancel(); expiry = nil
        endPicking()
        witness = nil; image = nil; binding = nil; revision = nil; notice = message
    }

    private nonisolated static func sessionAvailable() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool == true &&
            session["CGSSessionScreenIsLocked"] as? Bool != true
    }

    @available(macOS 15.2, *)
    private func capture(_ filter: SCContentFilter, operation op: UUID) async {
        guard operation == op else { return }
        guard filter.style == .window, filter.includedWindows.count == 1, let chosen = filter.includedWindows.first,
              let application = chosen.owningApplication, !application.bundleIdentifier.isEmpty, application.processID != getpid(), chosen.windowLayer == 0, chosen.isOnScreen,
              let host, !host.configuration.surfaceHidden, let snapshot = host.bus.desktop,
              let window = snapshot.windows.first(where: { $0.metadata?.number == chosen.windowID && $0.metadata?.pid == application.processID }),
              let target = PreviewWindowBinding(snapshot, window: window), permits(target, host: host),
              let proof = await PreviewIdentityWitness(target: target, bundle: application.bundleIdentifier) else {
            if operation == op { clear("暂时无法同时确认所选窗口的位置与身份。") }; return
        }
        guard operation == op else { return }
        guard permits(target, host: host) else { clear("窗口已变化，请重新选择。"); return }
        let config = SCStreamConfiguration()
        let size = target.bounds
        let scale = min(1, 384 / max(size.width, size.height))
        config.width = max(1, Int((size.width * scale).rounded()))
        config.height = max(1, Int((size.height * scale).rounded()))
        config.ignoreShadowsSingleWindow = true; config.includeChildWindows = false
        config.showsCursor = false; config.capturesAudio = false
        do {
            let shot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard operation == op else { return }
            let stillSameWindow = await proof.verify()
            guard operation == op else { return }
            guard let current = host.bus.desktop, permits(target, host: host),
                  stillSameWindow else {
                clear("窗口或桌面已变化，已清除预览。"); return
            }
            endPicking()
            binding = target; image = shot; witness = proof; revision = current.revision
            notice = "已拍摄所选窗口。快照在一分钟后清除。"
            expiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                if self?.operation == op { self?.clear() }
            }
        } catch {
            if operation == op { clear("系统未提供该窗口的图像，仍显示窗口轮廓。") }
        }
    }

    func validate(_ snapshot: DesktopSnapshot?) async {
        guard let binding, let op = operation, let witness else { return }
        guard let snapshot, let host, permits(binding, host: host), binding.window(in: snapshot) != nil else {
            clear("窗口状态已变化，已清除预览。"); return
        }
        guard snapshot.revision != revision else { return }
        let stillSameWindow = await witness.verify()
        guard !Task.isCancelled, operation == op, host.bus.desktop?.revision == snapshot.revision else { return }
        guard binding.window(in: snapshot) != nil, stillSameWindow else {
            clear("窗口状态已变化，已清除预览。"); return
        }
        revision = snapshot.revision
    }
}

private final class WindowPickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    let completion: @MainActor @Sendable (SCContentFilter?) -> Void
    init(_ completion: @escaping @MainActor @Sendable (SCContentFilter?) -> Void) { self.completion = completion }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard stream == nil else { return }
        Task { @MainActor in completion(filter) }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        if stream == nil { Task { @MainActor in completion(nil) } }
    }
    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in completion(nil) }
    }
}

@MainActor enum WindowAppBadges {
    struct Badge { let name: String; let icon: NSImage }

    static func resolve(_ snapshot: DesktopSnapshot) -> [String: Badge] {
        var owners = [Int32: (UInt64, Badge)](), badges = [String: Badge]()
        for w in snapshot.windows {
            guard let m = w.metadata, let birth = m.launchMicroseconds, m.pid > 0, birth > 0,
                  m.presentation == .confirmed, m.isOnscreen == true else { continue }
            if owners[m.pid] == nil {
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout.size(ofValue: info))
                guard proc_pidinfo(m.pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                      info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec == birth,
                      let app = NSRunningApplication(processIdentifier: m.pid), !app.isTerminated,
                      let name = app.localizedName, let icon = app.icon else { continue }
                owners[m.pid] = (birth, Badge(name: name, icon: icon))
            }
            if let (born, badge) = owners[m.pid], born == birth { badges[w.id] = badge }
        }
        return badges
    }
}
