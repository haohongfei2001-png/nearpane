// Production input is one AXPress on an identified background document in the signed Host.
// The independent watch mode reads only physical display, Space and process metadata.
import AppKit
import ApplicationServices
import Security

typealias Map = [String: Any]
struct Refusal: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
func need(_ ok: Bool, _ why: String) throws { if !ok { throw Refusal(why) } }
func emit(_ data: Map) {
    if let json = try? JSONSerialization.data(withJSONObject: data, options: .sortedKeys) {
        FileHandle.standardOutput.write(json); FileHandle.standardOutput.write(Data([10]))
    }
}
func prop(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(node,key as CFString,&result) == .success ? result : nil
}
func array(_ node: AXUIElement, _ key: String) -> [AXUIElement] { prop(node,key) as? [AXUIElement] ?? [] }
func owner(_ element: AXUIElement) -> pid_t { var p: pid_t = 0; _ = AXUIElementGetPid(element,&p); return p }
func birth(_ p: pid_t) -> UInt64? {
    var b = proc_bsdinfo(); let n = Int32(MemoryLayout.size(ofValue:b))
    guard p > 1, proc_pidinfo(p,PROC_PIDTBSDINFO,0,&b,n) == n, b.pbi_uid == getuid(), b.pbi_pid == UInt32(p), b.pbi_start_tvsec > 0 else { return nil }
    return b.pbi_start_tvsec * 1_000_000 + b.pbi_start_tvusec
}
func path(_ p: pid_t) -> String? {
    var bytes = [CChar](repeating:0,count:4096)
    return proc_pidpath(p,&bytes,UInt32(bytes.count)) > 0 ? String(cString:bytes) : nil
}
func signature(_ p: pid_t) -> (String,String)? {
    var live: SecCode?, selected: SecStaticCode?, fields: CFDictionary?
    guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:p] as CFDictionary,[],&live) == errSecSuccess,
          let live, SecCodeCheckValidity(live,[],nil) == errSecSuccess,
          SecCodeCopyStaticCode(live,[],&selected) == errSecSuccess, let selected,
          SecCodeCopySigningInformation(selected,SecCSFlags(rawValue:kSecCSSigningInformation),&fields) == errSecSuccess,
          let info = fields as? Map, let bytes = info[kSecCodeInfoUnique as String] as? Data,
          let id = info[kSecCodeInfoIdentifier as String] as? String else { return nil }
    return (id,bytes.map { String(format:"%02x",$0) }.joined())
}
struct Space: Codable, Equatable { let id: UInt64; let type: Int; let uuid: UUID }
struct Topology: Codable, Equatable { let display: UUID; let records: [Space]; let current: UInt64 }
struct Window: Codable { let pid: pid_t; let birth: UInt64; let number: UInt32; let executable, identifier, hash: String }
struct Pair: Codable { let topology: Topology; let sourceWindow, targetWindow: Window; let target: UInt64; let hostPID: pid_t; let hostBirth: UInt64; let hostHash: String; let hid: [UInt32] }
func object<T: Encodable>(_ item:T) throws -> Any { try JSONSerialization.jsonObject(with:JSONEncoder().encode(item)) }
func hardware() -> [UInt32] {
    [CGEventType.leftMouseDown,.rightMouseDown,.otherMouseDown,.keyDown,.scrollWheel,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged].map {
        CGEventSource.counterForEventType(.hidSystemState,eventType:$0)
    }
}
func topology() throws -> Topology {
    guard let session = CGSessionCopyCurrentDictionary() as? Map, session[kCGSessionOnConsoleKey as String] as? Bool == true,
          session[kCGSessionLoginDoneKey as String] as? Bool == true, session["CGSSessionScreenIsLocked"] as? Bool != true,
          session[kCGSessionUserIDKey as String] as? UInt32 == getuid() else { throw Refusal("unlocked local console unavailable") }
    var count: UInt32 = 0, online: UInt32 = 0, display = CGDirectDisplayID()
    guard CGGetActiveDisplayList(0,nil,&count) == .success, count == 1, CGGetOnlineDisplayList(0,nil,&online) == .success, online == 1,
          CGGetActiveDisplayList(1,&display,&count) == .success, count == 1, CGDisplayIsInMirrorSet(display) == 0,
          let displayID = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
          let physical = UUID(uuidString:CFUUIDCreateString(nil,displayID) as String),
          let pointer = CGEvent(source:nil)?.location, CGDisplayBounds(display).contains(pointer),
          NPReadOnlySpacesOpen() == 1, let rows = NPReadInventory() as? [Map], rows.count == 1,
          let entry = rows.first, let name = entry["Display Identifier"] as? String, UUID(uuidString:name) == physical,
          let current = (entry["Current Space"] as? Map)?["id64"] as? UInt64,
          let list = entry["Spaces"] as? [Map], (1...256).contains(list.count) else {throw Refusal("single physical pointer display or native Space inventory unavailable")}
    let records = try list.map { r -> Space in
        guard let id = r["id64"] as? UInt64, id > 0, let type = r["type"] as? Int, let raw = r["uuid"] as? String, let uuid = UUID(uuidString:raw) else { throw Refusal("incomplete Space identity") }
        return Space(id:id,type:type,uuid:uuid)
    }
    try need(Set(records.map(\.id)).count == records.count && Set(records.map(\.uuid)).count == records.count && records.contains { $0.id == current },"ambiguous native topology")
    return Topology(display:physical,records:records,current:current)
}
func axFocus(_ pid: pid_t) -> UInt32? {
    let app = AXUIElementCreateApplication(pid); _ = AXUIElementSetMessagingTimeout(app,0.18)
    guard let value = prop(app,kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {return nil}
    let n = NPReadAXWindowNumber(value); return n > 0 ? n : nil
}
func snapshot(_ detailed: Bool) throws -> Map {
    let t = try topology(), front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    var data: Map = ["uptime":ProcessInfo.processInfo.systemUptime,"topology":try object(t),"hid":hardware(),"frontPID":front]
    if detailed { data["focusedNumber"] = axFocus(front) as Any? ?? NSNull(); data["observerAX"] = AXIsProcessTrusted() }
    return data
}
func windowProof(_ w: Window) throws -> Map {
    let allowed = ["org.nearpane.acceptance.LifecycleWindow","net.example.spaces-route-witness","net.example.spaces-document"]
    try need(allowed.contains(w.identifier) && w.executable.hasPrefix("/private/tmp/nearpane-d01.") && path(w.pid) == w.executable && birth(w.pid) == w.birth,"owned fixture executable or kernel process birth changed")
    let code = signature(w.pid)
    try need(code?.0 == w.identifier && code?.1 == w.hash,"fixture running code signature changed")
    let app = AXUIElementCreateApplication(w.pid); _ = AXUIElementSetMessagingTimeout(app,0.4)
    let matching = array(app,kAXWindowsAttribute).filter { owner($0) == w.pid && NPReadAXWindowNumber($0) == w.number }
    let reverse = NPReadWindowSpaces(w.number) as? [UInt64] ?? []
    let forward = reverse.count == 1 ? (NPReadCatalogSpaceWindowNumbers(reverse[0]) as? [UInt32])?.contains(w.number) : nil
    let standard = matching.count == 1 && prop(matching[0],kAXRoleAttribute) as? String == kAXWindowRole && prop(matching[0],kAXSubroleAttribute) as? String == kAXStandardWindowSubrole
    return ["number":w.number,"pid":w.pid,"birth":w.birth,"reverse":reverse,"forward":forward as Any? ?? NSNull(),"standard":standard,"focused":axFocus(w.pid) as Any? ?? NSNull()]
}
func bound(_ w: Window, _ space: UInt64) throws -> Map {
    let proof = try windowProof(w)
    try need(proof["standard"] as? Bool == true && proof["reverse"] as? [UInt64] == [space] && proof["forward"] as? Bool == true,"owned window lacks unique standard AX identity or forward/reverse Space evidence")
    return proof
}
func panelTarget(_ pid: pid_t, _ id:String) throws -> AXUIElement {
    let root = AXUIElementCreateApplication(pid); _ = AXUIElementSetMessagingTimeout(root,0.4)
    var todo = array(root,kAXWindowsAttribute) + [root]
    // Panels omitted by AXWindows can still be addressed by the owner-specific AX hit test.
    let rect = CGDisplayBounds(CGMainDisplayID())
    for fraction in [0.03,0.11,0.89,0.97] {
        var n: AXUIElement?
        if AXUIElementCopyElementAtPosition(root, Float(rect.minX+fraction*rect.width), Float(rect.minY+0.67*rect.height), &n) == .success {
            var node = n
            for _ in 0..<22 {
                guard let e = node, owner(e) == pid else { break }; todo.append(e)
                guard let p = prop(e,kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else {break}; node = (p as! AXUIElement)
            }
        }
    }
    var visited = Set<AXUIElement>(), matches = [AXUIElement]()
    while let n = todo.popLast(), visited.count < 6000 {
        guard owner(n) == pid, visited.insert(n).inserted else {continue}
        let i = prop(n,kAXIdentifierAttribute) as? String ?? ""
        if i == id { matches.append(n); continue }
        if i.hasPrefix("current-desktop-window:") || i.hasPrefix("native-space-window:") {continue}
        let role = prop(n,kAXRoleAttribute) as? String ?? ""
        if !["AXTextField","AXTextArea","AXWebArea","AXStaticText","AXImage"].contains(role) { todo += array(n,kAXChildrenAttribute) }
    }
    guard matches.count == 1 else {throw Refusal("official background card count \(matches.count)")}
    let card = matches[0]; var actions: CFArray?
    try need(prop(card,kAXRoleAttribute) as? String == kAXButtonRole && prop(card,kAXEnabledAttribute) as? Bool == true && AXUIElementCopyActionNames(card,&actions) == .success && (actions as? [String])?.contains(kAXPressAction) == true,"official background card disabled or lacks AXPress")
    return card
}
func guardPair(_ p:Pair) throws {
    try need(AXIsProcessTrusted() && path(p.hostPID) == "/Applications/Nearpane.app/Contents/MacOS/NearpaneHost" && birth(p.hostPID) == p.hostBirth,"signed installed Host path, AX or process generation changed")
    let s = signature(p.hostPID)
    try need(s?.0 == "com.holdsnow.nearpane.alpha" && s?.1 == p.hostHash,"installed running Host signature mismatch")
    try need(try topology() == p.topology && hardware() == p.hid,"Space topology, pointer display or human input changed")
    let ids = p.topology.records.map(\.id)
    guard let a = ids.firstIndex(of:p.topology.current), let b = ids.firstIndex(of:p.target), abs(a-b) == 1 else {throw Refusal("source and target are not exactly adjacent")}
    _ = try bound(p.sourceWindow,p.topology.current); _ = try bound(p.targetWindow,p.target)
    try need(NSWorkspace.shared.frontmostApplication?.processIdentifier == p.sourceWindow.pid && axFocus(p.sourceWindow.pid) == p.sourceWindow.number,"owned source window is not precisely foreground and focused")
}
let arguments = Array(CommandLine.arguments.dropFirst())
var issued = false
func main() throws {
    guard let verb = arguments.first else {throw Refusal("missing mode")}
    switch verb {
    case "watch":
        let end = ProcessInfo.processInfo.systemUptime + 20
        while ProcessInfo.processInfo.systemUptime < end {
            do {emit(try snapshot(false))} catch {emit(["error":String(describing:error),"uptime":ProcessInfo.processInfo.systemUptime])}
            RunLoop.current.run(until:Date(timeIntervalSinceNow:0.06))
        }
    case "state": emit(try snapshot(true))
    case "process":
        guard arguments.count == 2, let pid = pid_t(arguments[1]), let exe = path(pid), let start = birth(pid), let sign = signature(pid) else {throw Refusal("process unavailable")}
        emit(["pid":pid,"executable":exe,"birth":start,"identifier":sign.0,"hash":sign.1])
    case "windows":
        let owned = try JSONDecoder().decode([Window].self,from:FileHandle.standardInput.readDataToEndOfFile()); _ = try topology()
        emit(["windows":try owned.map(windowProof)])
    case "absence":
        let ids = arguments.dropFirst().compactMap(UInt32.init)
        try need(ids.count == arguments.count-1 && !ids.isEmpty,"invalid absent-window probe"); emit(["absence":ids.map { NPReadWindowNumberPresence($0) == 0 }])
    case "inspect", "press":
        let p = try JSONDecoder().decode(Pair.self,from:FileHandle.standardInput.readDataToEndOfFile())
        try guardPair(p)
        let id = "native-space-window:\(p.topology.display.uuidString):\(p.target):\(p.targetWindow.pid):\(p.targetWindow.number)"
        let card = try panelTarget(p.hostPID,id)
        try guardPair(p)
        try need(prop(card,kAXIdentifierAttribute) as? String == id && prop(card,kAXEnabledAttribute) as? Bool == true && owner(card) == p.hostPID,"target card changed before action")
        var out:Map = ["control":id,"ready":true,"issued":false,"uptime":ProcessInfo.processInfo.systemUptime]
        if verb == "press" {
            issued = true; out["issued"] = true; out["axError"] = AXUIElementPerformAction(card,kAXPressAction as CFString).rawValue; out["returnedUptime"] = ProcessInfo.processInfo.systemUptime
        }
        emit(out)
    default: throw Refusal("unknown mode")
    }
}
do {try main()} catch {emit(["issued":issued,"ready":false,"error":(error as? Refusal)?.reason ?? String(describing:error)]) ; exit(2)}
