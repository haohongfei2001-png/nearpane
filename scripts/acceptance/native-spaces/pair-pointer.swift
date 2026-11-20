import AppKit
import ApplicationServices

// Session-level mouse events enter WindowServer hit-testing and AppKit's local drag session.
// This observer neither calls AXPress nor has APIs for setting document frames.
private let pairClock = { ProcessInfo.processInfo.systemUptime }

func pairAXRect(_ item: AXUIElement) -> CGRect? {
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

func pairRows() -> [Object]? {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [Object]
}

private func pairBounds(_ row: Object) -> CGRect? {
    guard let raw = row[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: raw)
}

func pairBounds(_ rows: [Object], _ number: UInt32, _ pid: pid_t) -> CGRect? {
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

    func point(_ fraction: CGFloat = 0.5, y: CGFloat = 0.5) -> CGPoint {
        CGPoint(x:(rect.minX+rect.width*fraction).rounded(),y:(rect.minY+rect.height*y).rounded())
    }
}

private struct PairSurface {
    let publishedReasons: [String]
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
        self.publishedReasons = index.knownIssues.compactMap { pairRefusals[$0] }.sorted()
        self.cards = cards; self.panel = panel; self.panelID = cards[0].panel
        self.displayUUID = CFUUIDCreateString(nil, uuid) as String
        self.visible = visible; self.pid = host.processIdentifier
    }

    private func axIssue(_ point: CGPoint, _ card: PairCard?) -> String? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              var node = hit else { return "systemAXHitUnavailable" }
        var sawCard = card == nil
        for _ in 0..<40 {
            guard pairOwner(node, pid) else { return "systemAXHitOutsideHost" }
            if let card, CFEqual(node,card.node) { sawCard = true }
            if value(node,kAXRoleAttribute) as? String == kAXWindowRole {
                return sawCard && NPReadAXWindowNumber(node)==panelID ? nil : "registeredCardOrPanelNotInHitAncestry"
            }
            guard let parent = pairParent(node) else { return "boundPanelNotInHitAncestry" }
            node = parent
        }
        return "hitAncestryOverLimit"
    }

    func hitIssue(_ point: CGPoint, card: PairCard?, dragging: Bool, cursor: (Object)->Void) -> String? {
        guard panel.contains(point) else { return "outsidePanel" }
        // Check the precise registered accessibility surface on both sides of the CG
        // stacking query. Between cards the hit must still descend from the same panel.
        let expected = card ?? cards.first { $0.rect.contains(point) }
        if let before = axIssue(point,expected) { return before }
        guard let rows = pairRows() else { return "CGStackUnavailable" }
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
            if layer == CGWindowLevelForKey(.cursorWindow) {
                guard let birth = PairSystemCursor.generation(owner) else { return "cursorLayerOwnerNotLiveAppleWindowServer" }
                let footprint = PairSystemCursor.footprint(bounds,cursor:CGEvent(source:nil)?.location,candidate:point)
                cursor(["number":number,"owner":"com.apple.WindowServer","pid":owner,"birth":birth,"layer":layer,
                        "size":[bounds.width,bounds.height],"pointerAndCandidateInSmallFootprint":footprint] as Object)
                guard footprint else { return "signedCursorLayerFootprintUnconfirmed" }
                continue
            }
            return (owner == pid ? "otherHostSurfaceAtLayer" : "otherSurfaceAtLayer") + String(layer)
        }
        guard found else { return "boundPanelUnavailableAtPoint" }
        return axIssue(point,expected)
    }
}

func pairNear(_ a: CGRect, _ b: CGRect) -> Bool {
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
    var receiver: PairPointerReceiver?, picture: PairPointerVisual?
    var events = [Object]()
    defer { receiver?.close(); picture?.cancel() }
    func finish() -> Object {
        if let receiver { result["hostRouting"] = receiver.receipt() }
        if let sample = picture {
            picture = nil
            if result["issued"] as? Bool == true {
                result["presentation"] = sample.finish(events: events)
            } else {
                sample.cancel()
                result["presentation"] = ["status":"NOT_RUN","reason":"noAdmittedMouseEvent"]
            }
        }
        return result
    }
    func stop(_ reason: String) -> Object {
        result["reason"] = reason; result["hidAfter"] = p2Physical()
        if let sample = picture, reason == "userSuperseded" || events.last?["type"] as? UInt32 != CGEventType.leftMouseUp.rawValue {
            picture = nil; sample.cancel()
            result["presentation"] = ["status":"UNKNOWN","reason":"gestureRelinquishedBeforeCompleteObservation","retainedPixelBytes":0] as Object
        }
        return finish()
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
                           "members":numbers,"publishedManagementReasons":surface.publishedReasons] as Object
    if kind == "read" { result["status"] = "READ"; return result }

    let source = surface.cards[slot], destination = kind == "self" || kind == "click" ? source : surface.cards[1-slot]
    var cursorChecks = [Object]()
    func admitted(_ point: CGPoint, _ card: PairCard?, dragging: Bool) -> Bool {
        let issue = surface.hitIssue(point, card: card, dragging: dragging) { evidence in
            if cursorChecks.count < 40 { cursorChecks.append(evidence); result["cursorChecks"] = cursorChecks }
        }
        guard let issue else { return true }
        result["hitRefusal"] = ["reason":issue, "point":[point.x,point.y], "inFlight":dragging] as Object
        return false
    }
    // A signed cursor is optional: prefer a different fully qualified point on the
    // same control when one point cannot be certified, without posting any event.
    func qualified(_ card: PairCard, fraction: CGFloat) -> CGPoint? {
        for y in [CGFloat(0.5),0.28,0.72] {
            let point = card.point(fraction,y:y)
            if admitted(point,card,dragging:false) { return point }
        }
        return nil
    }
    guard let start = qualified(source,fraction:0.5),
          let end = kind == "self" || kind == "click" ? Optional(start) : qualified(destination,fraction:kind == "left" ? 0.25 : 0.75),
          let eventSource = CGEventSource(stateID: .privateState), CGPreflightPostEventAccess() else {
        return stop("endpointCardHitOrEventPostingUnconfirmed")
    }
    if let earlier = result.removeValue(forKey:"hitRefusal") { result["earlierCandidateRefusal"] = earlier }
    result["qualifiedEndpoints"] = ["source":[start.x,start.y],"target":[end.x,end.y],"verified":"AX card+panel before and after Quartz stacking"] as Object
    let before = focus()
    guard kind != "click" || (before.0 == numbers[1-slot] && before.1 == before.0 && before.2) else {
        return stop("differentExactEditorNotFocusedBeforeClick")
    }

    if kind == "click" {
        picture = PairPointerVisual.start(request:request,numbers:numbers,target:target,frames:cg,displayUUID:surface.displayUUID)
        guard p2Physical() == hid else { return stop("userSuperseded") }
    }
    let tag = Int64.random(in: 1...Int64.max)
    receiver = PairPointerReceiver(host:host.processIdentifier, panel:surface.panelID, tag:tag)
    result["initialFocus"] = ["focused":before.0 as Any? ?? NSNull(), "main":before.1 as Any? ?? NSNull(),
                              "editor":before.2] as Object
    var down = false, previousPoint = start
    func event(_ type: CGEventType, _ point: CGPoint) -> CGEvent? {
        guard let e = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return nil }
        e.flags = []
        e.setIntegerValueField(.eventSourceUserData, value: tag)
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        return e
    }
    func dispatch(_ type: CGEventType, _ point: CGPoint) -> Bool {
        guard let e = event(type, point), let movement = PairPointerMotion.apply(e, from:previousPoint, to:point),
              p2Physical() == hid else { return false }
        let t = pairClock()
        e.timestamp = DispatchTime.now().uptimeNanoseconds
        e.post(tap: .cgSessionEventTap)
        events.append(["type":type.rawValue,"beforePost":t,"afterPost":pairClock(),"eventTimestampNS":e.timestamp,
                       "point":[point.x,point.y],"previousPoint":[previousPoint.x,previousPoint.y],"quartzDelta":movement,
                       "expectedAppKitPanelPoint":[point.x-surface.panel.minX,surface.panel.maxY-point.y]] as Object)
        previousPoint = point
        result["motionUnits"] = "global Quartz logical points and integer kCGMouseEventDeltaX/Y"
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
    if kind == "click" {
        let fresh = focus()
        guard fresh.0 == numbers[1-slot], fresh.1 == fresh.0, fresh.2 else {
            return stop("exactSiblingChangedDuringDisplayEnrollment")
        }
    }
    guard scopeCurrent(), admitted(start, source, dragging: false), dispatch(.leftMouseDown, start) else {
        return abort("mouseDownAdmissionChanged")
    }
    down = true
    PairPointerReceiver.pump(kind == "click" ? 0.035 : 0.14)
    if kind != "click" {
        let waypoint = kind == "self" ? CGPoint(x: start.x + min(20, source.rect.width * 0.36), y: start.y) : end
        var path = [CGPoint]()
        func segment(_ from: CGPoint, _ to: CGPoint, _ count: Int) {
            for step in 1...count {
                let t = CGFloat(step)/CGFloat(count)
                path.append(PairPointerMotion.point(from:from, to:to, fraction:t))
            }
        }
        segment(start, waypoint, 9)
        if kind == "self" { segment(waypoint, end, 7) }
        var selfPath = [Object]()
        for point in path {
            guard p2Physical() == hid, scopeCurrent(), admitted(point, nil, dragging: true),
                  dispatch(.leftMouseDragged, point) else { return abort("dragPathLeftQualifiedHostPanel") }
            PairPointerReceiver.pump(0.016)
            if kind == "self", let snapshot = pairRows() {
                let actual = numbers.compactMap { pairBounds(snapshot, $0, pid) }
                selfPath.append(["clock":pairClock(),"cg":actual.map(windowReceiptRect)] as Object)
            }
        }
        if kind == "self" { result["duringSelfDrag"] = selfPath }
        PairPointerReceiver.pump(0.06)
    }
    guard p2Physical() == hid, scopeCurrent(), admitted(end, destination, dragging: down && kind != "click"),
          dispatch(.leftMouseUp, end) else { return abort("mouseUpTargetOrScopeChanged") }
    down = false
    result["hardwareUnchangedAtRelease"] = p2Physical() == hid
    if kind != "click" {
        result["status"] = "DISPATCHED"
        PairPointerReceiver.pump(0.025)
        return finish()
    }

    // First and second persistent system observations use the same monotonic clock as
    // posting. Poll intervals also include the AX calls and are retained as bounds.
    let released = events.last!["beforePost"] as! Double
    var lastFalseStart = released, first: (Double,Double)?, reads = 0
    var states = [String:Int](), transitions = [Object](), previous = ""
    let deadline = released + 3
    while pairClock() < deadline {
        guard p2Physical() == hid else { return stop("userSuperseded") }
        let t = pairClock(), f = focus(), finished = pairClock()
        reads += 1
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontKind = front == pid ? "fixture" : front == host.processIdentifier ? "host" : "otherOrUnavailable"
        func slotOf(_ n: UInt32?) -> String { n == target ? "target" : n == numbers[1-slot] ? "sibling" : "unavailable" }
        let state = [frontKind,slotOf(f.0),slotOf(f.1),f.2 ? "exactEditor":"otherEditor"].joined(separator:"/")
        states[state, default:0] += 1
        if state != previous && transitions.count < 24 {
            transitions.append(["state":state,"start":t,"end":finished]); previous = state
        }
        result["focusStates"] = ["counts":states,"firstTransitions":transitions] as Object
        if f.0 == target && f.1 == target && f.2 {
            if let first {
                result["focus"] = ["lastNegativeSampleStarted":lastFalseStart,"firstPositiveStart":first.0,
                                   "firstPositiveEnd":first.1,"secondPositiveEnd":finished,"reads":reads,
                                   "target":target,"clock":"systemUptime","method":"systemAndAppAXFocusedWindowMainExactEditor"] as Object
                guard scopeCurrent() else { return stop("leasedScopeChangedDuringFocusRead") }
                result["status"] = "FOCUSED"
                PairPointerReceiver.pump(0.015)
                return finish()
            }
            first = (t,finished)
        } else { lastFalseStart = t; first = nil }
        PairPointerReceiver.pump(0.006)
    }
    result["focus"] = ["reads":reads,"lastNegativeSampleStarted":lastFalseStart,"deadline":deadline] as Object
    return stop("systemFocusReadbackTimedOut")
}
