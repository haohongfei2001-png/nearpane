import AppKit

/// Observes the native wallpaper gesture. It never consumes an event, sets an OS preference
/// or identifies the user's documents. Only ordinary window numbers, owner PIDs and points
/// inside the current display are retained for the duration of the system animation.
@MainActor final class WallpaperRevealMonitor {
    struct Witness: Equatable {
        let number: Int, pid: pid_t, point: CGPoint
    }
    private var monitor: Any?
    private var witnesses = [Witness]()
    private var started: ContinuousClock.Instant?
    private var consecutive = 0
    private var held = false
    private let changed: (Bool) -> Void

    init(changed: @escaping (Bool) -> Void) {
        self.changed = changed
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let cg = event.cgEvent else { return }
            let point = cg.location
            let number = cg.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
            self?.clicked(number: number, point: point)
        }
    }

    private static func appKit(_ cg: CGPoint) -> CGPoint {
        CGPoint(x: cg.x, y: CGDisplayBounds(CGMainDisplayID()).maxY - cg.y)
    }
    private static func row(_ number: Int) -> [String: Any]? {
        guard number > 0, let n = UInt32(exactly: number),
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, n) as? [[String: Any]], rows.count == 1,
              let row = rows.first, row[kCGWindowNumber as String] as? Int == number else { return nil }
        return row
    }
    private static func eligible(_ row: [String: Any]) -> Bool {
        guard row[kCGWindowLayer as String] as? Int == 0, row[kCGWindowIsOnscreen as String] as? Bool == true,
              let pid = row[kCGWindowOwnerPID as String] as? Int32, pid != getpid(),
              let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return false }
        return true
    }
    private static func wallpaper(_ row: [String: Any]) -> Bool {
        guard let layer = row[kCGWindowLayer as String] as? Int, layer <= CGWindowLevelForKey(.desktopIconWindow),
              let pid = row[kCGWindowOwnerPID as String] as? Int32 else { return false }
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        return ["com.apple.finder","com.apple.dock","com.apple.wallpaper.agent","com.apple.WindowManager"].contains(bundle)
    }

    private func clicked(number: Int64, point: CGPoint) {
        let actual = number > 0 ? Int(number) : NSWindow.windowNumber(at: Self.appKit(point), belowWindowWithWindowNumber: 0)
        guard let row = Self.row(actual) else { return }
        if Self.wallpaper(row) {
            if !held {
                witnesses = visibleWitnesses()
                held = true; changed(true)
            }
            started = .now; consecutive = 0
        } else if held, Self.eligible(row), let pid = row[kCGWindowOwnerPID as String] as? Int32 {
            // A newly opened foreground window may replace every witness on the old desktop.
            witnesses = [.init(number: actual, pid: pid, point: point)]
            consecutive = 0
        }
    }

    private func visibleWitnesses() -> [Witness] {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], 0) as? [[String: Any]] else { return [] }
        var result = [Witness]()
        for row in rows where Self.eligible(row) {
            guard let n = row[kCGWindowNumber as String] as? Int, let p = row[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 4, rect.height > 4 else { continue }
            let point = CGPoint(x: rect.midX, y: rect.midY)
            if NSWindow.windowNumber(at: Self.appKit(point), belowWindowWithWindowNumber: 0) == n {
                result.append(.init(number: n, pid: p, point: point))
                if result.count == 4 { break }
            }
        }
        return result
    }

    private func visiblyOrdinary(_ w: Witness) -> Bool {
        guard let row = Self.row(w.number), Self.eligible(row), row[kCGWindowOwnerPID as String] as? pid_t == w.pid,
              NSWindow.windowNumber(at: Self.appKit(w.point), belowWindowWithWindowNumber: 0) == w.number else { return false }
        var hit: AXUIElement?, pid: pid_t = 0
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(w.point.x), Float(w.point.y), &hit) == .success,
              let hit, AXUIElementGetPid(hit, &pid) == .success else { return false }
        return pid == w.pid
    }

    func poll() {
        guard held, let started, ContinuousClock.now - started >= .milliseconds(700), AXIsProcessTrusted() else { return }
        if witnesses.isEmpty { witnesses = visibleWitnesses() }
        consecutive = !witnesses.isEmpty && witnesses.allSatisfy(visiblyOrdinary) ? consecutive + 1 : 0
        if consecutive >= 2 { reset() }
    }
    func reset() {
        witnesses.removeAll(); consecutive = 0; started = nil
        if held { held = false; changed(false) }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        reset()
    }
}
