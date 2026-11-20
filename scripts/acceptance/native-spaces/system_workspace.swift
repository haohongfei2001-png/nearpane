// System-side fixture preparation and S03 reference. Product actions live in separate drivers.
import AppKit
import ApplicationServices
import Security

struct Record: Codable, Equatable {
    let id: UInt64
    let type: Int
    let uuid: String
}
struct WorkspaceRequest: Decodable {
    let command, display: String
    let current, original: UInt64
    let records: [Record]
    let owned: [UInt64]
    let target, other: UInt64?
    let hostPID: pid_t
    let hostHash: String
    let hostBirth: UInt64
    let hid: [UInt32]
}
func demand(_ predicate: Bool, _ reason: String) throws {
    if !predicate { throw Refusal(reason) }
}
func hardware() -> [UInt32] {
    [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel].map {
        CGEventSource.counterForEventType(.hidSystemState, eventType: $0)
    }
}
func live(_ r: WorkspaceRequest) throws -> (UInt64, [Record]) {
    guard NPReadOnlySpacesOpen() == 1, let inventory = NPReadInventory() as? [[String:Any]], inventory.count == 1,
          let s = inventory.first, s["Display Identifier"] as? String == r.display,
          let current = (s["Current Space"] as? [String:Any])?["id64"] as? UInt64,
          let rows = s["Spaces"] as? [[String:Any]] else { throw Refusal("real single-display inventory unavailable") }
    let records = try rows.map { row -> Record in
        guard let n = row["id64"] as? UInt64, let t = row["type"] as? Int,
              let raw = row["uuid"] as? String, let uuid = UUID(uuidString: raw)
        else { throw Refusal("incomplete Space identity") }
        return Record(id:n,type:t,uuid:uuid.uuidString)
    }
    return (current,records)
}
func operatorBirth(_ pid:pid_t)->UInt64? { OverviewProcess.kernelBirth(pid) }
func operatorIdentity(_ pid: pid_t) -> (String,String)? {
    var code:SecCode?, selected:SecStaticCode?, info:CFDictionary?
    guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid:NSNumber(value:pid)] as CFDictionary,[],&code)==errSecSuccess,
          let code,SecCodeCopyStaticCode(code,[],&selected)==errSecSuccess, let selected,
          SecCodeCopySigningInformation(selected,SecCSFlags(rawValue:kSecCSSigningInformation),&info)==errSecSuccess,
          let fields=info as? [String:Any],let bytes=fields[kSecCodeInfoUnique as String] as? Data,
          let identifier=fields[kSecCodeInfoIdentifier as String] as? String else {return nil}
    return (identifier,bytes.map {String(format:"%02x",$0)}.joined())
}
@discardableResult
func guardState(_ r: WorkspaceRequest, stage: String = "initial", expected: UInt64? = nil,
                admitFullscreenOverview: Bool = false) throws -> UInt64 {
    let (current, records) = try live(r)
    let expect = expected ?? r.current
    func fail(_ reason: String) -> Refusal { Refusal("\(stage): \(reason) (current=\(current), expected=\(expect))") }
    guard let session = CGSessionCopyCurrentDictionary() as? [String:Any] else { throw fail("console session unavailable") }
    guard session[kCGSessionOnConsoleKey as String] as? Bool == true else {throw fail("session is off console")}
    guard session[kCGSessionUserIDKey as String] as? NSNumber == NSNumber(value:getuid()) else {throw fail("console user changed")}
    guard session["CGSSessionScreenIsLocked"] as? Bool != true else {throw fail("screen locked")}
    guard AXIsProcessTrusted() else {throw fail("AX trust lost")}
    let types=["leftDown","rightDown","otherDown","keyDown","scroll"]
    let counts=hardware()
    guard counts==r.hid else {
        let delta=types.indices.compactMap { i -> String? in
            guard i<counts.count && i<r.hid.count else {return types[i]+"=unavailable"}
            return counts[i] == r.hid[i] ? nil : "\(types[i])=\(counts[i] &- r.hid[i])"
        }
        throw fail("HID changed "+delta.joined(separator:","))
    }
    guard NSEvent.pressedMouseButtons == 0 else {throw fail("mouse buttons down: \(NSEvent.pressedMouseButtons)")}
    guard records == r.records else {throw fail("id/type/UUID order changed from \(r.records.map(\.id)) to \(records.map(\.id))")}
    guard Set([r.original]+r.owned).count==r.owned.count+1 else {throw fail("origin and leased identities collide")}
    guard operatorBirth(r.hostPID)==r.hostBirth else {throw fail("Host PID/uid/kernel birth changed: \(r.hostPID)")}
    var bytes=[CChar](repeating:0,count:4096)
    guard proc_pidpath(r.hostPID,&bytes,UInt32(bytes.count))>0 else {throw fail("Host process path unavailable: \(r.hostPID)")}
    guard String(cString:bytes)=="/Applications/Nearpane.app/Contents/MacOS/NearpaneHost" else {
        throw fail("Host process moved outside the signed installation: \(r.hostPID)")
    }
    guard let signature=operatorIdentity(r.hostPID) else {throw fail("active Host signature unavailable: \(r.hostPID)")}
    guard signature.0=="com.holdsnow.nearpane.alpha",signature.1==r.hostHash else {throw fail("active Host signature differs from handshake")}
    if current != expect {
        // Opening the system overview at a fullscreen origin can display an existing
        // ordinary Space. Bind that observed transition only for inactive-desktop recovery.
        guard admitFullscreenOverview, (r.command=="add" || r.command=="remove" || (r.command=="select" && r.target.map(r.owned.contains)==true)), try overviewVisible(),
              r.records.contains(where:{$0.id==expect && $0.type==4}),
              r.records.contains(where:{$0.id==current && $0.type==0}),
              !r.owned.contains(current), current != r.target else {throw fail("current Space changed")}
    }
    return current
}
func overviewGroup() throws -> AXUIElement? {
    let dock=try SystemDock.identity()
    let root = AXUIElementCreateApplication(dock.pid)
    try demand(dock.owns(root),"Dock AX root has a different owner")
    _ = AXUIElementSetMessagingTimeout(root,0.5)
    let groups=try children(root,named:"mc")
    guard groups.count<=1 else {throw Refusal("multiple system overview roots")}
    if let group=groups.first {try dock.verify();try demand(dock.owns(group),"Dock overview root owner changed")}
    return groups.first
}
func overviewVisible() throws -> Bool {try overviewGroup() != nil}

func awaitDismissal(of owned: AXUIElement?, request: WorkspaceRequest, timeout: Double) throws -> Bool {
    let stop=ProcessInfo.processInfo.systemUptime+timeout
    var absent=0
    repeat {
        guard hardware()==request.hid else {throw Refusal("user input changed during overview dismissal")}
        let group:AXUIElement?
        do {group=try overviewGroup()}
        catch let e as Refusal where e.reason=="Dock control children unavailable or unbounded" {
            // The AX reply may temporarily vanish when the strip rebuilds. This is never an absence reading.
            absent=0;usleep(80_000);continue
        }
        if let actual=group {
            if let owned, !CFEqual(actual,owned) {throw Refusal("a new overview owner replaced the enrolled root")}
            absent=0
        } else {
            absent+=1
            if absent>=2 {return true}
        }
        usleep(80_000)
    } while ProcessInfo.processInfo.systemUptime<stop
    return false
}
func finishOverview(_ owned: AXUIElement, request: WorkspaceRequest, proof: inout [String:Any]) {
    do {
        let dock=try SystemDock.identity()
        proof["overviewDock"]=["pid":dock.pid,"birth":dock.birth,"executable":SystemDock.executable,"appleSignature":true]
        if try awaitDismissal(of:owned,request:request,timeout:request.command=="select" ? 0.8 : 0.28) {
            proof["overviewDismissed"]=true;return
        }
        var reacquired:AXUIElement?, absent=0
        let end=ProcessInfo.processInfo.systemUptime+1.5
        repeat {
            try demand(hardware()==request.hid,"new input before owned overview closure")
            do {
                if let group=try overviewGroup() {
                    try demand(CFEqual(owned,group),"a different Mission Control root appeared before closure")
                    reacquired=group;break
                }
                absent+=1
                if absent>=2 {proof["overviewDismissed"]=true;return}
            } catch let e as Refusal where e.reason=="Dock control children unavailable or unbounded" {absent=0}
            usleep(80_000)
        } while ProcessInfo.processInfo.systemUptime<end
        guard let actual=reacquired,CFEqual(owned,actual),hardware()==request.hid else {throw Refusal("same signed Dock root could not be reread before dismissal")}
        var names:CFArray?
        var usedCancel=false
        if AXUIElementCopyActionNames(owned,&names) == .success, (names as? [String])?.contains(kAXCancelAction)==true {
            let result=AXUIElementPerformAction(owned,kAXCancelAction as CFString)
            usedCancel=true
            proof["overviewCloseAction"]="AXCancel"
            proof["overviewCloseAXResult"]=result.rawValue
        } else {
            // One toggle, only after resolving the same open system-owned root.
            try runOverviewLauncher()
            proof["overviewCloseAction"]="native launcher"
        }
        var dismissed=try awaitDismissal(of:owned,request:request,timeout:3.0)
        if !dismissed && usedCancel {
            // A system-wide toggle could open a closed overview. Use it only after
            // two fresh positive readings of the very same owned root and Dock.
            for _ in 0..<2 {
                guard let held=try overviewGroup() else {
                    try demand(try awaitDismissal(of:owned,request:request,timeout:0.35),"overview changed after AXCancel")
                    proof["overviewDismissed"]=true; return
                }
                guard CFEqual(owned,held),try SystemDock.identity().birth==dock.birth,
                      hardware()==request.hid else {throw Refusal("cannot corroborate the owned overview after AXCancel")}
                usleep(90_000)
            }
            guard let current=try overviewGroup(),CFEqual(current,owned),hardware()==request.hid else {throw Refusal("overview changed before native closure")}
            proof["stillOpenAfterAXCancel"]=true
            try runOverviewLauncher();dismissed=try awaitDismissal(of:owned,request:request,timeout:3.0)
            proof["verifiedFollowupCloseAction"]="native launcher"
        }
        proof["overviewDismissed"]=dismissed
    } catch {
        proof["overviewDismissed"]=false
        proof["overviewCloseReason"]=(error as? Refusal)?.reason ?? "overview dismissal unavailable"
    }
}

func runOverviewLauncher() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath:"/usr/bin/open")
    p.arguments = ["-g", "-a", "/System/Applications/Mission Control.app"]
    try p.run()
    p.waitUntilExit()
    try demand(p.terminationStatus == 0, "Mission Control launch failed")
}
func frame(_ e: AXUIElement) -> CGRect? {
    var origin = CGPoint.zero, size = CGSize.zero
    guard let a = attr(e,kAXPositionAttribute), let b = attr(e,kAXSizeAttribute),
          CFGetTypeID(a) == AXValueGetTypeID(), CFGetTypeID(b) == AXValueGetTypeID(),
          AXValueGetValue(a as! AXValue,.cgPoint,&origin), AXValueGetValue(b as! AXValue,.cgSize,&size),
          size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin:origin,size:size)
}
func belongs(_ element: AXUIElement, to parent: AXUIElement, owner: pid_t) -> Bool {
    var el = element
    for _ in 0..<10 {
        var pid: pid_t = 0
        guard AXUIElementGetPid(el,&pid) == .success, pid == owner else { return false }
        if CFEqual(el,parent) { return true }
        guard let next = attr(el,kAXParentAttribute), CFGetTypeID(next) == AXUIElementGetTypeID() else { return false }
        el = next as! AXUIElement
    }
    return false
}
func hit(_ point: CGPoint, _ tile: AXUIElement, _ pid: pid_t) -> Bool {
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(point.x),Float(point.y),&el) == .success,
          let el else { return false }
    return belongs(el,to:tile,owner:pid)
}
struct Tiles {
    let bar: SecondarySpacesBar
    let elements: [AXUIElement]
    let listFrame: CGRect
    init(_ r: WorkspaceRequest, _ uuid: UUID) throws {
        guard let bar = try secondarySpacesBar(uuid,currentDisplay:true,enrolledDock:SystemDock.identity()) else { throw Refusal("system overview is not exposed") }
        let list = try only(children(bar.spaces,named:"mc.spaces.list"),"desktop list")
        try bar.verify(list)
        guard let items = attr(list,kAXChildrenAttribute) as? [AXUIElement], items.count == r.records.count,
              let bounds = frame(list), CGDisplayBounds(bar.side).contains(bounds),
              Set(items).count == items.count, items.allSatisfy({
                  belongs($0,to:list,owner:bar.owner.pid) && attr($0,kAXRoleAttribute) as? String == kAXButtonRole
              })
        else { throw Refusal("system desktop controls do not corroborate the complete Space inventory") }
        // If tiles have geometry, their horizontal order must agree with the AX list.
        let frames = items.compactMap(frame).filter { bounds.contains($0) }
        if frames.count == items.count && Set(frames.map(\.midX)).count == items.count {
            try demand(zip(frames,frames.dropFirst()).allSatisfy { $0.midX < $1.midX }, "system tile order is ambiguous")
        }
        self.bar = bar; elements = items; listFrame = bounds
    }
    func point(_ index: Int, fraction: CGFloat) throws -> CGPoint {
        let el = elements[index], pid = bar.owner.pid
        if let f = frame(el), listFrame.contains(f) {
            for y in [0.5,0.7,0.3] {
                let p = CGPoint(x:f.minX+f.width*fraction,y:f.minY+f.height*y)
                if hit(p,el,pid) { return p }
            }
        }
        // Some system builds expose zero tile frames. Probe only inside the actual system strip,
        // then use a point whose hit returned this exact tile, never an estimated ordinal.
        let y = listFrame.midY
        var points = [CGPoint]()
        for x in stride(from:listFrame.minX+2,through:listFrame.maxX-2,by:6) {
            let p = CGPoint(x:x,y:y)
            if hit(p,el,pid) { points.append(p) }
        }
        guard !points.isEmpty else { throw Refusal("no independently hit-tested system desktop tile point") }
        return points[Int(CGFloat(points.count-1)*fraction)]
    }
}
func tileBodyRole(_ p: CGPoint, tile: AXUIElement, owner: pid_t) -> String? {
    var candidate: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(p.x),Float(p.y),&candidate) == .success,
          let candidate, belongs(candidate,to:tile,owner:owner),let role=attr(candidate,kAXRoleAttribute) as? String else {return nil}
    if CFEqual(candidate,tile),role==kAXButtonRole {return "desktop button"}
    if role==kAXImageRole, let parent=attr(candidate,kAXParentAttribute),CFEqual(parent,tile) {return "desktop image"}
    return nil
}

func expandedBody(_ tiles: Tiles, index: Int) throws -> (CGPoint,String,CGRect) {
    let tile=tiles.elements[index], owner=tiles.bar.owner.pid
    guard tiles.listFrame.height>=48 else {throw Refusal("signed Space strip still exposes compact titles")}
    if let f=frame(tile),tiles.listFrame.contains(f),f.width>=44,f.height>=40 {
        // The central/lower interior excludes the close button and the caption.
        for yf: CGFloat in [0.53,0.61,0.45] {
            for xf: CGFloat in [0.5,0.42,0.58] {
                let p=CGPoint(x:f.minX+f.width*xf,y:f.minY+f.height*yf)
                if let role=tileBodyRole(p,tile:tile,owner:owner) {return (p,role,f)}
            }
        }
    }
    // A zero-sized tile needs two separated vertical hits on this same non-text
    // button/image inside the expanded strip before it can receive a real click.
    let p=try tiles.point(index,fraction:0.5)
    let x=p.x
    for yf: CGFloat in [0.50,0.58,0.43] {
        let middle=CGPoint(x:x,y:tiles.listFrame.minY+tiles.listFrame.height*yf)
        let other=CGPoint(x:x,y:middle.y+12)
        if let role=tileBodyRole(middle,tile:tile,owner:owner),tiles.listFrame.contains(other),
           tileBodyRole(other,tile:tile,owner:owner) != nil {return (middle,role,tiles.listFrame)}
    }
    throw Refusal("signed overview exposes no independently hit-tested thumbnail body")
}
func sendMouse(_ event: CGEventType, _ p: CGPoint) throws {
    guard let e = CGEvent(mouseEventSource: nil, mouseType:event, mouseCursorPosition:p, mouseButton:.left) else { throw Refusal("cannot emit system drag") }
    e.post(tap:.cgSessionEventTap)
}
func mouseReorder(_ tiles: Tiles, from: Int, to: Int, _ r: WorkspaceRequest) throws {
    try demand(CGPreflightPostEventAccess() && abs(from-to)==1,"only two neighbouring owned desktop tiles may reorder")
    let start = try tiles.point(from,fraction:0.5), end = try tiles.point(to,fraction:from<to ? 0.84 : 0.16)
    let pointer = CGEvent(source:nil)?.location
    try guardState(r)
    try tiles.bar.verify(tiles.elements[from]);try demand(tiles.bar.owner.owns(tiles.elements[to]),"destination AX owner changed")
    try demand(hit(start,tiles.elements[from],tiles.bar.owner.pid) && hit(end,tiles.elements[to],tiles.bar.owner.pid),"desktop hit changed")
    var last = start
    try sendMouse(.leftMouseDown,start)
    defer {
        try? sendMouse(.leftMouseUp,last)
        if let pointer, hardware()==r.hid { CGWarpMouseCursorPosition(pointer) }
    }
    usleep(240_000)
    for n in 1...26 {
        let p = CGPoint(x:start.x+(end.x-start.x)*CGFloat(n)/26, y:start.y+(end.y-start.y)*CGFloat(n)/26)
        try demand(tiles.listFrame.contains(p) && hardware()==r.hid,"user input or drag left the system strip")
        try sendMouse(.leftMouseDragged,p); last=p
        usleep(18_000)
    }
    usleep(250_000)
}
func publicWindowNumbers() throws -> Set<UInt32> {
    guard let numbers=NPContractPublicWindowNumbers() as? [UInt32], (1...8192).contains(numbers.count) else {
        throw Refusal("public WindowServer number inventory unavailable")
    }
    return Set(numbers)
}
func requireEmpty(_ n: UInt64, host: pid_t, beforeOverview: Set<UInt32>? = nil) throws -> [String:Any]? {
    let report = NPContractMemberReport([NSNumber(value:n)] as CFArray, host) as? [String:Any]
    if let row=report?[String(n)] as? [String:Any], row["unresolved"] as? Int == 0,
       row["otherMembers"] as? Int == 0, let members=row["ordinary"] as? [[String:Any]] {
        if members.isEmpty {return nil}
        // The authenticated system overview creates a normal-layer compositing window.
        // The target had zero ordinary windows immediately before this invocation opened
        // Mission Control. Only a single newly allocated, Apple-signed system surface qualifies.
        if let beforeOverview, members.count==1, let member=members.first,
           let pid=member["pid"] as? Int32, let number=member["number"] as? UInt32,
           !beforeOverview.contains(number), try overviewVisible(), overviewHost(pid)=="com.apple.WindowManager" {
            return ["pid":pid,"number":number,"owner":"com.apple.WindowManager","newSinceOverview":true,"otherOrdinary":0]
        }
    }
    let data = try JSONSerialization.data(withJSONObject:report ?? [:],options:.sortedKeys)
    throw Refusal("WindowServer could not establish an empty desktop: "+String(decoding:data,as:UTF8.self))
}
// Keep the activated system control alive while its asynchronous action settles.
// A successful AX return alone is retained separately from this WindowServer witness.
func witnessSystemAction(_ r: WorkspaceRequest) -> Bool {
    let deadline=ProcessInfo.processInfo.systemUptime+3.5
    var stable=0
    let originalIDs=Set(r.records.map(\.id))
    repeat {
        guard hardware()==r.hid, let (current,records)=try? live(r) else {return false}
        let matches:Bool
        switch r.command {
        case "add":
            let added=records.filter {!originalIDs.contains($0.id)}
            matches=added.count==1 && added[0].type==0 && records.filter {originalIDs.contains($0.id)}==r.records
        case "select":matches=current==r.target && records==r.records
        case "remove":matches=current != r.target && records==r.records.filter {$0.id != r.target}
        default:return false
        }
        stable=matches ? stable+1 : 0
        if stable>=2 {return true}
        usleep(80_000)
    } while ProcessInfo.processInfo.systemUptime<deadline
    return false
}
func perform(_ r: WorkspaceRequest, issued: inout Bool, proof: inout [String:Any]) throws {
    try guardState(r)
    guard let uuid=UUID(uuidString:r.display), !r.records.isEmpty, r.records.contains(where: {$0.id == r.original && [0, 4].contains($0.type)}) else {throw Refusal("original active Space disappeared")}
    var beforeOverview: Set<UInt32>?
    if r.command=="remove" {
        guard let target=r.target, r.owned.contains(target), target != r.current else {throw Refusal("only an inactive created desktop may be removed")}
        _=try requireEmpty(target,host:r.hostPID)
        beforeOverview=try publicWindowNumbers()
    }
    if try overviewVisible() {
        // A prior operation's close animation may still expose its accessibility root.
        guard try awaitDismissal(of:nil,request:r,timeout:1.5) else {throw Refusal("Mission Control was already open")}
    }
    try guardState(r,stage:"before-opening-overview")
    try runOverviewLauncher()
    var ownedOverview: AXUIElement?
    var pointerBeforeHover: CGPoint?, hovered: CGPoint?
    defer {
        if let ownedOverview {finishOverview(ownedOverview,request:r,proof:&proof)}
        if let p=pointerBeforeHover,let h=hovered,let current=CGEvent(source:nil)?.location,
           hypot(current.x-h.x,current.y-h.y)<5,hardware()==r.hid {CGWarpMouseCursorPosition(p)}
    }
    var tiles: Tiles?
    let deadline = ProcessInfo.processInfo.systemUptime + 3.5
    var detail = "system overview unavailable"
    repeat {
        do {
            if ownedOverview==nil {ownedOverview=try overviewGroup()}
            tiles=try Tiles(r,uuid);break
        } catch let e as Refusal {detail=e.reason}
        usleep(80_000)
    } while ProcessInfo.processInfo.systemUptime < deadline
    guard let tiles else {throw Refusal(detail)}
    var overviewCurrent=try guardState(r,stage:"overview-admission",admitFullscreenOverview:true)
    if overviewCurrent != r.current { proof["overviewChangedCurrent"]=["from":r.current,"to":overviewCurrent] }
    let second=try Tiles(r,uuid)
    try demand(second.bar.dock==tiles.bar.dock && second.bar.owner==tiles.bar.owner &&
               CFEqual(second.bar.add,tiles.bar.add) && zip(second.elements,tiles.elements).allSatisfy { CFEqual($0,$1) },"system desktop controls changed")
    proof["overviewControlsIdentity"]=["dockPID":second.bar.dock.pid,"dockBirth":second.bar.dock.birth,
        "ownerPID":second.bar.owner.pid,"ownerBirth":second.bar.owner.birth,"ownerID":second.bar.owner.identifier]
    let action: String, el: AXUIElement
    switch r.command {
    case "add": el=tiles.bar.add;action=kAXPressAction
    case "select","remove","swap":
        guard let target=r.target, let index=r.records.firstIndex(where: {$0.id == target && ($0.type == 0 || (r.command == "select" && target == r.original && $0.type == 4))}),
              r.owned.contains(target) || (r.command=="select" && target==r.original)
        else {throw Refusal("target is outside the owner-bound desktop set")}
        if r.command=="swap" {
            guard let peer=r.other, r.owned.contains(peer),r.owned.contains(target),
                  let next=r.records.firstIndex(where:{$0.id==peer && $0.type==0}) else {throw Refusal("unleased reorder")}
            issued=true
            try mouseReorder(tiles,from:index,to:next,r)
            return
        }
        el=tiles.elements[index]
        action=r.command=="remove" ? "AXRemoveDesktop" : kAXPressAction
    default: throw Refusal("unrecognized system fixture operation")
    }
    var choices: CFArray?
    guard AXUIElementCopyActionNames(el,&choices) == .success, (choices as? [String])?.contains(action)==true,
          attr(el,kAXEnabledAttribute) as? Bool == true else {throw Refusal("system desktop action unavailable")}
    overviewCurrent=try guardState(r,stage:"before-system-action",expected:overviewCurrent,
                                   admitFullscreenOverview:overviewCurrent==r.current)
    if overviewCurrent != r.current {proof["overviewChangedCurrent"]=["from":r.current,"to":overviewCurrent]}
    if r.command=="select", let target=r.target, let index=r.records.firstIndex(where:{$0.id==target}) {
        // AXPress on a Mission Control tile can acknowledge without leaving the
        // overview. Use one mouse click whose exact signed accessibility hit still
        // names the enrolled tile. Target selection is independently read afterwards.
        guard CGPreflightPostEventAccess() else {throw Refusal("event access unavailable for system tile selection")}
        let provisional=try second.point(index,fraction:0.5)
        let before=CGEvent(source:nil)?.location
        guard hit(provisional,second.elements[index],second.bar.owner.pid),let before else {throw Refusal("signed tile hover is unavailable")}
        pointerBeforeHover=before;hovered=provisional
        proof["compactOrExpandedStripHeightBeforeHover"]=second.listFrame.height
        CGWarpMouseCursorPosition(provisional)
        try sendMouse(.mouseMoved,provisional)
        var body:(CGPoint,String,CGRect)?, detail="expanded Space thumbnail did not settle"
        var settledBody=false
        let hoverDeadline=ProcessInfo.processInfo.systemUptime+2.2
        repeat {
            usleep(100_000)
            do {
                let updated=try Tiles(r,uuid)
                guard CFEqual(second.elements[index],updated.elements[index]) && updated.bar.dock==second.bar.dock,updated.bar.owner==second.bar.owner else {
                    throw Refusal("enrolled system tile changed while expanding thumbnails")
                }
                let candidate=try expandedBody(updated,index:index)
                if let previous=body,previous.0==candidate.0,previous.2==candidate.2 {body=candidate;settledBody=true;break}
                body=candidate
            } catch let err as Refusal {body=nil;detail=err.reason}
        } while ProcessInfo.processInfo.systemUptime<hoverDeadline
        guard settledBody,let (point,role,thumb)=body else {throw Refusal(detail)}
        overviewCurrent=try guardState(r,stage:"before-system-tile-click",expected:overviewCurrent,
                                       admitFullscreenOverview:overviewCurrent==r.current)
        try second.bar.verify(second.elements[index])
        guard tileBodyRole(point,tile:second.elements[index],owner:second.bar.owner.pid)==role else {throw Refusal("system tile body changed")}
        proof["tileHit"]=["index":index,"role":role,"point":[point.x,point.y],
                          "bodyOrStrip":[thumb.minX,thumb.minY,thumb.width,thumb.height]]
        hovered=point
        issued=true
        guard let down=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left),
              let up=CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left) else {
            issued=false;throw Refusal("system tile click events unavailable")
        }
        down.setIntegerValueField(.mouseEventClickState,value:1)
        up.setIntegerValueField(.mouseEventClickState,value:1)
        down.post(tap:.cgSessionEventTap);usleep(70_000);up.post(tap:.cgSessionEventTap)
        usleep(60_000)
        proof["systemSelection"]="hit-tested desktop tile click"
        proof["windowServerConfirmedBeforeClose"]=witnessSystemAction(r)
        return
    }
    if r.command=="remove", let target=r.target, let beforeOverview {
        if let surface = try requireEmpty(target,host:r.hostPID,beforeOverview:beforeOverview) {
            proof["overviewComposite"] = surface
        }
        try guardState(r,stage:"after-empty-read",expected:overviewCurrent,admitFullscreenOverview:overviewCurrent==r.current)
    }
    try second.bar.verify(el)
    issued=true
    let err=AXUIElementPerformAction(el,action as CFString)
    try demand(err == .success,"system control did not acknowledge input: \(err.rawValue)")
    proof["windowServerConfirmedBeforeClose"]=witnessSystemAction(r)
}
@main enum Main {
    static func main() {
        if CommandLine.arguments.dropFirst().elementsEqual(["overview-state"]) {
            do {
                let dock=try SystemDock.identity(),a=try overviewGroup()
                usleep(120_000);let b=try overviewGroup()
                let stable=(a==nil && b==nil) || (a != nil && b != nil && CFEqual(a!,b!))
                let proof:[String:Any]=["pid":dock.pid,"birth":dock.birth,"stable":stable,"visible":b != nil,"events":0]
                print(String(decoding:try JSONSerialization.data(withJSONObject:proof,options:.sortedKeys),as:UTF8.self))
            } catch {fputs("\(error)\n",stderr);exit(2)}
            return
        }
        if CommandLine.arguments.dropFirst().elementsEqual(["dock-identity"]) {
            do {
                let dock=try SystemDock.identity()
                let proof:[String:Any]=["pid":dock.pid,"birth":dock.birth,"executable":SystemDock.executable,"appleSignature":true,"events":0]
                print(String(decoding:try JSONSerialization.data(withJSONObject:proof,options:.sortedKeys),as:UTF8.self))
            } catch {fputs("\(error)\n",stderr);exit(2)}
            return
        }
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="birth",let pid=Int32(CommandLine.arguments[2]) {
            guard let birth=operatorBirth(pid) else {exit(2)}
            print(birth);return
        }
        if CommandLine.arguments.dropFirst().elementsEqual(["overview"]) {
            guard let active=try? overviewVisible() else {exit(2)}
            print(active ? "open" : "closed");return
        }
        if CommandLine.arguments.dropFirst().elementsEqual(["hid"]) {
            print(hardware().map(String.init).joined(separator:","))
            return
        }
        var issued=false
        var proof=[String:Any]()
        do {
            let request=try JSONDecoder().decode(WorkspaceRequest.self,from:FileHandle.standardInput.readDataToEndOfFile())
            try perform(request,issued:&issued,proof:&proof)
            proof["acknowledged"]=true;proof["issued"]=true
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:proof)+Data([10]))
        } catch {
            let detail=(error as? Refusal)?.reason ?? String(describing:error)
            proof["acknowledged"]=false;proof["issued"]=issued;proof["reason"]=detail
            let data=try! JSONSerialization.data(withJSONObject:proof)
            FileHandle.standardOutput.write(data+Data([10]));exit(2)
        }
    }
}
