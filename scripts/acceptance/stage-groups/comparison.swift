import AppKit
import NearpaneCore

/// Runs only in the disposable hosted login. Writes are limited to the three retained
/// AX objects exported by our two fixture owners. Dock inspection reads role counts only.
@MainActor private final class CornerMask: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func prepare(screen: NSScreen, bounds: CGRect, root: URL) -> CornerMask? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let size = CGSize(width: 48, height: 80)
        let frame = CGRect(x: screen.frame.maxX - size.width, y: screen.frame.minY, width: size.width, height: size.height)
        let crop = root.appendingPathComponent("unoccupied-corner.png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-R\(Int(bounds.maxX-size.width)),\(Int(bounds.maxY-size.height)),48,80", crop.path]
        guard (try? capture.run()) != nil else { return nil }
        capture.waitUntilExit()
        guard capture.terminationStatus == 0, let image = NSImage(contentsOf: crop) else { return nil }
        let panel = CornerMask(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.level = .init(rawValue: NSWindow.Level.normal.rawValue + 1)
        panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        let view = NSImageView(frame: CGRect(origin: .zero, size: size))
        view.imageScaling = .scaleAxesIndependently
        view.image = image
        panel.contentView = view
        panel.setFrame(frame, display: false)
        return panel
    }
}

@MainActor private func dockMiniatures() -> Int? {
    let docks = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
    guard docks.count == 1, let dock = docks.first,
          let children = ax(AXUIElementCreateApplication(dock.processIdentifier), kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    let lists = children.filter { ax($0, kAXRoleAttribute) as? String == kAXListRole }
    guard lists.count == 1, let list = lists.first, let items = ax(list, kAXChildrenAttribute) as? [AXUIElement],
          !items.isEmpty, items.count < 1024 else { return nil }
    let roles = items.compactMap { ax($0, kAXSubroleAttribute) as? String }
    guard roles.count == items.count, roles.contains(kAXApplicationDockItemSubrole) else { return nil }
    return roles.filter { $0 == kAXMinimizedWindowDockItemSubrole }.count
}

private func writePosition(_ target: Target, _ origin: CGPoint) -> AXError {
    var p = origin
    guard let value = AXValueCreate(.cgPoint, &p) else { return .illegalArgument }
    return AXUIElementSetAttributeValue(target.element, kAXPositionAttribute as CFString, value)
}

private func sameOwner(_ target: Target) -> Bool {
    var pid: pid_t = 0
    return AXUIElementGetPid(target.element, &pid) == .success && pid == target.owner.pid &&
        (try? birth(pid)) == target.owner.birth && NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == target.owner.identifier
}

private func focused(_ target: Target) -> Bool {
    guard sameOwner(target),
          NSWorkspace.shared.frontmostApplication?.processIdentifier == target.owner.pid,
          let value = ax(AXUIElementCreateApplication(target.owner.pid), kAXFocusedWindowAttribute) else { return false }
    return CFEqual(value, target.element)
}

@MainActor private func takeFocus(_ target: Target) async throws -> Bool {
    guard sameOwner(target), !StageManagerPreference.ownsWindowDispatch,
          let app = NSRunningApplication(processIdentifier: target.owner.pid) else { return false }
    _ = app.activate(options: [])
    _ = AXUIElementSetAttributeValue(target.element, kAXMainAttribute as CFString, kCFBooleanTrue)
    _ = AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
    let end = ContinuousClock.now + .seconds(2)
    repeat {
        if focused(target) { return true }
        try await Task.sleep(for: .milliseconds(45))
    } while ContinuousClock.now < end
    return false
}

/// The fixture receives a normal hardware-route key pair through its key window.
/// Never inject unless both the global front app and exact focused window match.
private func key(_ target: Target, code: CGKeyCode) -> Bool {
    guard CGPreflightPostEventAccess(), focused(target),
          let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return false }
    down.flags = []; up.flags = []
    down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    return true
}

private func rectJSON(_ r: CGRect?) -> [Double] {
    guard let r else { return [] }
    return [r.minX, r.minY, r.width, r.height]
}

private func unchanged(_ ids: [UInt32], _ previous: Samples, _ current: Samples) -> Bool {
    ids.allSatisfy { id in
        guard let a = previous.owned[id], let b = current.owned[id] else { return false }
        return a.frame == b.frame && a.miniature == b.miniature && a.visible == b.visible &&
            a.activeSpace == b.activeSpace && a.key == b.key && a.input == b.input &&
            previous.axFrames[id] == current.axFrames[id] && previous.axMiniature[id] == current.axMiniature[id] &&
            previous.cg[id] == current.cg[id]
    }
}

private func hidden(_ target: Target, _ s: Samples, method: String, bounds: CGRect) -> Bool {
    let id = target.id
    guard let owner = s.owned[id] else { return false }
    if method == "minimize" { return owner.miniature && s.axMiniature[id] == true && s.cg[id] == nil }
    guard owner.activeSpace, !owner.miniature, s.axMiniature[id] == false, let f = s.cg[id], f == s.axFrames[id] else { return false }
    let strip = bounds.intersection(f)
    // AppKit may clamp the title bar vertically. Only a one-point horizontal strip may remain.
    return f.minX >= bounds.maxX - 1 && !strip.isNull && strip.width <= 1 && strip.height <= 48 &&
        f.minY >= bounds.maxY - 48
}

private func restored(_ t: Target, _ s: Samples, before: Samples) -> Bool {
    guard let w = s.owned[t.id], let original = before.owned[t.id] else { return false }
    return w.visible && !w.miniature && w.activeSpace && w.frame == original.frame &&
        s.axMiniature[t.id] == false && s.axFrames[t.id] == before.axFrames[t.id] && s.cg[t.id] == before.cg[t.id]
}

@MainActor func compareGroupVisibility(root: URL, method: String) async throws {
    var receipt: [String: Any] = ["status": "BLOCKED", "method": method, "installedHost": "NOT_RUN",
        "tenCycles": "NOT_RUN", "fiftyCycles": "NOT_RUN", "nativeWrites": 0,
        "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString, "screenRecordingAllowed": CGPreflightScreenCaptureAccess()]
    let file = root.appendingPathComponent("trial.json")
    var actions = [[String: Any]](), steps = [[String: Any]]()
    func save(_ reason: String) throws {
        receipt["reason"] = reason; receipt["actions"] = actions; receipt["steps"] = steps
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: file, options: .atomic)
    }
    let owners = try ["a", "b"].map { try JSONDecoder().decode(Owner.self, from: Data(contentsOf: root.appendingPathComponent($0 + ".json"))) }
    receipt["stageManager"] = StageManagerPreference.read() as Any? ?? NSNull()
    receipt["axTrusted"] = AXIsProcessTrusted()
    guard AXIsProcessTrusted(), !StageManagerPreference.ownsWindowDispatch, NSScreen.screens.count == 1,
          let screen = NSScreen.main, let sn = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
          owners[0].display == owners[1].display, owners.allSatisfy(\.onActiveSpace),
          let a = enroll(owners[0], name: "a"), a.count == 2,
          let b = enroll(owners[1], name: "b", auxiliary: [3]), b.count == 4
    else { try save("isolatedOrdinaryOwnersOrAXUnavailable"); return }
    let managed = a + [b[0]], all = a + b, others = Array(b.dropFirst()).map(\.id)
    let bounds = CGDisplayBounds(sn.uint32Value)
    let corner = CGPoint(x: bounds.maxX-1, y: bounds.maxY-1)
    receipt["display"] = owners[0].display.uuidString
    receipt["owners"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(owners))
    receipt["auxiliaryID"] = b[3].id
    receipt["userMinimizedID"] = b[2].id
    let dockUnseeded = dockMiniatures()
    guard let initial = try await sample(all, root: root), initial.cg.count == 6, initial.owned[b[3].id]?.auxiliary == true else {
        try save("unseededInventoryIncomplete"); return
    }
    try Data().write(to: root.appendingPathComponent("user-minimize"))
    guard try await takeFocus(managed[0]) else { try save("initialExactFocusUnavailable"); return }
    var base: Samples?
    for _ in 0..<24 {
        if let s = try await sample(all, root: root), s.owned[b[2].id]?.miniature == true, s.axMiniature[b[2].id] == true,
           s.cg[b[2].id] == nil, s.owned[managed[0].id]?.key == true,
           managed.allSatisfy({ s.axFrames[$0.id] == s.cg[$0.id] && s.cg[$0.id] != nil }) { base = s; break }
        try await Task.sleep(for: .milliseconds(70))
    }
    guard let base else { try save("originalFramesFocusOrUserMinimizationUnconfirmed"); return }
    try await Task.sleep(for: .milliseconds(240))
    let dockBase = dockMiniatures()
    receipt["dockBeforeUserMinimized"] = dockUnseeded ?? -1
    receipt["dockBaseline"] = dockBase ?? -1
    let mask = method == "corner" ? CornerMask.prepare(screen: screen, bounds: bounds, root: root) : nil
    defer { mask?.orderOut(nil) }
    var held = [UInt32: Samples]()
    var state = "PASS", reason = "singleABCARoundTrip", dockPeak = dockBase ?? -1
    let originals = Dictionary(uniqueKeysWithValues: managed.compactMap { t in base.cg[t.id].map { (t.id, $0) } })
    let clock = ContinuousClock.now
    func evidence(_ s: Samples) -> [[String: Any]] {
        all.map { t in
            let w = s.owned[t.id]
            return ["id": t.id, "cg": rectJSON(s.cg[t.id]), "axFrame": rectJSON(s.axFrames[t.id]), "appKitFrame": rectJSON(w?.frame),
                    "ownerKey": w?.key ?? false, "ownerVisible": w?.visible ?? false, "ownerMini": w?.miniature ?? false,
                    "axMin": s.axMiniature[t.id] as Any? ?? NSNull(), "input": w?.input ?? ""]
        }
    }
    receipt["baseline"] = evidence(base)
    func change(_ t: Target, park: Bool, prior: Samples) async throws -> Samples? {
        guard !StageManagerPreference.ownsWindowDispatch, sameOwner(t), let original = originals[t.id],
              let current = try await sample(all, root: root), current.owned[t.id] == prior.owned[t.id],
              current.axFrames[t.id] == prior.axFrames[t.id], current.axMiniature[t.id] == prior.axMiniature[t.id],
              current.cg[t.id] == prior.cg[t.id] else { return nil }
        if !park {
            guard let owned = held[t.id], current.axFrames[t.id] == owned.axFrames[t.id], current.cg[t.id] == owned.cg[t.id],
                  current.axMiniature[t.id] == owned.axMiniature[t.id], current.owned[t.id]?.frame == owned.owned[t.id]?.frame else { return nil }
        }
        // The ambiguous interval is on disk before any setter can take effect.
        actions.append(["id": t.id, "park": park, "state": "mayHaveIssued", "uptime": ProcessInfo.processInfo.systemUptime])
        try save("pendingReadback")
        let code = method == "minimize" ? AXUIElementSetAttributeValue(t.element, kAXMinimizedAttribute as CFString, park ? kCFBooleanTrue : kCFBooleanFalse)
            : writePosition(t, park ? corner : original.origin)
        actions[actions.count-1]["axReturn"] = code.rawValue
        let end = ContinuousClock.now + .seconds(3)
        var last: Samples?, confirmations = 0
        repeat {
            if let s = try await sample(all, root: root) {
                // Also retain a measured clamped position so this experiment can clean up its own partial effect.
                let stable = last.map { s.cg[t.id] == $0.cg[t.id] && s.axFrames[t.id] == $0.axFrames[t.id] &&
                    s.owned[t.id]?.frame == $0.owned[t.id]?.frame && s.owned[t.id]?.miniature == $0.owned[t.id]?.miniature } == true
                let moved = method == "corner" && s.cg[t.id] != nil && s.axFrames[t.id] == s.cg[t.id] && s.cg[t.id] != original &&
                    s.owned[t.id]?.frame != base.owned[t.id]?.frame
                if park && stable && (hidden(t, s, method: method, bounds: bounds) || moved) { held[t.id] = s }
                let ok = park ? hidden(t, s, method: method, bounds: bounds) : restored(t, s, before: base)
                confirmations = ok ? confirmations + 1 : 0
                last = s
                if stable && confirmations >= 2 {
                    if park { held[t.id] = s } else { held.removeValue(forKey: t.id) }
                    actions[actions.count-1]["state"] = "confirmed"
                    return s
                }
            } else { last = nil; confirmations = 0 }
            try await Task.sleep(for: .milliseconds(70))
        } while ContinuousClock.now < end
        if let last { actions[actions.count-1]["lastObserved"] = evidence(last) }
        return nil
    }

    let order = [0, 1, 2, 0], codes: [CGKeyCode] = [0, 11, 8, 2], markers = ["a","b","c","d"]
    var inputs = base.owned.mapValues(\.input)
    round: for (n, selected) in order.enumerated() {
        let target = managed[selected]
        guard var now = try await sample(all, root: root) else { state = "UNKNOWN"; reason = "inventoryLost"; break }
        for (index, t) in managed.enumerated() where index != selected && held[t.id] == nil {
            guard restored(t, now, before: base), let after = try await change(t, park: true, prior: now) else {
                state = held[t.id] == nil ? "UNKNOWN" : "FAIL"; reason = "inactiveGeometryOrMinimizationNotConfirmed"; break round
            }
            now = after
        }
        if held[target.id] != nil {
            guard let after = try await change(target, park: false, prior: now) else { state = "UNKNOWN"; reason = "targetRestoreUnconfirmed"; break }
            now = after
        }
        if let mask { mask.orderFrontRegardless() }
        guard try await takeFocus(target), let focusedSample = try await sample(all, root: root),
              focusedSample.owned[target.id]?.key == true, key(target, code: codes[n]) else {
            state = "BLOCKED"; reason = "physicalRouteKeyOrExactAXFocusUnavailable"; break
        }
        inputs[target.id, default: ""] += markers[n]
        var consecutive = 0, lastFacts = [String: Bool](), last: Samples?
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            if let s = try await sample(all, root: root) {
                let dock = dockMiniatures()
                dockPeak = max(dockPeak, dock ?? -1)
                last = s
                lastFacts = ["selectedVisibleAtOriginalLayout": restored(target, s, before: base),
                    "allInactiveIsolated": managed.filter { $0.id != target.id }.allSatisfy { hidden($0, s, method: method, bounds: bounds) },
                    "bystandersUnchanged": unchanged(others, base, s),
                    "exactFocusAndCGKey": focused(target) && s.owned[target.id]?.key == true,
                    "onlyIntendedKeyReceiver": s.owned.allSatisfy { inputs[$0.key] == $0.value.input }]
                consecutive = lastFacts.values.allSatisfy { $0 } ? consecutive+1 : 0
                if consecutive >= 2 { break }
            } else { consecutive = 0 }
            try await Task.sleep(for: .milliseconds(80))
        } while ContinuousClock.now < deadline
        var step: [String: Any] = ["group": selected, "facts": lastFacts, "independentSamples": consecutive, "dockMiniatures": dockMiniatures() ?? -1,
                                    "elapsedSeconds": clock.duration(to: .now).components.seconds]
        if let last { step["windows"] = evidence(last) }
        steps.append(step)
        if consecutive < 2 { state = last == nil ? "UNKNOWN" : "FAIL"; reason = "groupReadbackOrNaturalInput"; break }
    }
    let dockVerified = dockBase != nil && dockUnseeded != nil && steps.count == 4 && steps.allSatisfy { ($0["dockMiniatures"] as? Int) == dockBase }
    receipt["dockPeak"] = dockPeak; receipt["dockNoExtraTiles"] = dockVerified
    receipt["maskPresented"] = mask?.isVisible == true
    if state == "PASS" && !dockVerified { state = dockBase == nil ? "UNKNOWN" : "FAIL"; reason = "dockWindowTiles" }
    if method == "corner" && state == "PASS" {
        // A click-through panel must also leave no parked AX target at the remaining strip.
        var hit: AXUIElement?, pid: pid_t = 0
        let hitRead = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(bounds.maxX-0.5), Float(bounds.maxY-2), &hit)
        let identified = hitRead == .success && hit.map { AXUIElementGetPid($0, &pid) == .success } == true
        receipt["cornerHitOwnedPID"] = identified && managed.contains { $0.owner.pid == pid }
        if mask?.isVisible != true || !identified { state = "UNKNOWN"; reason = "maskOrHitTestUnconfirmed" }
        else if managed.contains(where: { $0.owner.pid == pid }) { state = "FAIL"; reason = "parkedWindowStillAcceptsPointer" }
    }
    mask?.orderOut(nil)
    var clean = true
    for t in managed.reversed() where held[t.id] != nil {
        guard let now = try await sample(all, root: root), try await change(t, park: false, prior: now) != nil else { clean = false; continue }
    }
    let refocused = try await takeFocus(managed[0])
    let final = try await sample(all, root: root)
    let cleanup = clean && held.isEmpty && refocused && final.map { s in
        managed.allSatisfy { restored($0, s, before: base) } && unchanged(others, base, s) && s.owned[managed[0].id]?.key == true
    } == true
    receipt["restoredOriginals"] = cleanup
    receipt["dockAfterCleanup"] = dockMiniatures() ?? -1
    receipt["status"] = cleanup ? state : "UNKNOWN"
    try save(cleanup ? reason : "cleanupNotIndependentlyConfirmed")
}
