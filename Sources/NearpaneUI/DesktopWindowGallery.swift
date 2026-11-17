import AppKit
import NearpaneCore
@preconcurrency import ScreenCaptureKit

/// One WindowServer surface on the observed desktop. Observation IDs include a revision and
/// cannot be used to carry a click or an image across routine reader refreshes.
struct DesktopWindowKey: Hashable {
    let pid: pid_t
    let birth: UInt64
    let number: CGWindowID
}

struct DesktopWindowTarget: Equatable {
    let key: DesktopWindowKey
    let session: UUID
    let topology, display: String
    let current: String?
    let membership: WindowMembership
    let frame: SurfaceRect

    init?(_ window: WindowObservation, in snapshot: DesktopSnapshot) {
        guard let m = window.metadata, m.pid > 1, let birth = m.launchMicroseconds, birth > 0,
              m.number > 0, m.isOnscreen == true, m.onActiveDesktop == true,
              m.minimized != true, m.fullScreen != true, m.globalFrame.geometry.isValid,
              window.confidence != .synthetic,
              window.confidence != .ambiguous || (m.element == nil && m.axFrame == nil && m.axStandardWindowNumber == nil),
              m.axFrame == nil || m.presentation == .confirmed,
              m.axStandardWindowNumber == nil || m.axStandardWindowNumber == m.number else { return nil }
        let active = snapshot.scopes.filter { $0.displayID == window.displayID }.flatMap(\.records).filter(\.isCurrent)
        guard active.count <= 1 else { return nil }
        key = .init(pid: m.pid, birth: birth, number: m.number)
        session = snapshot.sessionID; topology = snapshot.topologyFingerprint
        display = window.displayID; current = active.first?.id
        membership = window.membership; frame = m.globalFrame
    }

    func present(in snapshot: DesktopSnapshot?, now: Date = .now, uptime: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let snapshot, snapshot.sessionID == session, snapshot.topologyFingerprint == topology else { return false }
        let matched = snapshot.currentDesktopWindows(on: display, now: now, uptime: uptime)
            .filter { $0.metadata?.number == key.number }
        return matched.count == 1 && matched.first.flatMap { DesktopWindowTarget($0, in: snapshot) } == self
    }

    func liveOwner() -> NSRunningApplication? {
        var info = proc_bsdinfo()
        let n = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(key.pid, PROC_PIDTBSDINFO, 0, &info, n) == n,
              info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec == key.birth,
              let app = NSRunningApplication(processIdentifier: key.pid), !app.isTerminated,
              app.activationPolicy == .regular, let bundle = app.bundleIdentifier,
              !bundle.isEmpty, !bundle.hasPrefix("com.holdsnow.nearpane"), !bundle.hasPrefix("org.nearpane.")
        else { return nil }
        return app
    }

    /// Never read window titles. Require the same shared layer-zero surface, its on-screen
    /// frame and the public current-desktop list on both sides of an asynchronous capture.
    @MainActor func isVisibleSurface() -> Bool {
        guard liveOwner() != nil,
              (NSWindow.windowNumbers(options: .allApplications) ?? []).contains(NSNumber(value: key.number)),
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, key.number) as? [[String: Any]],
              rows.count == 1, let row = rows.first,
              row[kCGWindowNumber as String] as? UInt32 == key.number,
              row[kCGWindowOwnerPID as String] as? Int32 == key.pid,
              row[kCGWindowLayer as String] as? Int == 0, row[kCGWindowIsOnscreen as String] as? Bool == true,
              (row[kCGWindowAlpha as String] as? Double ?? 0) > 0,
              let shared = row[kCGWindowSharingState as String] as? UInt32, shared != CGWindowSharingType.none.rawValue,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bounds)
        else { return false }
        return matches(r)
    }

    func matches(_ rect: CGRect) -> Bool {
        frame == SurfaceRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}

@MainActor @Observable final class DesktopWindowGallery {
    private struct Still {
        let target: DesktopWindowTarget
        let image: CGImage
        let time: TimeInterval
    }
    private var stills = [DesktopWindowKey: Still]()
    private(set) var generation: UInt64 = 0
    // A per-display lease prevents cancelled or superseded captures from being published.
    @ObservationIgnored private var operations = [String: UUID]()
    private var visible = [String: Set<DesktopWindowKey>]()
    private let permitsWindow: (DesktopWindowKey) -> Bool

    init(permitsWindow: @escaping (DesktopWindowKey) -> Bool = { _ in true }) {
        self.permitsWindow = permitsWindow
    }

    func setCard(_ key: DesktopWindowKey, on display: String, visible onScreen: Bool) {
        if onScreen { visible[display, default: []].insert(key) }
        else { visible[display]?.remove(key); stills.removeValue(forKey: key) }
    }

    func clear(display: String? = nil) {
        if let display {
            operations.removeValue(forKey: display)
            stills = stills.filter { $0.value.target.display != display }
        } else {
            generation &+= 1
            operations.removeAll(); stills.removeAll()
        }
    }

    func image(for target: DesktopWindowTarget, permitted: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CGImage? {
        guard permitted, visible[target.display]?.contains(target.key) == true,
              let still = stills[target.key], still.target == target, now - still.time < 12 else { return nil }
        return still.image
    }

    func run(on display: String, snapshot: @escaping () -> DesktopSnapshot?, allowed: @escaping () -> Bool) async {
        let token = UUID()
        operations[display] = token
        var attempted = [DesktopWindowKey: TimeInterval]()
        defer {
            if operations[display] == token { clear(display: display) }
        }
        while !Task.isCancelled && operations[display] == token {
            guard allowed(), WindowContentPreview.sessionAvailable(), CGPreflightScreenCaptureAccess() else { return }
            if let sample = snapshot() {
                let targets = sample.currentDesktopWindows(on: display, now: .now, uptime: ProcessInfo.processInfo.systemUptime)
                    .compactMap { DesktopWindowTarget($0, in: sample) }
                    .filter { permitsWindow($0.key) && visible[display]?.contains($0.key) == true }
                let active = Dictionary(targets.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                for key in stills.keys where stills[key]?.target.display == display && active[key] != stills[key]?.target {
                    stills.removeValue(forKey: key)
                }
                attempted = attempted.filter { active[$0.key] != nil }
                let due = targets.sorted { (attempted[$0.key] ?? 0) < (attempted[$1.key] ?? 0) }
                    .filter { ProcessInfo.processInfo.systemUptime - (attempted[$0.key] ?? -.infinity) >= 3 }
                if !due.isEmpty, let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) {
                    for target in due.prefix(6) {
                        attempted[target.key] = ProcessInfo.processInfo.systemUptime
                        func valid() -> Bool {
                            !Task.isCancelled && operations[display] == token && allowed() && permitsWindow(target.key) &&
                                visible[display]?.contains(target.key) == true && WindowContentPreview.sessionAvailable() &&
                                CGPreflightScreenCaptureAccess() && target.present(in: snapshot()) && target.isVisibleSurface()
                        }
                        guard valid() else { if operations[display] == token { stills.removeValue(forKey: target.key) }; continue }
                        let selected = content.windows.filter { $0.windowID == target.key.number &&
                            $0.owningApplication?.processID == target.key.pid && $0.windowLayer == 0 && $0.isOnScreen && target.matches($0.frame) }
                        guard selected.count == 1, let window = selected.first else { stills.removeValue(forKey: target.key); continue }
                        let config = SCStreamConfiguration()
                        let scale = min(1, 420 / max(target.frame.width, target.frame.height))
                        config.width = max(1, Int((target.frame.width * scale).rounded()))
                        config.height = max(1, Int((target.frame.height * scale).rounded()))
                        config.showsCursor = false; config.capturesAudio = false
                        config.ignoreShadowsSingleWindow = true
                        if #available(macOS 14.2, *) { config.includeChildWindows = false }
                        let filter = SCContentFilter(desktopIndependentWindow: window)
                        guard let pixels = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
                              valid() else { if operations[display] == token { stills.removeValue(forKey: target.key) }; continue }
                        stills[target.key] = Still(target: target, image: pixels, time: ProcessInfo.processInfo.systemUptime)
                    }
                }
            }
            do { try await Task.sleep(for: .milliseconds(850)) } catch { return }
        }
    }
}
