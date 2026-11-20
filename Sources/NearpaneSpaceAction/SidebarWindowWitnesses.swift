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
                contradicted: () -> Bool = { true }, rejected: (String) -> Void = { _ in }) -> UUID? {
        if self.session != session { reset(); self.session = session }
        entries = entries.filter { now >= $0.value.verified && now - $0.value.verified <= 12 }
        if let original = probe.original {
            guard var saved = entries[original] else { rejected("original-not-held-or-expired"); return nil }
            guard saved.location == probe.location else {
                entries.removeValue(forKey: original); rejected("registered-location-changed"); return nil
            }
            guard let live = check(saved.location, probe.current, saved.element) else {
                // A transport error or an unsettled read grants no row or action.
                // Keep only the original reference and its original expiry time.
                if contradicted() { entries.removeValue(forKey: original) }
                return nil
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
                 check: Check? = nil, report: (NativeSpaceWindow, String) -> Void = { _,_ in },
                 facts: (NativeSpaceWindow, [String: String]) -> Void = { _,_ in },
                 withheld: (Int) -> Void = { _ in }) throws -> [UUID?] {
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
        let results = probes.enumerated().map { index, probe -> UUID? in
            let now = ProcessInfo.processInfo.systemUptime
            guard now < deadline else {
                if probe.audit == true { report(probe.location.window, "batch-time-budget") }
                if let token = probe.original, let entry = entries[token], entry.location == probe.location,
                   (0...12).contains(now - entry.verified) { withheld(index) }
                return nil
            }
            observed.begin(diagnosing: probe.audit == true)
            let token = sample(probe, session: inventory.session, now: now, check: read,
                               contradicted: { observed.contradicted }, rejected: { observed.reason($0) })
            if token == nil, let original = probe.original, entries[original]?.location == probe.location { withheld(index) }
            if probe.audit == true {
                facts(probe.location.window, observed.facts)
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
        let read = SidebarWindowRead(view, deadline: request.deadlineUptime)
        guard sample(probe, session: view.session, now: ProcessInfo.processInfo.systemUptime,
                     check: read.exact, contradicted: { read.contradicted }) == token, let original = entries[token]?.element else {
            throw ActionFailure("原窗口已关闭、重建或离开原桌面。")
        }
        return original
    }
}

@MainActor final class SidebarWindowRead {
    private let inventory: ActionInventory
    private var diagnosing = false
    private var factPrefix = ""
    private(set) var lastReason: String?
    private(set) var contradicted = false
    private(set) var facts = [String: String]()
    func begin(diagnosing: Bool) {
        self.diagnosing = diagnosing
        lastReason = nil; contradicted = false; facts.removeAll(keepingCapacity: true)
    }
    func reason(_ value: String) { if diagnosing { lastReason = value } }
    private func reject(_ value: String, contradiction: Bool = false) -> AXUIElement? {
        contradicted = contradiction
        reason(value)
        return nil
    }
    private func fact(_ key: String, _ value: @autoclosure () -> String) {
        if diagnosing { facts[factPrefix + key] = value() }
    }
    private var members = [String: Set<UInt32>]()
    private var owners = [Int32: [UInt32: [AXUIElement]]]()
    private var ownerReads = [Int32: AXWindowList]()
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
        let app = AXUIElementCreateApplication(pid)
        let read = ownerReads[pid] ?? AXWindowList.read(app, limit: 64, canRead: { bounded(app) })
        ownerReads[pid] = read
        fact("listCountStatus", String(read.countStatus.rawValue))
        fact("listReportedCount", read.reportedCount.map(String.init) ?? "unknown")
        fact("listArrayStatus", read.arrayStatus.map { String($0.rawValue) } ?? "not-read")
        fact("listActualCount", read.actualCount.map(String.init) ?? "unknown")
        if let hit = owners[pid] { return hit }
        guard let rows = read.windows else { reason("owner-ax-list-unconfirmed"); return nil }
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
        guard AXIsProcessTrusted() else { return reject("worker-ax-denied", contradiction: true) }
        guard let display = inventory.displays[scope.display] else { return reject("display-missing") }
        guard (display.current == scope.space) == current else { return reject("current-changed") }
        guard display.spaces.contains(where: { $0.id == scope.space && $0.kind == .ordinary && $0.uuid == scope.spaceUUID })
        else { return reject("ordinary-space-uuid", contradiction: true) }
        let application = NSRunningApplication(processIdentifier: key.pid)
        fact("ownerRegistered", String(application != nil))
        guard let app = application else { return reject("owner-registration-unavailable") }
        fact("ownerActivationPolicy", String(app.activationPolicy.rawValue))
        fact("ownerTerminated", String(app.isTerminated))
        fact("ownerHidden", String(app.isHidden))
        guard !app.isTerminated else { return reject("owner-terminated", contradiction: true) }
        guard app.activationPolicy == .regular else { return reject("owner-not-regular") }
        guard !app.isHidden else { return reject("owner-hidden", contradiction: true) }
        guard WindowWitness.owner(key) else { return reject("owner-birth", contradiction: true) }
        guard let places = WindowWitness.membership(key.number) else { return reject("reverse-membership-unreadable") }
        guard places == [scope.space] else { return reject("reverse-membership", contradiction: true) }
        guard let forward = forward(scope.space) else { return reject("forward-list-unreadable") }
        guard forward.contains(key.number) else { return reject("forward-membership", contradiction: true) }
        guard let surface = WindowSurfaceRecord(number: key.number) else { return reject("exact-cg-record") }
        guard surface.pid == key.pid && surface.layer == 0 else { return reject("cg-owner-or-layer", contradiction: true) }
        guard surface.isDrawn else { return reject("cg-alpha") }
        let frame = surface.frame
        let center = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        if current {
            guard surface.isOnscreen else { return reject("current-cg-offscreen") }
            guard display.bounds.contains(center) else { return reject("current-cg-display") }
        } else if inventory.displays.contains(where: { $0.key != scope.display && $0.value.bounds.contains(center) }) {
            return reject("background-cg-other-display", contradiction: true)
        }
        // An empty window list and the retained object's live properties are
        // independent reads. Collect both, even when one side is unavailable.
        let indexed = listed(key.pid)
        let candidates = indexed?[key.number]
        let rows = candidates ?? []
        fact("listMatches", indexed == nil ? "unknown" : String(rows.count))
        fact("listedIsOriginal", retained.flatMap { old in rows.first.map { CFEqual(old,$0) ? "true" : "false" } } ?? "not-comparable")
        let inspected = retained ?? (rows.count == 1 ? rows[0] : nil)
        let direct = inspected.map { readOriginal($0, key: key) }
        if diagnosing, let retained, rows.isEmpty {
            let app = AXUIElementCreateApplication(key.pid)
            if bounded(app) {
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
                fact("ownerFocusedStatus", String(status.rawValue))
                if status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                    let focused = unsafeBitCast(value, to: AXUIElement.self)
                    fact("ownerFocusedIsOriginal", String(CFEqual(focused, retained)))
                    let n = NPReadAXWindowNumber(focused)
                    fact("ownerFocusedNumber", n == 0 ? "unknown" : (n == key.number ? "matches" : "different"))
                    // Keep companion diagnostic evidence for the same opaque object,
                    // without attributing another window's state to this selection.
                    if CFEqual(focused, retained), n == key.number, case .unavailable = direct {
                        factPrefix = "named."
                        _ = readOriginal(focused, key: key)
                        factPrefix = ""
                    }
                }
            }
        }
        if let direct, case .invalid(let why) = direct { return reject(why, contradiction: true) }
        guard indexed != nil else { return nil }
        guard let element = Self.original(in: rows, current: current, retained: retained) else {
            return reject(rows.isEmpty ? "missing-ax-original" : "ambiguous-or-replaced-ax-object", contradiction: !rows.isEmpty)
        }
        guard let direct else { return reject("original-ax-unavailable") }
        if case .unavailable(let why) = direct { return reject(why) }
        guard WindowWitness.owner(key) else { return reject("final-owner-birth", contradiction: true) }
        return element
    }

    enum DirectEvidence: Equatable {
        case verified, unavailable(String), invalid(String)
    }

    private func readOriginal(_ element: AXUIElement, key: NativeSpaceWindow) -> DirectEvidence {
        guard bounded(element) else { return .unavailable("original-ax-time-budget") }
        var pid: pid_t = 0, values: CFArray?
        let pidStatus = AXUIElementGetPid(element, &pid)
        let number = NPReadAXWindowNumber(element)
        let attrs = [kAXRoleAttribute, kAXSubroleAttribute, kAXModalAttribute, kAXMinimizedAttribute, "AXFullScreen"]
        let status = AXUIElementCopyMultipleAttributeValues(element, attrs as CFArray, [], &values)
        let fields = values as? [Any]
        fact("originalPIDStatus", String(pidStatus.rawValue))
        fact("originalPIDMatches", pidStatus == .success ? String(pid == key.pid) : "unknown")
        fact("originalNumber", number == 0 ? "unknown" : (number == key.number ? "matches" : "different"))
        fact("originalAttributesStatus", String(status.rawValue))
        var direct = Self.properties(status: status, fields: fields, fact: { name, value in self.fact(name, value) })
        if case .unavailable = direct, status != .apiDisabled {
            // Some providers omit one field from a multiple-attribute reply. A
            // missing flag can only be established by a successful direct read
            // on this same original AX object. Never default it to false.
            var combined = fields ?? []
            if combined.count != attrs.count { combined = Array(repeating: NSNull(), count: attrs.count) }
            let names = ["role", "subrole", "modal", "minimized", "fullscreen"]
            for i in attrs.indices {
                let typed = i < 2 ? combined[i] is String : Self.boolean(combined[i]) != nil
                guard !typed, bounded(element) else { continue }
                var value: CFTypeRef?
                let rc = AXUIElementCopyAttributeValue(element, attrs[i] as CFString, &value)
                fact("single." + names[i] + ".status", String(rc.rawValue))
                if rc == .invalidUIElement { return .invalid("original-ax-object-invalid") }
                if rc == .success, let value { combined[i] = value }
            }
            direct = Self.properties(status: .success, fields: combined, fact: { name, value in self.fact("resolved." + name, value) })
        }
        if pidStatus == .invalidUIElement { return .invalid("original-ax-pid-invalid") }
        if pidStatus == .success && pid != key.pid { return .invalid("original-ax-pid") }
        if number != 0 && number != key.number { return .invalid("original-ax-number") }
        if case .invalid = direct { return direct }
        if pidStatus != .success { return .unavailable("original-ax-pid-unreadable") }
        if number == 0 { return .unavailable("original-ax-number-unreadable") }
        let finalNumber = NPReadAXWindowNumber(element)
        fact("finalOriginalNumber", finalNumber == 0 ? "unknown" : (finalNumber == key.number ? "matches" : "different"))
        if finalNumber == 0 { return .unavailable("original-ax-number-unreadable") }
        if finalNumber != key.number { return .invalid("original-ax-number") }
        return direct
    }

    private static func boolean(_ value: Any) -> Bool? {
        CFGetTypeID(value as AnyObject) == CFBooleanGetTypeID() ? value as? Bool : nil
    }

    /// AXCopyMultiple returns a per-attribute AXError wrapped in an AXValue for
    /// unsupported or unavailable properties. Such errors never mean false.
    static func properties(status: AXError, fields: [Any]?, fact: (String, String) -> Void) -> DirectEvidence {
        guard status == .success, let fields, fields.count == 5 else {
            return status == .invalidUIElement ? .invalid("original-ax-object-invalid") :
                .unavailable("original-ax-attributes-" + String(status.rawValue))
        }
        var missing: String?, conflicting: String?
        let names = ["role", "subrole", "modal", "minimized", "fullscreen"]
        for (index, value) in fields.enumerated() {
            let name = names[index]
            if index < 2, let role = value as? String {
                let ok = role == (index == 0 ? kAXWindowRole : kAXStandardWindowSubrole)
                fact("original." + name, ok ? "matches" : "different")
                if !ok { conflicting = conflicting ?? name }
            } else if index >= 2, let state = boolean(value) {
                fact("original." + name, String(state))
                if state { conflicting = conflicting ?? name }
            } else {
                var error = AXError.failure
                let raw = value as AnyObject
                let errorValue = CFGetTypeID(raw) == AXValueGetTypeID() ? unsafeBitCast(raw, to: AXValue.self) : nil
                let hasError = errorValue.map { AXValueGetType($0) == .axError && AXValueGetValue($0, .axError, &error) } == true
                fact("original." + name, hasError ? "ax-error-" + String(error.rawValue) : "unavailable")
                missing = missing ?? name
            }
        }
        if let conflicting { return .invalid("original-ax-" + conflicting + "-contradiction") }
        if let missing { return .unavailable("original-ax-" + missing + "-unreadable") }
        return .verified
    }

    static func original(in rows: [AXUIElement], current: Bool, retained: AXUIElement?) -> AXUIElement? {
        if rows.isEmpty { return current ? nil : retained }
        guard rows.count == 1, let listed = rows.first, retained.map({ CFEqual($0, listed) }) != false else { return nil }
        return listed
    }
}
