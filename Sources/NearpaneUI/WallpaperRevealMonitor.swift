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
            guard let cg = event.cgEvent, event.clickCount == 1,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return }
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
    static func isBlankDesktop(at point: CGPoint, windowNumber: Int) -> Bool {
        guard let row = row(windowNumber) else { return false }
        return isBlankDesktop(at: point, row: row)
    }

    private static func isBlankDesktop(at point: CGPoint, row: [String: Any]) -> Bool {
        guard let layer = row[kCGWindowLayer as String] as? Int,
              layer <= CGWindowLevelForKey(.desktopIconWindow),
              let pid = row[kCGWindowOwnerPID as String] as? pid_t, let app = NSRunningApplication(processIdentifier: pid),
              let bundle = app.bundleIdentifier,
              desktopOwners.contains(bundle), AXIsProcessTrusted() else { return false }
        var hit: AXUIElement?, hitPID: pid_t = 0, role: CFTypeRef?
        let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
        guard result == .success, let hit else {
            // With files concealed WindowManager owns a desktop-level click surface which
            // exposes no AX item. Confirm this physical hit again in WindowServer.
            guard bundle == "com.apple.WindowManager",
                  app.bundleURL?.standardizedFileURL.path == "/System/Library/CoreServices/WindowManager.app",
                  layer == CGWindowLevelForKey(.desktopIconWindow), row[kCGWindowIsOnscreen as String] as? Bool == true,
                  let n = row[kCGWindowNumber as String] as? Int, NSWindow.windowNumber(at: appKit(point), belowWindowWithWindowNumber: 0) == n,
                  let raw = row[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: raw),
                  let screen = displayBounds(at: point) else { return false }
            return coversDesktop(bounds, display: screen, at: point)
        }
        guard AXUIElementGetPid(hit, &hitPID) == .success, let hitOwner = NSRunningApplication(processIdentifier: hitPID)?.bundleIdentifier,
              AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String else { return false }
        var fullDesktopGroup = false
        if hitOwner == "com.apple.finder", role == kAXGroupRole, let frame = elementFrame(hit), let screen = displayBounds(at: point) {
            fullDesktopGroup = coversDesktop(frame, display: screen, at: point)
        }
        return isDesktopBackground(windowOwner: bundle, hitOwner: hitOwner, role: role, fullDesktopGroup: fullDesktopGroup)
    }

    private static func displayBounds(at point: CGPoint) -> CGRect? {
        var id: CGDirectDisplayID = 0, count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count == 1 else { return nil }
        return CGDisplayBounds(id)
    }
    private static let desktopOwners: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.wallpaper.agent", "com.apple.WindowManager"]
    static func coversDesktop(_ frame: CGRect, display: CGRect, at point: CGPoint) -> Bool {
        // Finder may exclude the menu bar and Dock, or span several physical displays.
        !display.isEmpty && display.contains(point) && frame.contains(point)
            && frame.contains(display.insetBy(dx: display.width * 0.12, dy: display.height * 0.12))
    }
    static func elementFrame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
    static func isDesktopBackground(windowOwner: String, hitOwner: String, role: String, fullDesktopGroup: Bool = false) -> Bool {
        guard desktopOwners.contains(windowOwner), desktopOwners.contains(hitOwner) else { return false }
        // Desktop items and the Finder background share one CG window. An item, widget or Dock
        // control must never become a background click on the strength of that window number.
        if hitOwner == "com.apple.finder" {
            return [kAXScrollAreaRole, kAXListRole, kAXWindowRole, kAXApplicationRole].contains(role)
                || (role == kAXGroupRole && fullDesktopGroup)
        }
        return [kAXWindowRole, kAXApplicationRole].contains(role)
    }

    private func clicked(number: Int64, point: CGPoint) {
        let actual = number > 0 ? Int(number) : NSWindow.windowNumber(at: Self.appKit(point), belowWindowWithWindowNumber: 0)
        guard let row = Self.row(actual) else { return }
        if Self.isBlankDesktop(at: point, row: row) {
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
