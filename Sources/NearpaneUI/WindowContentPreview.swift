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

/// Every consumer, including a draw of the same desk revision, must still have access.
@MainActor @Observable final class WindowPreviewStill {
    private let pixels: CGImage
    private let allowed: @MainActor () -> Bool
    private let expires = ContinuousClock.now.advanced(by: .seconds(60))
    private(set) var revision: UInt64

    init?(pixels: CGImage, revision: UInt64, allowed: @escaping @MainActor () -> Bool) {
        guard allowed() else { return nil }
        self.pixels = pixels; self.revision = revision; self.allowed = allowed
    }

    var accessible: Bool { ContinuousClock.now < expires && allowed() }
    func image(at revision: UInt64) -> CGImage? {
        self.revision == revision && accessible ? pixels : nil
    }
    /// Call synchronously after the final asynchronous identity read.
    func acceptVerifiedRevision(_ revision: UInt64) -> Bool {
        guard accessible else { return false }
        self.revision = revision
        return true
    }
}

@MainActor @Observable final class WindowContentPreview {
    private(set) var choosing = false
    private(set) var notice = ""
    private(set) var binding: PreviewWindowBinding?
    private var still: WindowPreviewStill?
    var hasStill: Bool { still != nil }
    var revision: UInt64? { still?.revision }

    func image(in snapshot: DesktopSnapshot) -> CGImage? {
        guard let still, let binding, host?.bus.desktop?.sessionID == snapshot.sessionID,
              binding.window(in: snapshot) != nil else { return nil }
        return still.image(at: snapshot.revision)
    }
    var active: Bool { operation != nil }
    private var observer: WindowPickerObserver?
    private weak var host: HostSession?
    private var requiresScreenRecording = false
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
              Self.sessionAvailable(), !requiresScreenRecording || CGPreflightScreenCaptureAccess(),
              target.window(in: host.bus.desktop) != nil else { return false }
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

    /// A separate, explicit opt-in for the exact AX object selected in Settings. The
    /// ordinary-window selection never grants screen recording permission or window writes.
    @available(macOS 15.2, *)
    func captureSelected(_ id: ManagedWindowID, bundle: String, host: HostSession,
                         stillSelected: @escaping @MainActor () async -> Bool) async {
        guard let op = beginSelection() else { return }
        self.host = host
        requiresScreenRecording = true
        guard CGPreflightScreenCaptureAccess() else {
            clear("拍摄已选窗口需要已有的屏幕录制权限。也可在「桌面预览」使用系统选择器。"); return
        }
        guard let snapshot = host.bus.desktop,
              let target = Self.selectedBinding(id, in: snapshot), permits(target, host: host),
              await stillSelected() else {
            if operation == op { clear("无法确认原窗口。请重新选择。") }; return
        }
        guard operation == op else { return }
        notice = "正在读取所选窗口…"
        do {
            // ScreenCaptureKit exposes its public ID index as SCWindow objects. Inspect
            // only their numbers until the unique selected record has been found.
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard operation == op else { return }
            let matches = content.windows.filter { $0.windowID == id.number }
            guard matches.count == 1, let chosen = matches.first, chosen.isOnScreen, chosen.windowLayer == 0,
                  chosen.owningApplication?.processID == id.pid, chosen.owningApplication?.bundleIdentifier == bundle,
                  CGPreflightScreenCaptureAccess(), permits(target, host: host) else {
                clear("系统没有提供原窗口的可见图像。"); return
            }
            let filter = SCContentFilter(desktopIndependentWindow: chosen)
            await capture(filter, operation: op, expected: target, consent: {
                guard CGPreflightScreenCaptureAccess() else { return false }
                return await stillSelected()
            })
        } catch {
            if operation == op { clear("系统未提供该窗口的图像，仍显示窗口轮廓。") }
        }
    }

    static func selectedBinding(_ id: ManagedWindowID, in snapshot: DesktopSnapshot,
                                now: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) -> PreviewWindowBinding? {
        let matches = snapshot.windows.filter { $0.metadata?.number == id.number }
        guard matches.count == 1, let window = matches.first, let target = PreviewWindowBinding(snapshot, window: window),
              target.pid == id.pid, target.birth == id.launch, target.window(in: snapshot, now: now, uptime: uptime) != nil else { return nil }
        return target
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
        requiresScreenRecording = false
        witness = nil; still = nil; binding = nil; notice = message
    }

    private nonisolated static func sessionAvailable() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool == true &&
            session["CGSSessionScreenIsLocked"] as? Bool != true
    }

    @available(macOS 15.2, *)
    private func capture(_ filter: SCContentFilter, operation op: UUID,
                         expected: PreviewWindowBinding? = nil,
                         consent: @MainActor () async -> Bool = { true }) async {
        guard operation == op else { return }
        guard filter.style == .window, filter.includedWindows.count == 1, let chosen = filter.includedWindows.first,
              let application = chosen.owningApplication, !application.bundleIdentifier.isEmpty, application.processID != getpid(), chosen.windowLayer == 0, chosen.isOnScreen,
              let host, !host.configuration.surfaceHidden, let snapshot = host.bus.desktop,
              let window = snapshot.windows.first(where: { $0.metadata?.number == chosen.windowID && $0.metadata?.pid == application.processID }),
              let target = PreviewWindowBinding(snapshot, window: window), expected == nil || target == expected, permits(target, host: host),
              let proof = await PreviewIdentityWitness(target: target, bundle: application.bundleIdentifier) else {
            if operation == op { clear("暂时无法同时确认所选窗口的位置与身份。") }; return
        }
        guard operation == op else { return }
        let granted = await consent()
        guard operation == op else { return }
        guard granted, permits(target, host: host) else { clear("窗口已变化，请重新选择。"); return }
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
            let granted = stillSameWindow ? await consent() : false
            guard operation == op else { return }
            guard granted, let current = host.bus.desktop,
                  let held = WindowPreviewStill(pixels: shot, revision: current.revision, allowed: { [weak self, weak host] in
                      guard let self, let host, self.operation == op else { return false }
                      return self.permits(target, host: host)
                  }) else {
                clear("窗口或桌面已变化，已清除预览。"); return
            }
            endPicking()
            binding = target; still = held; witness = proof
            notice = "已拍摄所选窗口。快照在一分钟后清除。"
            // The system does not notify every client of an already granted TCC
            // revocation. Only a live still needs this bounded in-memory cleanup.
            expiry = Task { [weak self, weak held] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, self.operation == op, let held else { return }
                    if !held.accessible { self.clear("快照已到期或窗口无法继续验证，已清除预览。"); return }
                }
            }
        } catch {
            if operation == op { clear("系统未提供该窗口的图像，仍显示窗口轮廓。") }
        }
    }

    func validate(_ snapshot: DesktopSnapshot?) async {
        guard let binding, let op = operation, let witness, let still else { return }
        guard let snapshot, let host, permits(binding, host: host), binding.window(in: snapshot) != nil else {
            clear("窗口状态已变化，已清除预览。"); return
        }
        guard snapshot.revision != revision else { return }
        let stillSameWindow = await witness.verify()
        guard !Task.isCancelled, operation == op, host.bus.desktop?.revision == snapshot.revision else { return }
        guard binding.window(in: snapshot) != nil, stillSameWindow, still.acceptVerifiedRevision(snapshot.revision) else {
            clear("窗口状态已变化，已清除预览。"); return
        }
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
