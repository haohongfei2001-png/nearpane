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

    func sample(_ probe: NativeSidebarWindowProbe, session: Int, now: Double, check: Check) -> UUID? {
        if self.session != session { reset(); self.session = session }
        entries = entries.filter { now >= $0.value.verified && now - $0.value.verified <= 12 }
        if let original = probe.original {
            guard var saved = entries[original], saved.location == probe.location,
                  let live = check(saved.location, probe.current, saved.element),
                  CFEqual(live, saved.element) else {
                entries.removeValue(forKey: original)
                return nil
            }
            saved.verified = now
            entries[original] = saved
            return original
        }
        guard probe.current, let live = check(probe.location, true, nil) else { return nil }
        // A new foreground enrollment always gets a new token. Evict the superseded
        // incarnation, including a previous window with the same number and owner.
        entries = entries.filter { $0.value.location.window.number != probe.location.window.number }
        guard entries.count < 64 else { return nil }
        let token = UUID()
        entries[token] = Entry(location: probe.location, element: live, verified: now)
        return token
    }

    func observe(_ probes: [NativeSidebarWindowProbe], inventory: ActionInventory,
                 permitted: () -> Bool = AXIsProcessTrusted, after: () throws -> ActionInventory = ActionInventory.read,
                 check: Check? = nil) throws -> [UUID?] {
        guard probes.count <= 16, Set(probes.map(\.location.window.number)).count == probes.count,
              permitted() else { reset(); throw ActionFailure("窗口身份或辅助功能权限不可用。") }
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
        let read = check ?? SidebarWindowRead(inventory, deadline: deadline).exact
        let results = probes.map { probe -> UUID? in
            let now = ProcessInfo.processInfo.systemUptime
            guard now < deadline else { return nil }
            return sample(probe, session: inventory.session, now: now, check: read)
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
        guard bounded(app),
              AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 65, &list) == .success,
              let rows = list as? [AXUIElement], rows.count <= 64 else { return nil }
        var indexed = [UInt32: [AXUIElement]]()
        for row in rows {
            var owner: pid_t = 0
            guard AXUIElementGetPid(row, &owner) == .success, owner == pid,
                  bounded(row) else { return nil }
            let number = NPReadAXWindowNumber(row)
            guard number != 0 else { return nil }
            indexed[number, default: []].append(row)
        }
        owners[pid] = indexed
        return indexed
    }

    func exact(_ scope: NativeSidebarWindowLocation, _ current: Bool, _ retained: AXUIElement?) -> AXUIElement? {
        let key = scope.window
        guard ProcessInfo.processInfo.systemUptime < deadline, AXIsProcessTrusted(), let display = inventory.displays[scope.display],
              (display.current == scope.space) == current,
              display.spaces.contains(where: { $0.id == scope.space && $0.kind == .ordinary && $0.uuid == scope.spaceUUID }),
              let app = NSRunningApplication(processIdentifier: key.pid), app.activationPolicy == .regular,
              !app.isHidden, !app.isTerminated, WindowWitness.owner(key),
              WindowWitness.membership(key.number) == [scope.space], forward(scope.space)?.contains(key.number) == true,
              let surface = WindowSurfaceRecord(number: key.number), surface.pid == key.pid, surface.layer == 0, surface.isDrawn,
              let list = listed(key.pid) else { return nil }
        let frame = surface.frame
        let center = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        if current {
            guard surface.isOnscreen, display.bounds.contains(center) else { return nil }
        } else if inventory.displays.contains(where: { $0.key != scope.display && $0.value.bounds.contains(center) }) {
            return nil
        }
        let matches = list[key.number] ?? []
        guard let element = Self.original(in: matches, current: current, retained: retained) else { return nil }
        var pid: pid_t = 0, values: CFArray?
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXModalAttribute, kAXMinimizedAttribute, "AXFullScreen"] as CFArray
        guard AXUIElementGetPid(element, &pid) == .success, pid == key.pid,
              bounded(element),
              AXUIElementCopyMultipleAttributeValues(element, attributes, [], &values) == .success,
              let fields = values as? [Any], fields.count == 5,
              fields[0] as? String == kAXWindowRole, fields[1] as? String == kAXStandardWindowSubrole,
              fields[2] as? Bool == false, fields[3] as? Bool == false, fields[4] as? Bool == false,
              NPReadAXWindowNumber(element) == key.number, WindowWitness.owner(key) else { return nil }
        return element
    }

    static func original(in rows: [AXUIElement], current: Bool, retained: AXUIElement?) -> AXUIElement? {
        if rows.isEmpty { return current ? nil : retained }
        guard rows.count == 1, let listed = rows.first, retained.map({ CFEqual($0, listed) }) != false else { return nil }
        return listed
    }
}
