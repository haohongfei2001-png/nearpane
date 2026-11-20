import AppKit
import ApplicationServices

// Session-level mouse events enter WindowServer hit-testing and AppKit's local drag session.
// This observer neither calls AXPress nor has APIs for setting document frames.
private let pairClock = { ProcessInfo.processInfo.systemUptime }

private func pairAXRect(_ item: AXUIElement) -> CGRect? {
    guard let pos = value(item, kAXPositionAttribute), let size = value(item, kAXSizeAttribute),
          CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s),
          p.x.isFinite, p.y.isFinite, s.width.isFinite, s.height.isFinite, s.width > 0, s.height > 0 else { return nil }
    return CGRect(origin: p, size: s)
}

private func pairParent(_ node: AXUIElement) -> AXUIElement? {
    guard let parent = value(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
    return (parent as! AXUIElement)
}

private func pairOwner(_ node: AXUIElement, _ pid: pid_t) -> Bool {
    var owner: pid_t = 0
    return AXUIElementGetPid(node, &owner) == .success && owner == pid
}

private func pairRows() -> [Object]? {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [Object]
}

private func pairBounds(_ row: Object) -> CGRect? {
    guard let raw = row[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: raw)
}

private func pairBounds(_ rows: [Object], _ number: UInt32, _ pid: pid_t) -> CGRect? {
    let matches = rows.filter {
        $0[kCGWindowNumber as String] as? UInt32 == number && $0[kCGWindowOwnerPID as String] as? pid_t == pid &&
        $0[kCGWindowIsOnscreen as String] as? Bool == true
    }
    guard matches.count == 1 else { return nil }
    return pairBounds(matches[0])
}

private struct PairCard {
    let node: AXUIElement
    let rect: CGRect
    let panel: UInt32

    init?(_ node: AXUIElement, host: pid_t) {
        guard pairOwner(node, host), value(node, kAXRoleAttribute) as? String == kAXButtonRole,
              value(node, kAXEnabledAttribute) as? Bool == true, let rect = pairAXRect(node),
              rect.width >= 24, rect.height >= 16 else { return nil }
        var ancestor = node
        for _ in 0..<40 {
            guard pairOwner(ancestor, host) else { return nil }
            if value(ancestor, kAXRoleAttribute) as? String == kAXWindowRole {
                let number = NPReadAXWindowNumber(ancestor)
                guard number > 0 else { return nil }
                self.node = node; self.rect = rect; self.panel = number
                return
            }
            guard let parent = pairParent(ancestor) else { return nil }
            ancestor = parent
        }
        return nil
    }

    func point(_ fraction: CGFloat = 0.5) -> CGPoint {
        CGPoint(x: (rect.minX + rect.width * fraction).rounded(), y: rect.midY.rounded())
    }
}

private struct PairSurface {
    let cards: [PairCard], panel: CGRect, visible: CGRect, panelID: UInt32, pid: pid_t, displayUUID: String

    init?(host: NSRunningApplication, pid: pid_t, numbers: [UInt32], rows: [Object]) {
        let index = Sidebar(host, rows: rows)
        let ids = numbers.map { "current-desktop-window:\(pid):\($0)" }
        guard Set(index.controls.keys.filter { $0.hasPrefix("current-desktop-window:") }) == Set(ids) else { return nil }
        let cards = ids.compactMap { id -> PairCard? in
            guard let hits = index.controls[id], hits.count == 1 else { return nil }
            return PairCard(hits[0], host: host.processIdentifier)
        }
        guard cards.count == 2, cards[0].panel == cards[1].panel, !cards[0].rect.intersects(cards[1].rect),
              let panel = pairBounds(rows, cards[0].panel, host.processIdentifier),
              cards.allSatisfy({panel.contains($0.rect)}), NSScreen.screens.count == 1, let screen = NSScreen.screens.first,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
              id == CGMainDisplayID(), let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        let display = CGDisplayBounds(id), usable = screen.visibleFrame
        let visible = CGRect(x: display.minX + usable.minX - screen.frame.minX, y: display.minY + screen.frame.maxY - usable.maxY,
                             width: usable.width, height: usable.height)
        guard visible.contains(panel.insetBy(dx: 1, dy: 1)) else { return nil }
        self.cards = cards; self.panel = panel; self.panelID = cards[0].panel
        self.displayUUID = CFUUIDCreateString(nil, uuid) as String
        self.visible = visible; self.pid = host.processIdentifier
    }

    func hitIssue(_ point: CGPoint, card: PairCard?, dragging: Bool) -> String? {
        guard panel.contains(point), let rows = pairRows() else { return "outsidePanelOrCGReadUnavailable" }
        // The WindowServer list is front-to-back. Ignore only this same Host's
        // transient AppKit drag image at the documented dragging-window level.
        var found = false
        for row in rows {
            guard let bounds = pairBounds(row) else { return "unclassifiedSurfaceBounds" }
            guard bounds.contains(point) else { continue }
            guard let alpha = row[kCGWindowAlpha as String] as? Double else { return "unclassifiedSurfaceOpacity" }
            if alpha == 0 { continue }
            guard let owner = row[kCGWindowOwnerPID as String] as? pid_t,
                  let number = row[kCGWindowNumber as String] as? UInt32,
                  let layer = row[kCGWindowLayer as String] as? Int32 else { return "unclassifiedSurfaceIdentity" }
            if number == panelID && owner == pid { found = true; break }
            if dragging && owner == pid && layer == CGWindowLevelForKey(.draggingWindow) { continue }
            return (owner == pid ? "otherHostSurfaceAtLayer" : "otherSurfaceAtLayer") + String(layer)
        }
        guard found else { return "boundPanelUnavailableAtPoint" }
        guard let card else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              var node = hit else { return "systemAXHitUnavailable" }
        for _ in 0..<40 {
            guard pairOwner(node, pid) else { return "systemAXHitOutsideHost" }
            if CFEqual(node, card.node) { return nil }
            guard let parent = pairParent(node) else { return "boundCardNotInHitAncestry" }
            node = parent
        }
        return "hitAncestryOverLimit"
    }
}

private func pairNear(_ a: CGRect, _ b: CGRect) -> Bool {
    zip(windowReceiptRect(a), windowReceiptRect(b)).allSatisfy { abs($0 - $1) <= 1 }
}

private func pairOwnsIsolatedHome(_ host: pid_t) -> Bool {
    guard let name = ProcessInfo.processInfo.environment["NEARPANE_TEST_HOME"],
          let user = getpwuid(getuid()) else { return false }
    let home = URL(fileURLWithPath: name), parent = home.deletingLastPathComponent()
    let caches = URL(fileURLWithPath:String(cString:user.pointee.pw_dir)).appendingPathComponent("Library/Caches")
    guard home.lastPathComponent == "home", parent.lastPathComponent.hasPrefix("nearpane-native-acceptance."),
          parent.deletingLastPathComponent().path == caches.path,
          home.resolvingSymlinksInPath().standardizedFileURL.path == home.path else { return false }
    for url in [home,parent] {
        var st = stat()
        guard lstat(url.path,&st) == 0, st.st_uid == getuid(), st.st_mode & 0o177777 == 0o40700 else { return false }
    }
    let lock = home.appendingPathComponent("Library/Application Support/Nearpane Alpha Profiles/writer.lock")
    let proc = Process(), pipe = Pipe()
    proc.executableURL = URL(fileURLWithPath:"/usr/sbin/lsof")
    proc.arguments = ["-a","-p",String(host),"-t",lock.path]
    proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
    guard (try? proc.run()) != nil else { return false }
    let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return proc.terminationStatus == 0 && Int32(String(decoding:bytes,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)) == host
}

func pairPointer(kind: String, target: UInt32, host: NSRunningApplication, request: P2Request, uuid: String,
                 numbers: [UInt32], windows: [AXUIElement], focus: () -> (UInt32?, UInt32?, Bool)) -> Object {
    var result: Object = ["status":"BLOCKED", "issued":false, "dispatch":"WindowServer.cgSessionEventTap",
                          "kind":kind, "target":target, "events":[], "hid":p2Physical()]
    func stop(_ reason: String) -> Object {
        result["reason"] = reason; result["hidAfter"] = p2Physical()
        return result
    }
    guard let pid = request.pid, let slot = numbers.firstIndex(of: target),
          let hostBirth = request.hostBirth, let birth = request.birth, let hid = request.hid,
          ["read", "click", "self", "left", "right"].contains(kind) else { return stop("invalidPairPointerIntent") }
    func scopeCurrent() -> Bool {
        guard birthMicroseconds(host.processIdentifier) == hostBirth, birthMicroseconds(pid) == birth,
              let scopes = inventory(requireComplete: true), scopes.count == 1, let scope = scopes.first,
              scope["scope"] as? String == request.display, scope["current"] as? UInt64 == request.space,
              (scope["records"] as? [Object])?.contains(where: { $0["id"] as? UInt64 == request.space &&
                  $0["type"] as? Int == 0 && ($0["uuid"] as? String)?.lowercased() == uuid.lowercased() }) == true,
              let catalog = NPReadCatalogSpaceWindowNumbers(request.space) as? [UInt32], Set(numbers).isSubset(of: Set(catalog)),
              numbers.allSatisfy({ NPReadWindowSpaces($0) as? [UInt64] == [request.space] }),
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        return front == pid || front == host.processIdentifier
    }
    guard kind == "read" || pairOwnsIsolatedHome(host.processIdentifier) else { return stop("isolatedHostWriterLockUnconfirmed") }
    guard p2Physical() == hid, NSEvent.pressedMouseButtons == 0 else { return stop("userSuperseded") }
    guard scopeCurrent(), let rows = pairRows(), let surface = PairSurface(host: host, pid: pid, numbers: numbers, rows: rows) else {
        return stop("twoVisibleUniqueInstalledCardFramesOrLeaseUnconfirmed")
    }
    let otherOrdinary = rows.contains { row in
        guard row[kCGWindowLayer as String] as? Int == 0, let r = pairBounds(row), r.width > 2, r.height > 2,
              let number = row[kCGWindowNumber as String] as? UInt32, let owner = row[kCGWindowOwnerPID as String] as? pid_t,
              owner != host.processIdentifier && owner != pid else { return false }
        return (NPReadWindowSpaces(number) as? [UInt64])?.contains(request.space) != false
    }
    guard !otherOrdinary else { return stop("unboundVisibleOrdinaryWindowInLeasedSpace") }
    let cg = numbers.compactMap { pairBounds(rows, $0, pid) }
    let ax = windows.compactMap(pairAXRect)
    guard cg.count == 2, ax.count == 2, zip(cg,ax).allSatisfy(pairNear) else { return stop("enrolledSystemWindowBoundsDisagree") }
    result["geometry"] = ["clock":pairClock(), "ax":ax.map(windowReceiptRect), "cg":cg.map(windowReceiptRect),
                           "panel":windowReceiptRect(surface.panel), "visible":windowReceiptRect(surface.visible),
                           "cards":surface.cards.map { windowReceiptRect($0.rect) }, "panelID":surface.panelID, "displayUUID":surface.displayUUID,
                           "members":numbers] as Object
    if kind == "read" { result["status"] = "READ"; return result }

    let source = surface.cards[slot], destination = kind == "self" || kind == "click" ? source : surface.cards[1-slot]
    let start = source.point(), end = destination.point(kind == "left" ? 0.25 : kind == "right" ? 0.75 : 0.5)
    func admitted(_ point: CGPoint, _ card: PairCard?, dragging: Bool) -> Bool {
        guard let issue = surface.hitIssue(point, card: card, dragging: dragging) else { return true }
        result["hitRefusal"] = ["reason":issue, "point":[point.x,point.y], "inFlight":dragging] as Object
        return false
    }
    guard admitted(start, source, dragging: false), admitted(end, destination, dragging: false),
          let eventSource = CGEventSource(stateID: .privateState), CGPreflightPostEventAccess() else {
        return stop("endpointCardHitOrEventPostingUnconfirmed")
    }
    let before = focus()
    guard kind != "click" || (before.0 == numbers[1-slot] && before.1 == before.0 && before.2) else {
        return stop("differentExactEditorNotFocusedBeforeClick")
    }

    let tag = Int64.random(in: 1...Int64(Int32.max))
    var events = [Object](), down = false
    func event(_ type: CGEventType, _ point: CGPoint) -> CGEvent? {
        guard let e = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return nil }
        e.flags = []
        e.setIntegerValueField(.eventSourceUserData, value: tag)
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.setIntegerValueField(.mouseEventNumber, value: tag)
        return e
    }
    func dispatch(_ type: CGEventType, _ point: CGPoint) -> Bool {
        guard let e = event(type, point), p2Physical() == hid else { return false }
        let t = pairClock()
        e.post(tap: .cgSessionEventTap)
        events.append(["type":type.rawValue,"beforePost":t,"afterPost":pairClock(),"eventTimestampNS":e.timestamp,
                       "point":[point.x,point.y]] as Object)
        result["events"] = events; result["issued"] = true
        return true
    }
    func abort(_ reason: String) -> Object {
        // Balance only the existing synthetic gesture on its original enrolled Host.
        // Never release a session-wide button into a newly arrived user's application.
        if down, birthMicroseconds(host.processIdentifier) == hostBirth, let release = event(.leftMouseUp, start) {
            release.postToPid(host.processIdentifier)
            result["cancel"] = "releasedToOriginalHostAtSource"; down = false
        }
        return stop(p2Physical() == hid ? reason : "userSuperseded")
    }
    guard scopeCurrent(), admitted(start, source, dragging: false), dispatch(.leftMouseDown, start) else {
        return abort("mouseDownAdmissionChanged")
    }
    down = true
    Thread.sleep(forTimeInterval: kind == "click" ? 0.035 : 0.14)
    if kind != "click" {
        let waypoint = kind == "self" ? CGPoint(x: start.x + min(20, source.rect.width * 0.36), y: start.y) : end
        var path = [CGPoint]()
        func segment(_ from: CGPoint, _ to: CGPoint, _ count: Int) {
            for step in 1...count {
                let t = CGFloat(step)/CGFloat(count)
                path.append(CGPoint(x: from.x + (to.x-from.x)*t, y: from.y + (to.y-from.y)*t))
            }
        }
        segment(start, waypoint, 9)
        if kind == "self" { segment(waypoint, end, 7) }
        var selfPath = [Object]()
        for point in path {
            guard p2Physical() == hid, scopeCurrent(), admitted(point, nil, dragging: true),
                  dispatch(.leftMouseDragged, point) else { return abort("dragPathLeftQualifiedHostPanel") }
            Thread.sleep(forTimeInterval: 0.016)
            if kind == "self", let snapshot = pairRows() {
                let actual = numbers.compactMap { pairBounds(snapshot, $0, pid) }
                selfPath.append(["clock":pairClock(),"cg":actual.map(windowReceiptRect)] as Object)
            }
        }
        if kind == "self" { result["duringSelfDrag"] = selfPath }
        Thread.sleep(forTimeInterval: 0.06)
    }
    guard p2Physical() == hid, scopeCurrent(), admitted(end, destination, dragging: down && kind != "click"),
          dispatch(.leftMouseUp, end) else { return abort("mouseUpTargetOrScopeChanged") }
    down = false
    result["hardwareUnchangedAtRelease"] = p2Physical() == hid
    if kind != "click" {
        result["status"] = "DISPATCHED"
        return result
    }

    // First and second persistent system observations use the same monotonic clock as
    // posting. Poll intervals also include the AX calls and are retained as bounds.
    let released = events.last!["beforePost"] as! Double
    var lastFalseStart = released, first: (Double,Double)?, reads = 0
    let deadline = released + 3
    while pairClock() < deadline {
        guard p2Physical() == hid else { return stop("userSuperseded") }
        let t = pairClock(), f = focus(), finished = pairClock()
        reads += 1
        if f.0 == target && f.1 == target && f.2 {
            if let first {
                result["focus"] = ["lastNegativeSampleStarted":lastFalseStart,"firstPositiveStart":first.0,
                                   "firstPositiveEnd":first.1,"secondPositiveEnd":finished,"reads":reads,
                                   "target":target,"clock":"systemUptime","method":"systemAndAppAXFocusedWindowMainExactEditor"] as Object
                guard scopeCurrent() else { return stop("leasedScopeChangedDuringFocusRead") }
                result["status"] = "FOCUSED"
                return result
            }
            first = (t,finished)
        } else { lastFalseStart = t; first = nil }
        Thread.sleep(forTimeInterval: 0.006)
    }
    result["focus"] = ["reads":reads,"lastNegativeSampleStarted":lastFalseStart,"deadline":deadline] as Object
    return stop("systemFocusReadbackTimedOut")
}
