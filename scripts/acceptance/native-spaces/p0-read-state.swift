// Shared numeric process, Space and focus readers. No input or activation operations.
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
struct ActualFocus {
    let pid:pid_t, element:AXUIElement?, number:UInt32?, processBirth:UInt64?
    var fields:Map {["pid":pid,"number":number as Any? ?? NSNull(),"birth":processBirth as Any? ?? NSNull()]}
}
func actualFocus() -> ActualFocus? {
    let system=AXUIElementCreateSystemWide()
    _=AXUIElementSetMessagingTimeout(system,0.24)
    func foreground()->AXUIElement? {
        guard let app=prop(system,kAXFocusedApplicationAttribute),CFGetTypeID(app)==AXUIElementGetTypeID() else {return nil}
        return (app as! AXUIElement)
    }
    guard let app=foreground() else {return nil}
    let pid=owner(app);guard pid>1 else {return nil}
    let born=birth(pid)
    _=AXUIElementSetMessagingTimeout(app,0.24)
    let value=prop(app,kAXFocusedWindowAttribute)
    let window:AXUIElement?
    if let value,CFGetTypeID(value)==AXUIElementGetTypeID(),owner(value as! AXUIElement)==pid {window=(value as! AXUIElement)}
    else {window=nil}
    guard let again=foreground(),owner(again)==pid else {return nil}
    let n=window.map{NPReadAXWindowNumber($0)} ?? 0
    return ActualFocus(pid:pid,element:window,number:n>0 ? n : nil,processBirth:born == birth(pid) ? born : nil)
}
func snapshot(_ detailed: Bool) throws -> Map {
    let t=try topology(),workspace=NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    var data:Map=["uptime":ProcessInfo.processInfo.systemUptime,"topology":try object(t),"hid":hardware(),"frontPID":workspace]
    if detailed {
        let observed=actualFocus()
        data["workspaceFrontPID"]=workspace;data["systemFocus"]=observed?.fields as Any? ?? NSNull()
        data["frontPID"]=observed?.pid ?? workspace;data["focusedNumber"]=observed?.number as Any? ?? NSNull()
        data["observerAX"]=AXIsProcessTrusted()
    }
    return data
}
func exactWindowOwner(_ n:UInt32)->(pid_t,Int)? {
    var raw=UnsafeRawPointer(bitPattern:UInt(n))
    guard let ids=CFArrayCreate(nil,&raw,1,nil),let rows=CGWindowListCreateDescriptionFromArray(ids) as? [Map],rows.count==1,
          rows[0][kCGWindowNumber as String] as? UInt32==n,let pid=rows[0][kCGWindowOwnerPID as String] as? pid_t,
          let layer=rows[0][kCGWindowLayer as String] as? Int else {return nil}
    return (pid,layer)
}
