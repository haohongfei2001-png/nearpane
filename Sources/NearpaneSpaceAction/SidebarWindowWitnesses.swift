import AppKit
import CReadOnlySpaces
import NearpaneCore

/// Exact AX references remain in the installed helper. A numeric window ID alone
/// cannot renew a reference, nor can the sidebar seed one on an inactive Space.
@MainActor final class SidebarWindowWitnesses {
    typealias Check = (NativeSidebarWindowLocation, Bool, AXUIElement?) -> AXUIElement?
    private struct Entry {
        let location: NativeSidebarWindowLocation
        let element: AXUIElement
        var verified: Double
    }
    private var entries = [UUID: Entry]()
    private var session: Int?

    func reset() { entries.removeAll(); session = nil }

    func sample(_ probe: NativeSidebarWindowProbe, session: Int, now: Double, check: Check,
                rejected: (String) -> Void = { _ in }) -> UUID? {
        if self.session != session { reset(); self.session = session }
        entries = entries.filter { now >= $0.value.verified && now - $0.value.verified <= 12 }
        if let original = probe.original {
            guard var saved = entries[original] else { rejected("original-not-held-or-expired"); return nil }
            guard saved.location == probe.location else {
                entries.removeValue(forKey: original); rejected("registered-location-changed"); return nil
            }
            guard let live = check(saved.location, probe.current, saved.element) else {
                entries.removeValue(forKey: original); return nil
            }
            guard CFEqual(live, saved.element) else {
                entries.removeValue(forKey: original); rejected("original-ax-object-changed"); return nil
            }
            saved.verified = now
            entries[original] = saved
            return original
        }
        guard probe.current, let live = check(probe.location, true, nil) else { return nil }
        // A new foreground enrollment always gets a new token. Evict the superseded
        // incarnation, including a previous window with the same number and owner.
        entries = entries.filter { $0.value.location.window.number != probe.location.window.number }
        guard entries.count < 64 else { rejected("reference-limit"); return nil }
        let token = UUID()
        entries[token] = Entry(location: probe.location, element: live, verified: now)
        return token
    }

    func observe(_ probes: [NativeSidebarWindowProbe], inventory: ActionInventory,
                 permitted: () -> Bool = AXIsProcessTrusted, after: () throws -> ActionInventory = ActionInventory.read,
                 check: Check? = nil, report: (NativeSpaceWindow, String) -> Void = { _,_ in }) throws -> [UUID?] {
        guard probes.count <= 16, Set(probes.map(\.location.window.number)).count == probes.count else {
            reset(); throw ActionFailure("窗口观察清单含重复或过多编号。")
        }
        guard permitted() else { reset(); throw ActionFailure("空间动作助手未获辅助功能权限。") }
        // The independent overview may have straddled the system notification. Its
        // old current bit cannot revoke an otherwise live AX reference.
        for probe in probes {
            if let actual = inventory.displays[probe.location.display],
               (actual.current == probe.location.space) != probe.current {
                throw ActionFailure("两个窗口观察位于桌面切换的两侧。")
            }
        }
        let oldEntries = entries, oldSession = session
        let deadline = ProcessInfo.processInfo.systemUptime + 0.38
        let observed = SidebarWindowRead(inventory, deadline: deadline)
        let read = check ?? observed.exact
        let results = probes.map { probe -> UUID? in
            let now = ProcessInfo.processInfo.systemUptime
            guard now < deadline else {
                if probe.audit == true { report(probe.location.window, "batch-time-budget") }
                return nil
            }
            observed.diagnosing = probe.audit == true
            observed.lastReason = nil
            let token = sample(probe, session: inventory.session, now: now, check: read) { observed.reason($0) }
            if probe.audit == true {
                report(probe.location.window, token == nil ? (observed.lastReason ?? "not-registered") :
                        (probe.original == nil ? "foreground-original-bound" : "same-original-confirmed"))
            }
            return token
        }
        guard permitted() else { reset(); throw ActionFailure("辅助功能权限已改变。") }
        guard (try? after()) == inventory else {
            entries = oldEntries
            session = oldSession
            throw ActionFailure("核对原窗口期间桌面已改变。")
        }
        return results
    }

    func selected(_ request: NativeSpaceCommand, token: UUID) throws -> AXUIElement {
        guard request.action == .select, request.targetKind == .ordinary, let window = request.window,
              let display = UUID(uuidString: request.display), let space = request.targetUUID else {
            throw ActionFailure("所选原窗口凭据不完整。")
        }
        let location = NativeSidebarWindowLocation(window: window, display: display, space: request.target, spaceUUID: space)
        let view = try ActionInventory.read()
        guard let current = view.displays[display]?.current, AXIsProcessTrusted() else {
            reset(); throw ActionFailure("窗口权限或显示器已变化。")
        }
        let probe = NativeSidebarWindowProbe(location, current: current == location.space, original: token)
        guard sample(probe, session: view.session, now: ProcessInfo.processInfo.systemUptime,
                     check: SidebarWindowRead(view, deadline: request.deadlineUptime).exact) == token, let original = entries[token]?.element else {
            throw ActionFailure("原窗口已关闭、重建或离开原桌面。")
        }
        return original
    }
}

@MainActor final class SidebarWindowRead {
    private let inventory: ActionInventory
    var diagnosing = false
    var lastReason: String?
    func reason(_ value: String) { if diagnosing { lastReason = value } }
    private func reject(_ value: String) -> AXUIElement? { reason(value); return nil }
    private var members = [String: Set<UInt32>]()
    private var owners = [Int32: [UInt32: [AXUIElement]]]()
    private let deadline: Double
    init(_ inventory: ActionInventory, deadline: Double) {
        self.inventory = inventory
        self.deadline = deadline
    }

    private func bounded(_ element: AXUIElement) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        return remaining > 0 && AXUIElementSetMessagingTimeout(element, Float(min(0.06, remaining))) == .success
    }

    private func forward(_ space: String) -> Set<UInt32>? {
        if let hit = members[space] { return hit }
        guard let id = UInt64(space), let raw = NPReadCatalogSpaceWindowNumbers(id) as? [NSNumber],
              raw.count <= 8192 else { return nil }
        let ids = raw.compactMap { ActionInventory.id($0).flatMap(UInt32.init) }
        let unique = Set(ids)
        guard ids.count == raw.count, unique.count == raw.count else { return nil }
        members[space] = unique
        return unique
    }

    private func listed(_ pid: Int32) -> [UInt32: [AXUIElement]]? {
        if let hit = owners[pid] { return hit }
        let app = AXUIElementCreateApplication(pid)
        var list: CFArray?
        guard bounded(app) else { reason("owner-ax-list-time-budget"); return nil }
        let status = AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 65, &list)
        guard status == .success else { reason("owner-ax-list-status-" + String(status.rawValue)); return nil }
        guard let rows = list as? [AXUIElement], rows.count <= 64 else { reason("owner-ax-list-size"); return nil }
        var indexed = [UInt32: [AXUIElement]]()
        for row in rows {
            var owner: pid_t = 0
            guard AXUIElementGetPid(row, &owner) == .success, owner == pid,
                  bounded(row) else { reason("owner-ax-list-identity-or-budget"); return nil }
            let number = NPReadAXWindowNumber(row)
            guard number != 0 else { reason("owner-ax-list-missing-number"); return nil }
            indexed[number, default: []].append(row)
        }
        owners[pid] = indexed
        return indexed
    }

    func exact(_ scope: NativeSidebarWindowLocation, _ current: Bool, _ retained: AXUIElement?) -> AXUIElement? {
        let key = scope.window
        guard ProcessInfo.processInfo.systemUptime < deadline else { return reject("item-time-budget") }
        guard AXIsProcessTrusted() else { return reject("worker-ax-denied") }
        guard let display = inventory.displays[scope.display] else { return reject("display-missing") }
        guard (display.current == scope.space) == current else { return reject("current-changed") }
        guard display.spaces.contains(where: { $0.id == scope.space && $0.kind == .ordinary && $0.uuid == scope.spaceUUID })
        else { return reject("ordinary-space-uuid") }
        guard let app = NSRunningApplication(processIdentifier: key.pid), app.activationPolicy == .regular,
              !app.isTerminated else { return reject("owner-not-regular") }
        guard !app.isHidden else { return reject("owner-hidden") }
        guard WindowWitness.owner(key) else { return reject("owner-birth") }
        guard WindowWitness.membership(key.number) == [scope.space] else { return reject("reverse-membership") }
        guard let forward = forward(scope.space) else { return reject("forward-list-unreadable") }
        guard forward.contains(key.number) else { return reject("forward-membership") }
        guard let surface = WindowSurfaceRecord(number: key.number) else { return reject("exact-cg-record") }
        guard surface.pid == key.pid && surface.layer == 0 else { return reject("cg-owner-or-layer") }
        guard surface.isDrawn else { return reject("cg-alpha") }
        guard let list = listed(key.pid) else { return nil }
        let frame = surface.frame
        let center = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        if current {
            guard surface.isOnscreen else { return reject("current-cg-offscreen") }
            guard display.bounds.contains(center) else { return reject("current-cg-display") }
        } else if inventory.displays.contains(where: { $0.key != scope.display && $0.value.bounds.contains(center) }) {
            return reject("background-cg-other-display")
        }
        let matches = list[key.number] ?? []
        guard let element = Self.original(in: matches, current: current, retained: retained) else {
            return reject(matches.isEmpty ? "missing-ax-original" : "ambiguous-or-replaced-ax-object")
        }
        var pid: pid_t = 0, values: CFArray?
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXModalAttribute, kAXMinimizedAttribute, "AXFullScreen"] as CFArray
        guard AXUIElementGetPid(element, &pid) == .success, pid == key.pid else { return reject("original-ax-pid") }
        guard bounded(element) else { return reject("original-ax-time-budget") }
        let status = AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values)
        guard status == .success, let fields = values as? [Any], fields.count == 5 else {
            return reject("original-ax-attributes-" + String(status.rawValue))
        }
        guard fields[0] as? String == kAXWindowRole else { return reject("original-ax-role") }
        guard fields[1] as? String == kAXStandardWindowSubrole else { return reject("original-ax-subrole") }
        for (index, name) in [(2, "modal"), (3, "minimized"), (4, "fullscreen")] {
            guard let value = fields[index] as? Bool else { return reject("original-ax-" + name + "-unreadable") }
            guard !value else { return reject("original-ax-" + name + "-true") }
        }
        guard NPReadAXWindowNumber(element) == key.number else { return reject("original-ax-number") }
        guard WindowWitness.owner(key) else { return reject("final-owner-birth") }
        return element
    }

    static func original(in rows: [AXUIElement], current: Bool, retained: AXUIElement?) -> AXUIElement? {
        if rows.isEmpty { return current ? nil : retained }
        guard rows.count == 1, let listed = rows.first, retained.map({ CFEqual($0, listed) }) != false else { return nil }
        return listed
    }
}
