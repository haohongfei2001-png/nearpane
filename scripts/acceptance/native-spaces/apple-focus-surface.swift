import AppKit
import ApplicationServices

// A passive admission probe after P2 has authenticated the fixture and both original
// document AX objects. Never read a system button's title, description, value or image.
func appleFocusSurface(_ request: P2Request, windows: [AXUIElement], numbers: [UInt32]) -> Object {
    var out: Object = ["status":"BLOCKED", "issued":false, "retainedPixelBytes":0, "presentationSamples":0,
                       "operation":"selectWindowFromAlreadyVisiblePicker", "t0":"sessionMouseDown"]
    func stop(_ why: String) -> Object {out["reason"] = why; return out}
    var display: CGDirectDisplayID = 0, count: UInt32 = 0
    guard request.hid == p2Physical(), request.hostBirth != nil, request.spaceUUID != nil,
          numbers.count == 2, windows.count == 2, let pid = request.pid, let birth = request.birth,
          let fixtureHash = request.hash, let session = request.session,
          CGGetOnlineDisplayList(0,nil,&count) == .success, count == 1,
          CGGetActiveDisplayList(1,&display,&count) == .success, count == 1, CGDisplayIsInMirrorSet(display) == 0,
          let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
          (CFUUIDCreateString(nil,uuid) as String).lowercased() == request.display.lowercased()
    else {return stop("enrollmentOrPhysicalDisplayUnavailable")}
    func scope() -> Bool {
        guard request.hid == p2Physical(), NSEvent.pressedMouseButtons == 0, pairLeaseState(request) == "BOUND",
              birthMicroseconds(pid) == birth, runningCodeHash(pid) == fixtureHash,
              birthMicroseconds(request.hostPID) == request.hostBirth, runningCodeHash(request.hostPID) == request.hostHash,
              let forward = NPReadCatalogSpaceWindowNumbers(request.space) as? [UInt32] else {return false}
        return zip(windows,numbers).allSatisfy { window, n in
            var owner: pid_t = 0
            return AXUIElementGetPid(window,&owner) == .success && owner == pid && NPReadAXWindowNumber(window) == n &&
                forward.filter { $0 == n }.count == 1 && NPReadWindowSpaces(n) as? [UInt64] == [request.space]
        }
    }
    func frame(_ node: AXUIElement) -> CGRect? {
        guard let pos = attr(node,kAXPositionAttribute), CFGetTypeID(pos) == AXValueGetTypeID(),
              let size = attr(node,kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else {return nil}
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pos as! AXValue,.cgPoint,&p), AXValueGetValue(size as! AXValue,.cgSize,&s),
              p.x.isFinite, p.y.isFinite, s.width > 1, s.height > 1 else {return nil}
        return CGRect(origin:p,size:s)
    }
    struct Target { let node: AXUIElement, owner: OverviewProcess, box: CGRect }
    let bounds = CGDisplayBounds(display)
    func sysString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name,nil,&size,nil,0) == 0, (2...128).contains(size) else {return nil}
        var bytes = [CChar](repeating:0,count:size)
        guard sysctlbyname(name,&bytes,&size,nil,0) == 0 else {return nil}
        return String(cString:bytes)
    }
    func box(_ rect: CGRect) -> [CGFloat] { [rect.minX,rect.minY,rect.width,rect.height] }
    func environment() -> Object? {
        guard let mode = CGDisplayCopyDisplayMode(display), let os = sysString("kern.osversion"),
              let boot = sysString("kern.bootsessionuuid"), let spaceUUID = request.spaceUUID,
              let stage = CFPreferencesCopyAppValue("GloballyEnabled" as CFString,"com.apple.WindowManager" as CFString) as? Bool
        else {return nil}
        let observed = windows.compactMap(frame)
        guard observed.count == numbers.count, observed.allSatisfy({bounds.contains($0)}),
              let inventory = NPContractMemberReport([NSNumber(value:request.space)] as CFArray,request.hostPID) as? [String:Object],
              let scope = inventory[String(request.space)], scope["unresolved"] as? Int == 0,
              let members = scope["ordinary"] as? [[String:NSNumber]], members.count <= 128 else {return nil}
        let signedSystem = Set([OverviewAgent.dock,.manager].compactMap { (try? OverviewProcess.current($0))?.pid })
        var own = Set<UInt32>()
        for row in members {
            guard let owner = row["pid"]?.int32Value, let n = row["number"]?.uint32Value else {return nil}
            if owner == pid && numbers.contains(n) { own.insert(n) }
            else if !signedSystem.contains(owner) { return nil }
        }
        guard own == Set(numbers) else {return nil}
        return ["boot":boot,"osBuild":os,"display":request.display,"space":request.space,"spaceUUID":spaceUUID,
                "bounds":box(bounds),"modePixels":[mode.pixelWidth,mode.pixelHeight],
                "refreshHz":mode.refreshRate > 0 ? mode.refreshRate as Any : NSNull(),
                "reduceMotion":NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,"stageManager":stage,
                "fixturePID":pid,"fixtureBirth":birth,"fixtureHash":fixtureHash,"session":session,
                "numbers":numbers,"frames":observed.map(box),"otherOrdinaryAppWindows":0,
                "hostPID":request.hostPID,"hostBirth":request.hostBirth as Any,
                "hostHash":request.hostHash]
    }
    var stats = [[String:Int]]()
    func scan() throws -> [Target]? {
        var matched = [[Target](),[Target]()], containers = 0, buttons = 0
        defer {stats.append(["displayContainers":containers,"buttons":buttons,"firstLinks":matched[0].count,"secondLinks":matched[1].count])}
        guard let dock = try OverviewProcess.current(.dock) else {return nil}
        for owner in try OverviewProcess.owners(dock:dock) {
            let root = AXUIElementCreateApplication(owner.pid)
            guard AXUIElementSetMessagingTimeout(root,0.16) == .success else {return nil}
            // The signed root can also own the user's Dock. Select only the two known
            // static Mission Control container identifiers before traversing children.
            func groups(_ parent: AXUIElement, _ identifier: String) -> [AXUIElement] {
                guard owner.owns(parent), let nodes = attr(parent,kAXChildrenAttribute) as? [AXUIElement],
                      nodes.count <= 256 else {return []}
                return nodes.filter { owner.owns($0) && attr($0,kAXRoleAttribute) as? String == kAXGroupRole &&
                    attr($0,kAXIdentifierAttribute) as? String == identifier }
            }
            var displays = Set(groups(root,"mc.display"))
            for group in groups(root,"mc") {
                displays.formUnion(groups(group,"mc.display"))
            }
            for parent in displays where owner.owns(parent) && attr(parent,kAXRoleAttribute) as? String == kAXGroupRole &&
                (attr(parent,"AXDisplayID") as? NSNumber)?.uint32Value == display && frame(parent) == bounds {
                containers += 1
                guard let nodes = attr(parent,kAXChildrenAttribute) as? [AXUIElement], nodes.count <= 128 else {return nil}
                for node in nodes where owner.owns(node) && attr(node,kAXRoleAttribute) as? String == kAXButtonRole {
                    buttons += 1
                    guard let links = attr(node,kAXLinkedUIElementsAttribute) as? [AnyObject], links.count == 1,
                          CFGetTypeID(links[0]) == AXUIElementGetTypeID(),
                          let slot = windows.firstIndex(where:{ CFEqual($0,links[0]) }),
                          attr(node,kAXEnabledAttribute) as? Bool == true, let rect = frame(node), bounds.contains(rect)
                    else {continue}
                    // A center hit must also resolve to that exact Apple-owned button, not
                    // to another overlapping card or a user application under the overlay.
                    var hit: AXUIElement?
                    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(rect.midX),Float(rect.midY),&hit) == .success,
                          let hit, owner.owns(hit), CFEqual(hit,node) else {continue}
                    matched[slot].append(Target(node:node,owner:owner,box:rect))
                }
            }
            try owner.verify()
        }
        guard matched.allSatisfy({ $0.count == 1 }), matched[0][0].owner == matched[1][0].owner,
              !matched[0][0].box.intersects(matched[1][0].box) else {return nil}
        return matched.map { $0[0] }
    }
    guard scope(), let initial = environment() else {return stop("enrolledSpaceWindowsOrEnvironmentChanged")}
    let began = ProcessInfo.processInfo.systemUptime
    if request.mode == "focus-reference-environment" {
        guard scope(), let final = environment(), NSDictionary(dictionary:initial).isEqual(to:final) else {return stop("environmentChanged")}
        out["environment"] = final; out["interval"] = [began,ProcessInfo.processInfo.systemUptime]; out["status"] = "ENVIRONMENT_OBSERVED"
        return out
    }
    do {
        let first = try scan()
        let second = try scan()
        out["observations"] = stats
        guard scope(), let final = environment(), NSDictionary(dictionary:initial).isEqual(to:final) else {return stop("scopeChangedDuringNativeRead")}
        guard let a = first, let b = second,
              zip(a,b).allSatisfy({$0.owner == $1.owner && CFEqual($0.node,$1.node) && $0.box == $1.box})
        else {return stop("twoStableSystemLinksAndHitTestsUnavailable")}
        out["owner"] = ["bundle":b[0].owner.identifier,"pid":b[0].owner.pid,"birth":b[0].owner.birth,
                        "cdHash":runningCodeHash(b[0].owner.pid) as Any? ?? NSNull()]
        out["session"] = session; out["fixturePID"] = pid; out["fixtureBirth"] = birth; out["fixtureHash"] = fixtureHash
        out["targets"] = zip(numbers,b).map { n,t in ["number":n,"rect":[t.box.minX,t.box.minY,t.box.width,t.box.height]] as Object }
        out["display"] = request.display; out["space"] = request.space; out["spaceUUID"] = request.spaceUUID
        out["environment"] = final
        out["interval"] = [began,ProcessInfo.processInfo.systemUptime]
        out["status"] = "LINKS_OBSERVED"
        return out
    } catch {out["observations"] = stats; return stop("signedOverviewOwnerCouldNotBeConfirmed")}
}
