// Disposable GitHub-hosted GUI preparation only. All desktop changes are real
// signed Dock/Mission Control actions; no preference or private Space setter.
import AppKit
import ApplicationServices
import Foundation
import Security

private struct CIRecord: Codable, Equatable {
    let id: UInt64, type: Int, uuid: String
    var hasUUID: Bool {
        guard let value = UUID(uuidString: uuid) else { return false }
        return value.uuidString != "00000000-0000-0000-0000-000000000000"
    }
}
private struct CISnapshot: Codable {
    let display: String, current: UInt64, records: [CIRecord], rawInventoryJSON: String
    var active: CIRecord? { records.first { $0.id == current } }
    func sameScope(_ other: Self) -> Bool {
        display == other.display && current == other.current && records == other.records
    }
    @MainActor static func read() throws -> Self {
        guard NPReadOnlySpacesOpen() == 1, let raw = NPReadInventory() as? [[String: Any]], raw.count == 1,
              let display = raw[0]["Display Identifier"] as? String, UUID(uuidString: display) != nil,
              let current = raw[0]["Current Space"] as? [String: Any], let id = current["id64"] as? UInt64,
              let rows = raw[0]["Spaces"] as? [[String: Any]], !rows.isEmpty, rows.count <= 32,
              NSScreen.screens.count == 1, let screen = NSScreen.screens.first,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
              let screenUUID = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue(),
              UUID(uuidString: CFUUIDCreateString(nil, screenUUID) as String) == UUID(uuidString: display)
        else { throw Refusal("singleDisplayRawInventoryUnavailable") }
        let records = try rows.map { row -> CIRecord in
            guard let number = row["id64"] as? UInt64, number > 0, let kind = row["type"] as? Int,
                  let uuid = row["uuid"] as? String else { throw Refusal("rawSpaceRecordShapeUnavailable") }
            return .init(id: number, type: kind, uuid: uuid)
        }
        guard Set(records.map(\.id)).count == records.count,
              let active = records.first(where: { $0.id == id }), current["type"] as? Int == active.type,
              current["uuid"] as? String == active.uuid else { throw Refusal("currentRecordDisagreesWithRawInventory") }
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        return .init(display: display, current: id, records: records, rawInventoryJSON: String(decoding: data, as: UTF8.self))
    }
}
private struct CIEvent: Codable {
    let operation: String, uptime: Double, axError: Int32?
}
private struct CIState: Codable {
    let schema: Int, repository: String, runID: String, attempt: String, boot: String
    let original: CISnapshot
    var phase: String, pendingAdd: Bool, created: CIRecord?, latest: CISnapshot?, events: [CIEvent]
}
private func bootID() throws -> String {
    var bytes = [CChar](repeating: 0, count: 128), size = 128
    guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0,
          let value = UUID(uuidString: String(cString: bytes)) else { throw Refusal("bootIdentityUnavailable") }
    return value.uuidString
}
private func ciIdentity() throws -> (repository: String, run: String, attempt: String) {
    let env = ProcessInfo.processInfo.environment
    guard env["GITHUB_ACTIONS"] == "true", env["GITHUB_REPOSITORY"] == "haohongfei2001-png/nearpane",
          env["RUNNER_ENVIRONMENT"] != "self-hosted", let run = env["GITHUB_RUN_ID"], UInt64(run) != nil,
          let attempt = env["GITHUB_RUN_ATTEMPT"], UInt64(attempt) != nil else {
        throw Refusal("onlyDisposableNearpaneGitHubActionsRunnerMayPrepareDesktop")
    }
    return (env["GITHUB_REPOSITORY"]!, run, attempt)
}
private func controlFrame(_ element: AXUIElement) -> CGRect? {
    guard let p = attr(element, kAXPositionAttribute), let s = attr(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
          [point.x, point.y, size.width, size.height].allSatisfy(\.isFinite), size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: point, size: size)
}
private func controlGeometry(_ element: AXUIElement) -> [String: Any] {
    var position: CFTypeRef?, size: CFTypeRef?
    let p = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
    let s = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)
    var result: [String: Any] = ["positionAXError": p.rawValue, "sizeAXError": s.rawValue]
    var point = CGPoint.zero, dimensions = CGSize.zero
    if let position, CFGetTypeID(position) == AXValueGetTypeID(), AXValueGetValue(position as! AXValue, .cgPoint, &point),
       point.x.isFinite, point.y.isFinite { result["position"] = [point.x, point.y] }
    if let size, CFGetTypeID(size) == AXValueGetTypeID(), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
       dimensions.width.isFinite, dimensions.height.isFinite { result["size"] = [dimensions.width, dimensions.height] }
    return result
}
private func belongs(_ child: AXUIElement, to parent: AXUIElement, owner: pid_t) -> Bool {
    var next: AXUIElement? = child
    for _ in 0..<12 {
        var pid: pid_t = 0
        guard let element = next, AXUIElementGetPid(element, &pid) == .success, pid == owner else { return false }
        if CFEqual(element, parent) { return true }
        guard let raw = attr(element, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        next = (raw as! AXUIElement)
    }
    return false
}
private func controlHit(_ point: CGPoint, tile: AXUIElement, owner: pid_t, body: Bool) -> Bool {
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
          let hit, belongs(hit, to: tile, owner: owner) else { return false }
    if !body { return true }
    let role = attr(hit, kAXRoleAttribute) as? String
    return (CFEqual(hit, tile) && role == kAXButtonRole) ||
        (role == kAXImageRole && attr(hit, kAXParentAttribute).map { CFEqual($0, tile) } == true)
}
private struct CITiles {
    let bar: SecondarySpacesBar, elements: [AXUIElement], frame: CGRect
    init(_ snapshot: CISnapshot) throws {
        guard let display = UUID(uuidString: snapshot.display),
              let bar = try secondarySpacesBar(display, currentDisplay: true),
              let list = try children(bar.spaces, named: "mc.spaces.list").only,
              let items = attr(list, kAXChildrenAttribute) as? [AXUIElement], items.count == snapshot.records.count,
              let frame = controlFrame(list), CGDisplayBounds(bar.side).contains(frame), Set(items).count == items.count,
              items.allSatisfy({ belongs($0, to: list, owner: bar.owner.pid) && attr($0, kAXRoleAttribute) as? String == kAXButtonRole })
        else { throw Refusal("systemTilesDoNotMatchRawInventoryOrder") }
        try bar.verify(list)
        let frames = items.compactMap(controlFrame)
        // Collapsed Mission Control can keep expanded logical thumbnail frames
        // outside its short list. They cannot invalidate a semantic Add press.
        // Compare visual order only when every reported frame is actually within
        // the list; pointer selection below still requires an exact retained hit.
        if frames.count == items.count && frames.allSatisfy(frame.contains) {
            guard zip(frames, frames.dropFirst()).allSatisfy({ $0.midX < $1.midX }) else {
                throw Refusal("systemTileGeometryOrderChanged")
            }
        }
        self.bar = bar; elements = items; self.frame = frame
    }
    func sameObjects(_ other: Self) -> Bool {
        bar.dock == other.bar.dock && bar.owner == other.bar.owner && CFEqual(bar.add, other.bar.add) &&
            elements.count == other.elements.count && zip(elements, other.elements).allSatisfy { CFEqual($0, $1) }
    }
    func point(_ index: Int, body: Bool) -> CGPoint? {
        let tile = elements[index], owner = bar.owner.pid
        if body && frame.height < 48 { return nil }
        if let bounds = controlFrame(tile), frame.contains(bounds) {
            for fraction: CGFloat in [0.53, 0.61, 0.45] {
                let point = CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * fraction)
                if controlHit(point, tile: tile, owner: owner, body: body) { return point }
            }
        }
        // Read-only hit probes are confined to the actual signed strip. A point
        // is never clicked unless it resolves this exact retained button/image.
        let until = ProcessInfo.processInfo.systemUptime + 0.45
        for x in stride(from: frame.minX + 3, through: frame.maxX - 3, by: 6) {
            guard ProcessInfo.processInfo.systemUptime < until else { break }
            let point = CGPoint(x: x, y: frame.midY)
            if controlHit(point, tile: tile, owner: owner, body: body) { return point }
        }
        return nil
    }
}
private extension Array { var only: Element? { count == 1 ? first : nil } }

@MainActor private final class WorkspacePreparation {
    let file: URL
    var state: CIState?
    init(file: URL) { self.file = file }
    func save(_ phase: String? = nil) throws {
        if let phase { state?.phase = phase }
        guard let state else { throw Refusal("originalStateNotRecorded") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: file, options: .atomic)
    }
    func event(_ name: String, error: AXError? = nil) throws {
        state?.events.append(.init(operation: name, uptime: ProcessInfo.processInfo.systemUptime, axError: error?.rawValue))
        try save()
    }
    func verifyRun() throws {
        let ci = try ciIdentity()
        guard let state, state.schema == 1, state.repository == ci.repository, state.runID == ci.run,
              state.attempt == ci.attempt, state.boot == (try bootID()), AXIsProcessTrusted(), NSEvent.pressedMouseButtons == 0 else {
            throw Refusal("recordedRunBootOrExistingAXAccessChanged")
        }
    }
    func originalSurvives(_ snapshot: CISnapshot) -> Bool {
        guard let state, snapshot.display == state.original.display else { return false }
        let ids = Set(state.original.records.map(\.id))
        return snapshot.records.filter { ids.contains($0.id) }.map(\.id) == state.original.records.map(\.id) &&
            state.original.records.allSatisfy { before in
                snapshot.records.contains { after in
                    before.id == after.id && before.type == after.type &&
                        (before.uuid == after.uuid || (before.uuid.isEmpty && after.hasUUID))
                }
            }
    }
    func fresh() async throws -> CISnapshot {
        let first = try CISnapshot.read()
        try await Task.sleep(for: .milliseconds(90))
        let second = try CISnapshot.read()
        guard first.sameScope(second) else { throw Refusal("rawInventoryStillChanging") }
        return second
    }
    func poll<T>(_ seconds: Double, _ read: () throws -> T?) async throws -> T {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        var reason = "systemObservationTimedOut"
        repeat {
            do { if let result = try read() { return result } }
            catch { reason = (error as? Refusal)?.reason ?? String(describing: error) }
            try await Task.sleep(for: .milliseconds(90))
        } while ProcessInfo.processInfo.systemUptime < until
        throw Refusal(reason)
    }
    func overview() throws -> AXUIElement? {
        let dock = try SystemDock.identity(), root = AXUIElementCreateApplication(dock.pid)
        _ = AXUIElementSetMessagingTimeout(root, 0.3)
        let roots = try children(root, named: "mc")
        guard roots.count <= 1, roots.allSatisfy(dock.owns) else { throw Refusal("ambiguousSignedOverviewRoot") }
        try dock.verify()
        return roots.first
    }
    func launch(_ app: String, event name: String) async throws {
        try verifyRun(); try event("intent:" + name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open"); process.arguments = ["-g", "-a", app]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let until = ProcessInfo.processInfo.systemUptime + 5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < until { try await Task.sleep(for: .milliseconds(50)) }
        guard !process.isRunning else { process.terminate(); throw Refusal("systemApplicationLaunchTimedOut") }
        guard process.terminationStatus == 0 else { throw Refusal("systemApplicationLaunchFailed") }
        try event("issued:" + name)
    }
    func openOverview() async throws {
        if try overview() == nil {
            try await launch("/System/Applications/Mission Control.app", event: "openMissionControl")
        }
        let _: AXUIElement = try await poll(5) { try self.overview() }
    }
    func closeOverview() async throws {
        guard let owned = try overview() else { return }
        var actions: CFArray?
        if AXUIElementCopyActionNames(owned, &actions) == .success, (actions as? [String])?.contains(kAXCancelAction) == true {
            try verifyRun(); try event("intent:cancelMissionControl")
            let result = AXUIElementPerformAction(owned, kAXCancelAction as CFString)
            try event("issued:cancelMissionControl", error: result)
            if result == .success {
                let dismissed: Bool? = try? await poll(1) { try self.overview() == nil ? true : nil }
                if dismissed == true { return }
            }
        }
        if let still = try overview() {
            guard CFEqual(still, owned) else { throw Refusal("overviewReplacedBeforeClose") }
            try await launch("/System/Applications/Mission Control.app", event: "closeMissionControl")
        }
        let _: Bool = try await poll(4) { try self.overview() == nil ? true : nil }
    }
    func action(_ operation: String, snapshot: CISnapshot, target: UInt64? = nil,
                overviewMembers: Set<UInt32> = []) async throws {
        try verifyRun(); try await openOverview()
        let tiles: CITiles = try await poll(4) { try CITiles(snapshot) }
        let second = try CITiles(snapshot)
        guard tiles.sameObjects(second), snapshot.sameScope(try CISnapshot.read()) else { throw Refusal("systemControlsChangedBeforeAction") }
        let index = target.flatMap { id in snapshot.records.firstIndex { $0.id == id } }
        let control: AXUIElement, name: String
        switch operation {
        case "add": control = second.bar.add; name = kAXPressAction
        case "select", "remove":
            guard let index else { throw Refusal("targetOutsideRecordedInventory") }
            control = second.elements[index]; name = operation == "remove" ? "AXRemoveDesktop" : kAXPressAction
        default: throw Refusal("unknownSystemAction")
        }
        if operation == "remove", let target { _ = try empty(target, beforeOverview: overviewMembers) }
        try second.bar.verify(control)
        var available: CFArray?
        guard AXUIElementCopyActionNames(control, &available) == .success, (available as? [String])?.contains(name) == true,
              attr(control, kAXEnabledAttribute) as? Bool == true else { throw Refusal("requiredSystemAXActionUnavailable") }
        try verifyRun(); try event("intent:" + operation)
        let result = AXUIElementPerformAction(control, name as CFString)
        try event("issued:" + operation, error: result)
        guard result == .success else { throw Refusal("systemAXActionReturned:" + String(result.rawValue)) }
        guard operation == "select", let target, let index else { return }
        let selected: Bool? = try? await poll(0.8) { try CISnapshot.read().current == target ? true : nil }
        if selected == true { try await closeOverview(); return }
        // Some Dock builds acknowledge AXPress without selecting. Only a fresh,
        // exactly hit-tested thumbnail body may complete that same selection.
        guard let pointer = CGEvent(source: nil)?.location, CGPreflightPostEventAccess(),
              let hover = second.point(index, body: false) else { throw Refusal("systemTileSelectionUnconfirmed") }
        var lastPoint = hover
        defer { if CGEvent(source: nil)?.location == lastPoint { CGWarpMouseCursorPosition(pointer) } }
        CGWarpMouseCursorPosition(hover)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: hover, mouseButton: .left)?.post(tap: .cgSessionEventTap)
        let point: CGPoint = try await poll(3) {
            let current = try CITiles(snapshot)
            guard current.sameObjects(second), snapshot.sameScope(try CISnapshot.read()) else { throw Refusal("systemTileChangedDuringHover") }
            return current.point(index, body: true)
        }
        guard controlHit(point, tile: control, owner: second.bar.owner.pid, body: true),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw Refusal("systemTileBodyLostBeforeClick")
        }
        try verifyRun(); try event("intent:hitTestedTileClick")
        lastPoint = point; down.setIntegerValueField(.mouseEventClickState, value: 1); up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cgSessionEventTap); up.post(tap: .cgSessionEventTap)
        try event("issued:hitTestedTileClick")
        let _: Bool = try await poll(5) { try CISnapshot.read().current == target ? true : nil }
        try await closeOverview()
    }
    func empty(_ desktop: UInt64, beforeOverview: Set<UInt32>? = nil) throws -> Set<UInt32> {
        guard let ids = NPReadCatalogSpaceWindowNumbers(desktop) as? [UInt32], ids.count <= 512, !ids.contains(0) else {
            throw Refusal("createdDesktopMembershipUnreadable")
        }
        for number in ids {
            guard let values = CFArrayCreateMutable(nil, 1, nil), let pointer = UnsafeRawPointer(bitPattern: UInt(number)) else { throw Refusal("memberIDUnavailable") }
            CFArrayAppendValue(values, pointer)
            guard let rows = CGWindowListCreateDescriptionFromArray(values) as? [[String: Any]], rows.count == 1,
                  rows[0][kCGWindowNumber as String] as? UInt32 == number,
                  let pid = rows[0][kCGWindowOwnerPID as String] as? pid_t, let layer = rows[0][kCGWindowLayer as String] as? Int,
                  let memberships = NPReadWindowSpacesIncludingHidden(number) as? [UInt64], memberships.contains(desktop),
                  let service = signedSystemService(pid),
                  layer != 0 || (service == "com.apple.WindowManager" && beforeOverview?.contains(number) == false && (try? overview()) != nil)
            else { throw Refusal("createdDesktopIsNotConfirmedEmptyOfOrdinaryWindows") }
        }
        return Set(ids)
    }
    func prepare() async throws {
        let ci = try ciIdentity()
        guard !FileManager.default.fileExists(atPath: file.path), AXIsProcessTrusted() else { throw Refusal("stateAlreadyExistsOrAXUnavailable") }
        let original = try await fresh()
        guard original.active?.type == 0, original.records.allSatisfy({ $0.type == 0 }) else { throw Refusal("CIRequiresOrdinaryDesktopBaseline") }
        state = .init(schema: 1, repository: ci.repository, runID: ci.run, attempt: ci.attempt, boot: try bootID(),
                      original: original, phase: "recorded", pendingAdd: false, created: nil, latest: original, events: [])
        try save()
        if original.active?.hasUUID == true { try save("readyExisting"); return }
        try await launch("/System/Library/CoreServices/Finder.app", event: "launchFinder")
        try await openOverview(); try await closeOverview()
        var current = try await fresh()
        guard originalSurvives(current), current.records.map(\.id) == original.records.map(\.id), current.current == original.current else {
            throw Refusal("systemInitializationChangedProtectedDesktopSet")
        }
        state?.latest = current; try save("systemInitialized")
        if current.active?.hasUUID == true { try save("readySystemInitialized"); return }
        state?.pendingAdd = true; try save("adding")
        try await action("add", snapshot: current)
        current = try await poll(6) {
            let next = try CISnapshot.read(), old = Set(original.records.map(\.id))
            let added = next.records.filter { !old.contains($0.id) }
            guard self.originalSurvives(next), added.count <= 1 else { throw Refusal("unexpectedDesktopChangeAfterAdd") }
            return added.count == 1 ? next : nil
        }
        guard let created = current.records.first(where: { !Set(original.records.map(\.id)).contains($0.id) }), created.type == 0 else { throw Refusal("newOrdinaryDesktopNotObserved") }
        state?.created = created; state?.pendingAdd = false; state?.latest = current; try save("created")
        guard created.hasUUID else { throw Refusal("systemCreatedDesktopStillHasNoUUID") }
        if current.current != created.id { try await action("select", snapshot: current, target: created.id) }
        try await closeOverview(); current = try await fresh()
        guard originalSurvives(current), current.current == created.id, current.active == created, current.active?.hasUUID == true else {
            throw Refusal("newCurrentDesktopIdentityNotConfirmed")
        }
        state?.latest = current; try save("readyCreated")
    }
    func cleanup() async throws {
        state = try JSONDecoder().decode(CIState.self, from: Data(contentsOf: file))
        try verifyRun()
        guard var state else { throw Refusal("stateUnavailable") }
        var current = try await fresh()
        guard originalSurvives(current) else { throw Refusal("protectedOriginalDesktopChanged") }
        if state.created == nil && state.pendingAdd {
            let originalIDs = Set(state.original.records.map(\.id)), extras = current.records.filter { !originalIDs.contains($0.id) }
            guard extras.count <= 1, extras.allSatisfy({ $0.type == 0 }) else { throw Refusal("ambiguousPendingAddOutcome") }
            state.created = extras.first; state.pendingAdd = false; self.state = state; try save("recoveredAddObservation")
        }
        let allowed = Set(state.original.records.map(\.id) + (state.created.map { [$0.id] } ?? []))
        guard Set(current.records.map(\.id)).isSubset(of: allowed) else { throw Refusal("unownedDesktopRemainsAtCleanup") }
        if current.current != state.original.current {
            try await action("select", snapshot: current, target: state.original.current)
            current = try await fresh()
        }
        guard current.current == state.original.current else { throw Refusal("originalDesktopNotRestored") }
        try await closeOverview()
        if let created = state.created, let actual = current.records.first(where: { $0.id == created.id }) {
            guard actual.type == created.type, actual.uuid == created.uuid || (created.uuid.isEmpty && actual.hasUUID),
                  created.id != current.current else { throw Refusal("createdDesktopIdentityChangedBeforeRemoval") }
            self.state?.created = actual; try save("removingCreated")
            let first = try empty(created.id)
            try await Task.sleep(for: .milliseconds(90))
            guard first == (try empty(created.id)) else { throw Refusal("createdDesktopEmptyReadChanged") }
            try await action("remove", snapshot: current, target: created.id, overviewMembers: first)
            let _: Bool = try await poll(6) { try CISnapshot.read().records.contains { $0.id == created.id } ? nil : true }
        }
        try await closeOverview(); current = try await fresh()
        guard originalSurvives(current), current.current == state.original.current,
              current.records.map(\.id) == state.original.records.map(\.id) else { throw Refusal("originalDesktopInventoryNotRestored") }
        self.state?.latest = current; try save("cleaned")
    }
    func report(status: String, cleanup: Bool, reason: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["schema": 1, "status": status, "cleanup": cleanup,
                                    "qualificationGranted": false, "directWindowOperations": 0, "physicalGestureClaimed": false]
        if let reason { result["reason"] = reason }
        if let state {
            result["phase"] = state.phase; result["originalCurrent"] = state.original.current
            if let created = state.created { result["created"] = ["id": created.id, "type": created.type, "uuid": created.uuid] as [String: Any] }
            else { result["created"] = NSNull() }
            result["current"] = state.latest?.current; result["currentHasSystemUUID"] = state.latest?.active?.hasUUID
            result["systemInputs"] = state.events.filter { $0.operation.hasPrefix("issued:") }.count
            result["lastRecordedStep"] = state.events.last?.operation
        }
        if status != "READY" { result["readOnlyDiagnostics"] = diagnostics() }
        return result
    }
    func diagnostics() -> [String: Any] {
        var result: [String: Any] = ["AXTrusted": AXIsProcessTrusted(), "screens": NSScreen.screens.count]
        if let snapshot = try? CISnapshot.read() {
            result["current"] = snapshot.current
            result["records"] = snapshot.records.map { ["id": $0.id, "type": $0.type, "uuid": $0.uuid] as [String: Any] }
            if let display = UUID(uuidString: snapshot.display),
               let bar = try? secondarySpacesBar(display, currentDisplay: true) {
                var geometry: [String: Any] = ["ownerPID": bar.owner.pid, "ownerBirth": bar.owner.birth,
                    "container": controlGeometry(bar.container), "spaces": controlGeometry(bar.spaces), "add": controlGeometry(bar.add)]
                if let list = try? children(bar.spaces, named: "mc.spaces.list").only {
                    geometry["list"] = controlGeometry(list)
                    geometry["tiles"] = (attr(list, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(32).enumerated().map { index, tile in
                        ["index": index, "role": attr(tile, kAXRoleAttribute) as? String ?? "unavailable",
                         "geometry": controlGeometry(tile)] as [String: Any]
                    }
                }
                result["spacesBarGeometry"] = geometry
            }
        }
        do {
            let dock = try SystemDock.identity(), root = AXUIElementCreateApplication(dock.pid)
            _ = AXUIElementSetMessagingTimeout(root, 0.12)
            result["signedDockPID"] = dock.pid; result["signedDockBirth"] = dock.birth
            var raw: CFTypeRef?
            result["rootChildrenAXError"] = AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &raw).rawValue
            let first = raw as? [AXUIElement] ?? []
            result["rootChildCount"] = first.count
            var pending = first.map { ($0, 0) }, identifiers = [String: Int](), roles = [String: Int](), seen = Set<AXUIElement>()
            let known = ["mc", "mc.display", "mc.spaces", "mc.spaces.list", "mc.spaces.add", "mc.windows"]
            while let (element, depth) = pending.popLast(), seen.count < 96 {
                guard dock.owns(element), seen.insert(element).inserted else { continue }
                let id = attr(element, kAXIdentifierAttribute) as? String ?? ""
                identifiers[known.contains(id) ? id : "other", default: 0] += 1
                roles[attr(element, kAXRoleAttribute) as? String ?? "unavailable", default: 0] += 1
                if depth < 4 { pending += (attr(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(96).map { ($0, depth + 1) } }
            }
            result["identifierCounts"] = identifiers; result["roleCounts"] = roles; result["boundedNodes"] = seen.count
        } catch { result["signedDockReason"] = (error as? Refusal)?.reason ?? String(describing: error) }
        return result
    }
}

private func signedSystemService(_ pid: pid_t) -> String? {
    var bytes = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
    let path = String(cString: bytes)
    let services = [OverviewAgent.dock.executable: OverviewAgent.dock.rawValue,
                    OverviewAgent.manager.executable: OverviewAgent.manager.rawValue,
                    "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder": "com.apple.finder",
                    "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer": "com.apple.WindowServer"]
    guard let identifier = services[path] else { return nil }
    var code: SecCode?, requirement: SecRequirement?
    guard SecRequirementCreateWithString(("anchor apple and identifier \"" + identifier + "\"") as CFString, [], &requirement) == errSecSuccess,
          SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess,
          code.map({ SecCodeCheckValidity($0, [], requirement) == errSecSuccess }) == true,
          proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0, String(cString: bytes) == path else { return nil }
    return identifier
}

@main private struct CIWorkspaceMain {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, ["prepare", "cleanup"].contains(arguments[1]) else { exit(2) }
        let cleanup = arguments[1] == "cleanup", worker = WorkspacePreparation(file: URL(fileURLWithPath: arguments[2]))
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited); app.finishLaunching()
        DispatchQueue.main.async {
            Task { @MainActor in
                let result: [String: Any]
                do {
                    if cleanup { try await worker.cleanup() } else { try await worker.prepare() }
                    result = worker.report(status: "READY", cleanup: cleanup)
                } catch {
                    result = worker.report(status: cleanup ? "FAIL" : "BLOCKED", cleanup: false,
                                           reason: (error as? Refusal)?.reason ?? String(describing: error))
                }
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
                }
                exit(0)
            }
        }
        app.run()
    }
}
