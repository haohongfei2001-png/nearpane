// System-side fixture preparation and S03 reference. Product actions live in separate drivers.
import AppKit
import ApplicationServices

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
func guardState(_ r: WorkspaceRequest) throws {
    let (current, records) = try live(r)
    guard let session = CGSessionCopyCurrentDictionary() as? [String:Any], session[kCGSessionOnConsoleKey as String] as? Bool == true,
          session[kCGSessionUserIDKey as String] as? NSNumber == NSNumber(value:getuid()),
          session["CGSSessionScreenIsLocked"] as? Bool != true, AXIsProcessTrusted(),
          hardware() == r.hid, NSEvent.pressedMouseButtons == 0, current == r.current, records == r.records,
          Set([r.original] + r.owned).count == r.owned.count + 1, !r.owned.contains(r.original),
          let host = NSRunningApplication(processIdentifier:r.hostPID), !host.isTerminated,
          host.bundleURL?.standardizedFileURL.path == "/Applications/Nearpane.app",
          host.bundleIdentifier == "com.holdsnow.nearpane.alpha"
    else { throw Refusal("physical input, session, Host, current desktop or original inventory changed") }
}
func overviewVisible() throws -> Bool {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock")
    guard running.count == 1, let dock = running.first, overviewHost(dock.processIdentifier) == "com.apple.dock" else {throw Refusal("system Dock unavailable")}
    let root = AXUIElementCreateApplication(dock.processIdentifier)
    _ = AXUIElementSetMessagingTimeout(root,0.5)
    return try !children(root,named:"mc").isEmpty
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
        guard let bar = try secondarySpacesBar(uuid,currentDisplay:true) else { throw Refusal("system overview is not exposed") }
        let list = try only(children(bar.spaces,named:"mc.spaces.list"),"desktop list")
        guard let items = attr(list,kAXChildrenAttribute) as? [AXUIElement], items.count == r.records.count,
              let bounds = frame(list), CGDisplayBounds(bar.side).contains(bounds),
              Set(items).count == items.count, items.allSatisfy({
                  belongs($0,to:list,owner:bar.owner.processIdentifier) && attr($0,kAXRoleAttribute) as? String == kAXButtonRole
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
        let el = elements[index], pid = bar.owner.processIdentifier
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
func sendMouse(_ event: CGEventType, _ p: CGPoint) throws {
    guard let e = CGEvent(mouseEventSource: nil, mouseType:event, mouseCursorPosition:p, mouseButton:.left) else { throw Refusal("cannot emit system drag") }
    e.post(tap:.cgSessionEventTap)
}
func mouseReorder(_ tiles: Tiles, from: Int, to: Int, _ r: WorkspaceRequest) throws {
    try demand(CGPreflightPostEventAccess() && abs(from-to)==1,"only two neighbouring owned desktop tiles may reorder")
    let start = try tiles.point(from,fraction:0.5), end = try tiles.point(to,fraction:from<to ? 0.84 : 0.16)
    let pointer = CGEvent(source:nil)?.location
    try guardState(r)
    try demand(hit(start,tiles.elements[from],tiles.bar.owner.processIdentifier) && hit(end,tiles.elements[to],tiles.bar.owner.processIdentifier),"desktop hit changed")
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
func empty(_ n: UInt64, host: pid_t) -> Bool {
    let report = NPContractMemberReport([NSNumber(value:n)] as CFArray, host) as? [String:[String:Any]]
    guard let row=report?[String(n)], row["unresolved"] as? Int == 0, row["otherMembers"] as? Int == 0,
          let members=row["ordinary"] as? [[String:Any]] else {return false}
    return members.isEmpty
}
func perform(_ r: WorkspaceRequest, issued: inout Bool) throws {
    try guardState(r)
    guard let uuid=UUID(uuidString:r.display), !r.records.isEmpty, r.records.contains(where: { $0.id == r.original && [0, 4].contains($0.type)}) else {throw Refusal("original active Space disappeared")}
    if r.command=="remove" {
        guard let target=r.target, r.owned.contains(target), target != r.current, empty(target,host:r.hostPID) else {throw Refusal("only a positively empty, inactive created desktop may be removed")}
    }
    let prior = try overviewVisible()
    try demand(!prior, "Mission Control was already open")
    try runOverviewLauncher()
    defer {
        if hardware()==r.hid, (try? overviewVisible()) == true {
            try? runOverviewLauncher()
        }
    }
    var tiles: Tiles?
    let deadline = ProcessInfo.processInfo.systemUptime + 3.5
    var detail = "system overview unavailable"
    repeat {
        do { tiles=try Tiles(r,uuid);break } catch let e as Refusal {detail=e.reason}
        usleep(80_000)
    } while ProcessInfo.processInfo.systemUptime < deadline
    guard let tiles else {throw Refusal(detail)}
    try guardState(r)
    let second=try Tiles(r,uuid)
    try demand(second.bar.owner.processIdentifier==tiles.bar.owner.processIdentifier &&
               CFEqual(second.bar.add,tiles.bar.add) && zip(second.elements,tiles.elements).allSatisfy { CFEqual($0,$1) },"system desktop controls changed")
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
    try guardState(r)
    if r.command=="remove" {try demand(empty(r.target!,host:r.hostPID),"window membership changed before removal")}
    issued=true
    let err=AXUIElementPerformAction(el,action as CFString)
    try demand(err == .success,"system control did not acknowledge input: \(err.rawValue)")
    // A tile selection closes overview on its own. Wait before testing whether our launcher must dismiss it.
    usleep(r.command=="select" ? 500_000 : 250_000)
}
@main enum Main {
    static func main() {
        if CommandLine.arguments.dropFirst().elementsEqual(["hid"]) {
            print(hardware().map(String.init).joined(separator:","))
            return
        }
        var issued=false
        do {
            let request=try JSONDecoder().decode(WorkspaceRequest.self,from:FileHandle.standardInput.readDataToEndOfFile())
            try perform(request,issued:&issued)
            print("{\"acknowledged\":true,\"issued\":true}")
        } catch {
            let detail=(error as? Refusal)?.reason ?? String(describing:error)
            let data=try! JSONSerialization.data(withJSONObject:["acknowledged":false,"issued":issued,"reason":detail])
            FileHandle.standardOutput.write(data+Data([10]));exit(2)
        }
    }
}
