import AppKit
import NearpaneCore

@MainActor func desktopHitSample(_ point: CGPoint, number: Int) -> [String: Any] {
    var data: [String: Any] = ["window": number, "blank": WallpaperRevealMonitor.isBlankDesktop(at: point, windowNumber: number)]
    if let id = UInt32(exactly: number), let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
       let row = rows.first, let pid = row[kCGWindowOwnerPID as String] as? pid_t {
        data["layer"] = row[kCGWindowLayer as String]
        data["windowOwner"] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
    var element: AXUIElement?, pid: pid_t = 0
    if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
       let element, AXUIElementGetPid(element, &pid) == .success {
        data["hitOwner"] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        data["hitRole"] = ax(element, kAXRoleAttribute) as? String
    }
    return data
}

/// Exercise the actual system gesture on a clean hosted desktop without changing its preference.
/// Both clicks must hit the same positively identified system desktop surface.
@MainActor func qualifyWallpaper(root: URL) async throws {
    var receipt: [String: Any] = ["status":"BLOCKED", "installedHost":"NOT_RUN", "settingWrites":0, "clicks":0]
    func finish(_ reason: String) throws {
        receipt["reason"] = reason
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: root.appendingPathComponent("trial.json"), options: .atomic)
    }
    let owners = try ["a","b"].map { try JSONDecoder().decode(Owner.self, from: Data(contentsOf: root.appendingPathComponent($0+".json"))) }
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), !StageManagerPreference.ownsWindowDispatch, NSScreen.screens.count == 1,
          let left = enroll(owners[0], name: "a"), let right = enroll(owners[1], name: "b", auxiliary: [3]),
          let t = left.first else { try finish("isolatedOrdinaryOwnersOrPermission"); return }
    let targets = left + right
    guard try await takeFocus(t), let initial = try await sample(targets, root: root), let original = initial.cg[t.id] else {
        try finish("exactFixtureNotAvailable"); return
    }
    let bounds = CGDisplayBounds(CGMainDisplayID())
    func number(_ p: CGPoint) -> Int {
        NSWindow.windowNumber(at: CGPoint(x: p.x, y: bounds.maxY-p.y), belowWindowWithWindowNumber: 0)
    }
    func appleBackground(_ p: CGPoint) -> Bool {
        let n = number(p)
        guard n > 0, let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, UInt32(n)) as? [[String: Any]], rows.count == 1,
              let row = rows.first, let layer = row[kCGWindowLayer as String] as? Int,
              layer <= CGWindowLevelForKey(.desktopIconWindow),
              let pid = row[kCGWindowOwnerPID as String] as? Int32 else { return false }
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        return ["com.apple.finder","com.apple.dock","com.apple.wallpaper.agent","com.apple.WindowManager"].contains(bundle)
    }
    let inside = CGPoint(x: original.midX, y: original.midY)
    var point: CGPoint?
    for y in [0.75,0.80,0.28] {
        for x in [0.24,0.45,0.62] where point == nil {
            let candidate = CGPoint(x: bounds.width*x, y: bounds.height*y)
            if appleBackground(candidate) { point = candidate }
        }
    }
    guard let point, number(inside) == Int(t.id), let savedPointer = CGEvent(source: nil)?.location else {
        try finish("desktopHitOrVisibleFixtureUnconfirmed"); return
    }
    receipt["backgroundHit"] = desktopHitSample(point, number: number(point))
    var transitions = [Bool]()
    let monitor = WallpaperRevealMonitor { transitions.append($0) }
    defer { monitor.stop(); CGWarpMouseCursorPosition(savedPointer) }
    func click() -> Bool {
        guard appleBackground(point),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return false }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap); return true
    }
    guard click() else { try finish("initialWallpaperClickNotIssued"); return }
    receipt["clicks"] = 1
    var withdrew = 0
    for _ in 0..<15 {
        try await Task.sleep(for: .milliseconds(100)); monitor.poll()
        withdrew = appleBackground(inside) ? withdrew+1 : 0
        if withdrew >= 2 { break }
    }
    receipt["windowMovedAside"] = withdrew >= 2
    if withdrew < 2 {
        receipt["monitorTransitions"] = transitions
        receipt["fixtureGeometryUnchanged"] = (try await sample(targets, root: root))?.cg == initial.cg
        try finish("nativeWallpaperRevealNotObservedWithExistingSetting"); return
    }
    let heldAtReveal = transitions.last == true
    guard click() else { receipt["status"] = "UNKNOWN"; try finish("restoreClickTargetUnconfirmed"); return }
    receipt["clicks"] = 2
    var restored = 0
    for _ in 0..<24 {
        try await Task.sleep(for: .milliseconds(110)); monitor.poll()
        if number(inside) == Int(t.id), let s = try await sample(targets, root: root), s.cg == initial.cg, s.axFrames == initial.axFrames {
            restored += 1
        } else { restored = 0 }
        if restored >= 2 && transitions.last == false { break }
    }
    receipt["monitorTransitions"] = transitions
    receipt["heldWhileRevealed"] = heldAtReveal
    receipt["restoredSamples"] = restored
    receipt["status"] = heldAtReveal && transitions.last == false && restored >= 2 ? "PASS" : "FAIL"
    try finish("nativeRevealAndRestoreObserved")
}
