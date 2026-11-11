// Independent read-only observer. Window metadata is restricted to the fixture's process.
import AppKit
import ApplicationServices
import Darwin

func die(_ r: String) -> Never { FileHandle.standardError.write(Data((r+"\n").utf8)); exit(2) }
func value(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e,key as CFString,&v) == .success ? v : nil
}
typealias AXWindowNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern:-2), "_AXUIElementGetWindow") else { die("window identity unavailable") }
let numberFunction = unsafeBitCast(symbol, to:AXWindowNumber.self)
func number(_ e: AXUIElement) -> UInt32? {
    var n: UInt32 = 0
    if let v = value(e,"AXWindowNumber") as? NSNumber { return v.uint32Value }
    return numberFunction(e,&n) == .success && n > 0 ? n : nil
}
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = value(e,"AXPosition"), CFGetTypeID(p)==AXValueGetTypeID(),
          let s = value(e,"AXSize"), CFGetTypeID(s)==AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue,.cgPoint,&origin),AXValueGetValue(s as! AXValue,.cgSize,&size) else { return nil }
    return CGRect(origin:origin,size:size)
}
func rect(_ r:CGRect)->[Double] { [r.minX,r.minY,r.width,r.height] }
let screens = NSScreen.screens
guard screens.count == 2, let side = screens.last,
      let display = side.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
      !CGDisplayBounds(display.uint32Value).intersects(CGDisplayBounds(CGMainDisplayID())),
      CGDisplayIsInMirrorSet(display.uint32Value) == 0, let uuid = CGDisplayCreateUUIDFromDisplayID(display.uint32Value)?.takeRetainedValue(),
      let session = CGSessionCopyCurrentDictionary() as? [String:Any],session["kCGSSessionOnConsoleKey"] as? Bool == true,
      session["CGSSessionScreenIsLocked"] as? Bool != true, AXIsProcessTrusted(),
      let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
      let focused = value(AXUIElementCreateApplication(front),"AXFocusedWindow"),CFGetTypeID(focused) == AXUIElementGetTypeID(),
      let focusedNumber = number(focused as! AXUIElement) else { die("secondary display, console, existing AX permission or focus unavailable") }
var output:[String:Any] = ["side":CFUUIDCreateString(nil,uuid) as String,"bounds":rect(CGDisplayBounds(display.uint32Value)),
                            "front":front,"focus":focusedNumber,"time":ProcessInfo.processInfo.systemUptime]
let strings = Array(CommandLine.arguments.dropFirst())
if strings.first == "launch" {
    guard strings.count == 3 else { die("launch parameters") }
    let url=URL(fileURLWithPath: strings[1])
    guard url.path.hasPrefix("/private/tmp/nearpane-standard-windows."), url.lastPathComponent == "Standard documents.app",
          let id=Bundle(url:url)?.bundleIdentifier, id == "net.example.standard-documents",
          NSRunningApplication.runningApplications(withBundleIdentifier:id).isEmpty else { die("fixture scope") }
    let c=NSWorkspace.OpenConfiguration()
    c.activates=false; c.addsToRecentItems=false; c.createsNewApplicationInstance=true
    c.arguments=["--sample-pipes",strings[2]]
    var complete=false
    NSWorkspace.shared.openApplication(at:url,configuration:c) { app,error in
        output["subjectPID"]=app?.processIdentifier
        if let error { output["error"]=error.localizedDescription }
        complete=true
    }
    let deadline=Date().addingTimeInterval(5)
    while !complete && Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
    guard complete,output["subjectPID"] != nil else { die("LaunchServices did not start the enrolled sample") }
} else if strings.first == "gone" {
    guard strings.count >= 2, let pid=Int32(strings[1]), NSRunningApplication(processIdentifier: pid) == nil else { die("unexpected live process") }
    let residual:[UInt32]=strings.dropFirst(2).compactMap { str in
        guard let n=UInt32(str) else { die("number") }
        let list=CGWindowListCopyWindowInfo(.optionIncludingWindow,n) as? [[String:Any]] ?? []
        return list.contains(where: { $0[kCGWindowOwnerPID as String] as? Int32 == pid && $0[kCGWindowNumber as String] as? UInt32 == n }) ? n : nil
    }
    output["residual"]=residual
} else if !strings.isEmpty {
    guard strings.count >= 2, let pid = Int32(strings[0]),let app = NSRunningApplication(processIdentifier:pid),
          app.executableURL?.standardizedFileURL.path == URL(fileURLWithPath:strings[1]).standardizedFileURL.path,
          let id = app.bundleIdentifier,id == "net.example.standard-documents"
    else { die("wrong subject") }
    var identity = proc_bsdinfo()
    let identityBytes = Int32(MemoryLayout.size(ofValue: identity))
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &identity, identityBytes) == identityBytes,
          identity.pbi_pid == UInt32(pid), identity.pbi_uid == getuid() else { die("incomplete fixture identity") }
    output["ownerLaunch"] = identity.pbi_start_tvsec * 1_000_000 + identity.pbi_start_tvusec
    output["ownerBundle"] = id
    output["ownerRegular"] = app.activationPolicy == .regular
    output["ownerTerminated"] = app.isTerminated
    let axRoot = AXUIElementCreateApplication(pid)
    let all = value(axRoot,"AXWindows") as? [AXUIElement] ?? []
    var records = [[String:Any]]()
    for k in strings.dropFirst(2) {
        guard let n = UInt32(k) else { die("invalid number") }
        let ax = all.filter { number($0) == n }
        let cg = (CGWindowListCopyWindowInfo(.optionIncludingWindow,n) as? [[String:Any]] ?? []).filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowNumber as String] as? UInt32) == n
        }
        var a:[String:Any] = ["number":n,"axMatches":ax.count,"cgMatches":cg.count]
        if ax.count == 1, let e = ax.first, let r = frame(e) {
            a["ax"] = rect(r); a["hasAXMinSize"] = value(e,"AXMinSize") != nil
            a["role"] = value(e,"AXSubrole") as? String
        }
        if cg.count == 1, let row=cg.first,let d=row[kCGWindowBounds as String] as? NSDictionary,let r=CGRect(dictionaryRepresentation:d) {
            a["cg"]=rect(r); a["layer"]=row[kCGWindowLayer as String]; a["on"]=row[kCGWindowIsOnscreen as String]
        }
        records.append(a)
    }
    output["windows"]=records
}
print(String(decoding:try JSONSerialization.data(withJSONObject:output),as:UTF8.self))
