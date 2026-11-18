// Independent test driver. The only target of injected mouse events is an
// explicitly hit-tested control in the installed Nearpane sidebar.
import AppKit
import ApplicationServices
import Security

struct Window: Codable { let pid: Int32, birth: UInt64, number: UInt32 }
struct Request: Codable {
    let action: String
    let hostPID: Int32, hostHash: String
    let fixture: String, fixtureHash: String
    let target, sibling: Window
    let display, sourceUUID, destUUID: String
    let source, dest, current: UInt64
    let frontPID: Int32, focused: UInt32
    let expiresUptime: Double
}
struct Refusal: Error { let detail: String; init(_ detail: String) { self.detail = detail } }
func require(_ ok: Bool, _ why: String) throws { if !ok { throw Refusal(why) } }
func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}
func birth(_ pid: Int32) -> UInt64? {
    var t = proc_bsdinfo()
    let n = Int32(MemoryLayout.size(ofValue: t))
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &t, n) == n, t.pbi_start_tvsec > 0 else { return nil }
    return t.pbi_start_tvsec * 1_000_000 + t.pbi_start_tvusec
}
func directFixture(_ pid: Int32, path: String) -> Bool {
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    guard url.lastPathComponent == "Field Notes.app", url.deletingLastPathComponent().lastPathComponent.hasPrefix("nearpane-d01."),
          url.deletingLastPathComponent().deletingLastPathComponent().path == "/private/tmp" else { return false }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout.size(ofValue:info))
    return proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,size) == size && info.pbi_ppid == UInt32(getppid())
}
func code(_ pid: Int32) -> String? {
    var guest: SecCode?, pinned: SecStaticCode?, info: CFDictionary?
    guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String: pid] as CFDictionary, [], &guest) == errSecSuccess,
          let guest, SecCodeCheckValidity(guest, [], nil) == errSecSuccess,
          SecCodeCopyStaticCode(guest, [], &pinned) == errSecSuccess, let pinned,
          SecCodeCopySigningInformation(pinned, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
    return hash.map { String(format: "%02x", $0) }.joined()
}
func focus() -> (Int32, UInt32)? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
          let v = attr(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
          CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    let n = NPReadAXWindowNumber(v)
    return n == 0 ? nil : (pid, n)
}
func validate(_ r: Request) throws {
    let t = ProcessInfo.processInfo.systemUptime
    try require(r.expiresUptime > t && r.expiresUptime - t <= 900, "Expired enrolment")
    guard let state = CGSessionCopyCurrentDictionary() as? [String:Any],
          state[kCGSessionOnConsoleKey as String] as? Bool == true, state["CGSSessionScreenIsLocked"] as? Bool != true,
          state[kCGSessionUserIDKey as String] as? UInt32 == getuid(),
          NPReadOnlySpacesOpen() == 1, AXIsProcessTrusted(), CGPreflightPostEventAccess(),
          NSScreen.screens.count == 1, let screenNumber = NSScreen.screens[0].deviceDescription[.init("NSScreenNumber")] as? UInt32,
          let screenUUID = CGDisplayCreateUUIDFromDisplayID(screenNumber)?.takeRetainedValue(),
          CFUUIDCreateString(nil, screenUUID) as String == r.display,
          let scopes = NPReadInventory() as? [[String:Any]], scopes.count == 1,
          let row = scopes.first, row["Display Identifier"] as? String == r.display,
          (row["Current Space"] as? [String:Any])?["id64"] as? UInt64 == r.current,
          let records = row["Spaces"] as? [[String:Any]] else { throw Refusal("Display, current Space, session or permission changed") }
    func space(_ id: UInt64, _ uuid: String) -> Bool {
        let matches = records.filter { $0["id64"] as? UInt64 == id }
        return matches.count == 1 && matches[0]["type"] as? Int == 0 &&
            (matches[0]["uuid"] as? String)?.caseInsensitiveCompare(uuid) == .orderedSame
    }
    let allowed = Set([r.target.number, r.sibling.number])
    guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] else {
        throw Refusal("Missing current window census")
    }
    for item in list where item[kCGWindowLayer as String] as? Int == 0 && item[kCGWindowOwnerPID as String] as? Int32 != r.hostPID {
        guard let number = item[kCGWindowNumber as String] as? UInt32,
              let membership = NPReadWindowSpaces(number) as? [UInt64], !membership.isEmpty else {
            throw Refusal("Unattributed window prevents a controlled trial")
        }
        if membership.contains(r.source) || membership.contains(r.dest) {
            try require(allowed.contains(number) && item[kCGWindowOwnerPID as String] as? Int32 == r.target.pid,
                        "Unexpected window entered a test Space")
        }
    }
    try require(r.source != r.dest && space(r.source, r.sourceUUID) && space(r.dest, r.destUUID), "Enrolled Space identity changed")
    guard let owner = NSRunningApplication(processIdentifier: r.hostPID),
          owner.bundleIdentifier == "com.holdsnow.nearpane.alpha", owner.bundleURL?.standardizedFileURL.path == "/Applications/Nearpane.app",
          code(r.hostPID) == r.hostHash, r.target.pid == r.sibling.pid, r.target.birth == r.sibling.birth,
          r.target.number != r.sibling.number, birth(r.target.pid) == r.target.birth, directFixture(r.target.pid, path:r.fixture),
          let fixture = NSRunningApplication(processIdentifier: r.target.pid),
          fixture.bundleIdentifier == "net.example.spaces-document",
          fixture.bundleURL?.standardizedFileURL == URL(fileURLWithPath:r.fixture).standardizedFileURL,
          code(r.target.pid) == r.fixtureHash else { throw Refusal("Installed app or fixture generation changed") }
}
func windows(_ r: Request) throws -> [UInt32:AXUIElement] {
    guard let elements = attr(AXUIElementCreateApplication(r.target.pid), kAXWindowsAttribute) as? [AXUIElement],
          elements.count == 2 else { throw Refusal("Fixture requires exactly two owned test windows") }
    var ids = [UInt32:AXUIElement]()
    for e in elements {
        let id = NPReadAXWindowNumber(e)
        try require(id != 0 && ids[id] == nil && (id == r.sibling.number || id == r.target.number), "Fixture window identity changed")
        ids[id] = e
    }
    return ids
}
func members(_ w: Window) -> [UInt64]? {
    guard birth(w.pid) == w.birth,
          let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, w.number) as? [[String:Any]],
          rows.count == 1, rows[0][kCGWindowOwnerPID as String] as? Int32 == w.pid,
          rows[0][kCGWindowNumber as String] as? UInt32 == w.number, rows[0][kCGWindowLayer as String] as? Int == 0
    else { return nil }
    return (NPReadWindowSpaces(w.number) as? [UInt64])?.sorted()
}
func identifier(_ el: AXUIElement) -> String? { attr(el,kAXIdentifierAttribute) as? String }
func nodeFrame(_ el: AXUIElement) -> CGRect? {
    guard let p = attr(el,kAXPositionAttribute), let s = attr(el,kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue,.cgPoint,&point), AXValueGetValue(s as! AXValue,.cgSize,&size),
          size.width > 2, size.height > 2 else { return nil }
    return CGRect(origin:point,size:size)
}
func control(_ root: AXUIElement, id: String) throws -> AXUIElement {
    var queue = [root], seen = Set<AXUIElement>(), hits = [AXUIElement]()
    while let el = queue.popLast() {
        guard seen.insert(el).inserted else { continue }
        try require(seen.count <= 5000, "Sidebar AX tree exceeded the limit")
        if identifier(el) == id { hits.append(el); continue }
        let role = attr(el,kAXRoleAttribute) as? String ?? ""
        if !["AXTextArea","AXTextField","AXSecureTextField","AXStaticText","AXWebArea","AXImage"].contains(role) {
            queue += attr(el,kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
    }
    guard hits.count == 1, let el = hits.first, attr(el,kAXEnabledAttribute) as? Bool == true else { throw Refusal("An enabled, unique target sidebar control is required") }
    return el
}
func hit(_ pos: CGPoint, _ id: String, _ pid: Int32) -> Bool {
    var result: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(pos.x), Float(pos.y), &result) == .success else { return false }
    var el = result
    for _ in 0..<12 {
        guard let e = el else { return false }
        var owner: pid_t = 0
        guard AXUIElementGetPid(e,&owner) == .success, owner == pid else { return false }
        if identifier(e) == id { return true }
        if let value = attr(e,kAXParentAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() { el = (value as! AXUIElement) } else { return false }
    }
    return false
}
func point(_ el: AXUIElement,_ id: String,_ pid: Int32, title: Bool) throws -> CGPoint {
    guard let f = nodeFrame(el) else { throw Refusal("Sidebar control has no visible frame") }
    let candidates = title ? [CGPoint(x:f.minX+12,y:f.minY+8),CGPoint(x:f.midX,y:f.minY+7)] :
        [CGPoint(x:f.midX,y:f.midY),CGPoint(x:f.minX+f.width*0.25,y:f.minY+f.height*0.30)]
    guard let p = candidates.first(where:{ hit($0,id,pid) }) else { throw Refusal("Source or destination is occluded or outside its scroll viewport") }
    return p
}

var inputs = 0
func mouse(_ kind: CGEventType,_ point: CGPoint) throws {
    guard let e = CGEvent(mouseEventSource:nil,mouseType:kind,mouseCursorPosition:point,mouseButton:.left) else { throw Refusal("Mouse event unavailable") }
    e.post(tap:.cghidEventTap); inputs += 1
}
func run(_ r: Request) throws -> [String:Any] {
    try validate(r)
    let chosen = members(r.target), sibling = members(r.sibling)
    let f = focus()
    if r.action == "sample" {
        let elems = attr(AXUIElementCreateApplication(r.target.pid), kAXWindowsAttribute) as? [AXUIElement]
        return ["target":chosen as Any, "sibling":sibling as Any, "front":f?.0 as Any, "focused":f?.1 as Any,
                "fixtureAXNumbers":elems?.map { NPReadAXWindowNumber($0) }.sorted() as Any, "inputs":0]
    }
    try require(["drag","cancel","close-during-drag"].contains(r.action) && chosen == [r.source] &&
                sibling?.count == 1 && (sibling == [r.source] || sibling == [r.dest]),
                "Unexpected fixture Space membership")
    try require(f?.0 == r.frontPID && f?.1 == r.focused, "Original focus is no longer current")
    let bound = try windows(r)
    let src = "native-space-window:\(r.display):\(r.source):\(r.target.pid):\(r.target.number)"
    let dst = "native-space-row:\(r.display):\(r.dest)"
    let root = AXUIElementCreateApplication(r.hostPID)
    let a = try point(control(root,id:src),src,r.hostPID,title:false)
    let b = try point(control(root,id:dst),dst,r.hostPID,title:true)
    guard let origin = CGEvent(source:nil)?.location, let closed = bound[r.target.number] else { throw Refusal("Cannot preserve cursor or bind test window") }
    try require(hypot(a.x-b.x,a.y-b.y) >= 12, "No distinct drop target")
    let closeButton = r.action == "close-during-drag" ? attr(closed,kAXCloseButtonAttribute) : nil
    if r.action == "close-during-drag" {
        try require(closeButton.map{ CFGetTypeID($0) == AXUIElementGetTypeID() } == true, "Cannot close only the enrolled window")
    }
    try validate(r)
    try require(hit(a,src,r.hostPID) && hit(b,dst,r.hostPID), "Physical hit changed before mouse down")
    let board = NSPasteboard(name: .drag)
    let priorGeneration = board.changeCount
    try mouse(.leftMouseDown,a)
    var released = false, last = a
    defer {
        if !released {
            // Cancel only the product's in-progress drag, never a click into another app.
            if let e = CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:true) { e.postToPid(r.hostPID) }
            if let e = CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:false) { e.postToPid(r.hostPID) }
            if let e = CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:last,mouseButton:.left) { e.postToPid(r.hostPID) }
        }
        if CGEvent(source:nil).map({ hypot($0.location.x-last.x,$0.location.y-last.y) < 4 }) == true { CGWarpMouseCursorPosition(origin) }
    }
    func glide(_ from: CGPoint,_ to: CGPoint) throws {
        for i in 1...12 {
            let t = CGFloat(i)/12
            let p = CGPoint(x:from.x+(to.x-from.x)*t,y:from.y+(to.y-from.y)*t)
            // Input stays over the same installed process for the entire live drag.
            var e: AXUIElement?, pid: pid_t = 0
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(p.x),Float(p.y),&e) == .success,
                  let e, AXUIElementGetPid(e,&pid) == .success, pid == r.hostPID,
                  birth(r.target.pid) == r.target.birth, ProcessInfo.processInfo.systemUptime < r.expiresUptime
            else { throw Refusal("Drag left the installed sidebar or lost the fixture") }
            try mouse(.leftMouseDragged,p); last = p; usleep(17_000)
        }
    }
    try glide(a,b)
    let pressedUntil = ProcessInfo.processInfo.systemUptime + 0.6
    while board.changeCount == priorGeneration && ProcessInfo.processInfo.systemUptime < pressedUntil { usleep(16_000) }
    try require(board.changeCount != priorGeneration &&
                board.types?.contains(NSPasteboard.PasteboardType("com.holdsnow.nearpane.space-window")) == true,
                "Independent observer could not witness the product's local drag session")
    if r.action == "close-during-drag", let closeButton {
        try require(windows(r)[r.target.number].map { CFEqual($0,closed) } == true, "Window changed before test close")
        try require(AXUIElementPerformAction(closeButton as! AXUIElement,kAXPressAction as CFString) == .success, "Exact owned window did not close")
        let end = ProcessInfo.processInfo.systemUptime + 1.2
        while members(r.target) != nil && ProcessInfo.processInfo.systemUptime < end { usleep(20_000) }
        try require(members(r.target) == nil, "Closed source is still present")
    }
    if r.action == "cancel" {
        guard let down = CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:true),
              let up = CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:false) else { throw Refusal("Cannot cancel drag") }
        down.postToPid(r.hostPID); up.postToPid(r.hostPID); inputs += 2
        try glide(b,a)
    }
    let drop = r.action == "cancel" ? a : b
    try validate(r)
    try require(hit(drop,r.action == "cancel" ? src : dst,r.hostPID), "Final drop point no longer belongs to the chosen sidebar control")
    try mouse(.leftMouseUp,drop); last = drop; released = true
    return ["inputs":inputs, "issued":true, "productDragWitnessed":true, "sourceControl":src, "destinationControl":dst]
}
if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--fixture-birth" {
    let args = CommandLine.arguments
    guard let pid = Int32(args[2]), directFixture(pid, path:args[4]), let app = NSRunningApplication(processIdentifier: pid),
          app.bundleIdentifier == "net.example.spaces-document", app.bundleURL?.standardizedFileURL == URL(fileURLWithPath:args[4]).standardizedFileURL,
          code(pid) == args[3], let generation = birth(pid) else { exit(2) }
    print(generation)
    exit(0)
}
do {
    let r = try JSONDecoder().decode(Request.self,from:FileHandle.standardInput.readDataToEndOfFile())
    let result = try run(r)
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
} catch {
    let reason = (error as? Refusal)?.detail ?? "Invalid request"
    FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject:["issued":false,"inputs":inputs,"reason":reason]))
    exit(2)
}
