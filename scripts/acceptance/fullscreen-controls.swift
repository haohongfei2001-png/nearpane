// Operates only on marked controls in an exact, secondary-only candidate window.
import AppKit
import ApplicationServices
import Darwin
func stop(_ s:String)->Never {FileHandle.standardError.write(Data((s+"\n").utf8));exit(2)}
_ = NSApplication.shared.setActivationPolicy(.prohibited)
let a=Array(CommandLine.arguments.dropFirst())
if a == ["preflight"] || a == ["preflight-displays"] {
    let state = CGSessionCopyCurrentDictionary() as? [String:Any]
    guard state?["kCGSSessionOnConsoleKey"] as? Bool == true,
          state?["CGSSessionScreenIsLocked"] as? Bool != true, AXIsProcessTrusted(),
          NSScreen.screens.count == 2, let side = NSScreen.screens.last,
          let number = side.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
          number.uint32Value != CGMainDisplayID(), CGDisplayIsInMirrorSet(number.uint32Value) == 0,
          !CGDisplayBounds(CGMainDisplayID()).intersects(CGDisplayBounds(number.uint32Value)),
          let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
        stop("secondary, unlocked local console, and existing AX permission required")
    }
    let first = NSWorkspace.shared.frontmostApplication?.processIdentifier
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    guard first != nil, first != getpid(), NSWorkspace.shared.frontmostApplication?.processIdentifier == first else {
        stop("foreground in transition")
    }
    if a == ["preflight-displays"] {
        guard let main = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue() else { stop("primary identity") }
        print(CFUUIDCreateString(nil, main) as String)
        guard let first else { stop("foreground unavailable") }
        print(first)
    }
    print(CFUUIDCreateString(nil,uuid) as String)
    exit(0)
}
guard [4, 10].contains(a.count), let pid=Int32(a[0]), let wid=UInt32(a[1]),AXIsProcessTrusted() else { stop("arguments or AX authority") }
let exe=URL(fileURLWithPath:a[2]).resolvingSymlinksInPath()
guard let app=NSRunningApplication(processIdentifier:pid),app.executableURL?.resolvingSymlinksInPath().path==exe.path,
      let bundle=app.bundleURL, let id = Bundle(url:bundle)?.bundleIdentifier, ["com.holdsnow.nearpane.candidate.p51","com.holdsnow.nearpane.candidate.p52","com.holdsnow.nearpane.alpha"].contains(id),
      Bundle(url:bundle)?.executableURL?.resolvingSymlinksInPath().path==exe.path else {stop("running bundle identity")}
let sessions=CGSessionCopyCurrentDictionary() as? [String:Any]
guard sessions?["kCGSSessionOnConsoleKey"] as? Bool==true,sessions?["CGSSessionScreenIsLocked"] as? Bool != true else {stop("console")}
let windows=CGWindowListCopyWindowInfo([.optionIncludingWindow],wid) as? [[String:Any]]
guard let own=windows?.first, own[kCGWindowIsOnscreen as String] as? Bool==true, own[kCGWindowOwnerPID as String] as? Int32==pid, own[kCGWindowNumber as String] as? UInt32==wid,
 let raw=own[kCGWindowBounds as String] as? [String:Double], let rect=CGRect(dictionaryRepresentation:raw as CFDictionary),
 rect.intersection(CGDisplayBounds(CGMainDisplayID())).isEmpty, NSScreen.screens.dropFirst().contains(where:{ screen in
    guard let n=screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber else {return false}
    return CGDisplayBounds(n.uint32Value).contains(rect)
 }) else {stop("secondary bounds")}
func ax(_ e:AXUIElement,_ k:String)->CFTypeRef? { var v:CFTypeRef?; return AXUIElementCopyAttributeValue(e,k as CFString,&v) == .success ? v:nil }
func box(_ e:AXUIElement)->CGRect? {
 guard let pv=ax(e,"AXPosition"),let sv=ax(e,"AXSize"),CFGetTypeID(pv)==AXValueGetTypeID(),CFGetTypeID(sv)==AXValueGetTypeID() else {return nil}
 var p=CGPoint.zero,z=CGSize.zero
 guard AXValueGetValue(pv as! AXValue,.cgPoint,&p),AXValueGetValue(sv as! AXValue,.cgSize,&z) else {return nil}
 return CGRect(origin:p,size:z)
}
// The optional six values bind a real-system overlay action to its still-focused
// foreground witness, its process generation, the secondary display and a deadline.
func verifyLiveWitness() {
    guard a.count == 10 else { return }
    guard ["read", "np.fullscreen.open.voice", "np.fullscreen.close"].contains(a[3]),
          let witness = Int32(a[4]), let launch = UInt64(a[5]), let number = UInt32(a[6]),
          let run = UUID(uuidString: a[7]), let display = UUID(uuidString: a[8]),
          let until = Double(a[9]), until.isFinite, until > ProcessInfo.processInfo.systemUptime,
          witness > 1, witness != pid, number > 0, !app.isActive,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == witness else { stop("witness focus or deadline changed") }
    guard let hostRows = CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String:Any]],
          hostRows.count == 1, let hostRow = hostRows.first,
          hostRow[kCGWindowOwnerPID as String] as? Int32 == pid,
          hostRow[kCGWindowNumber as String] as? UInt32 == wid,
          hostRow[kCGWindowIsOnscreen as String] as? Bool == true,
          let bounds = hostRow[kCGWindowBounds as String] as? NSDictionary,
          CGRect(dictionaryRepresentation:bounds) == rect else { stop("tool panel changed") }
    var info = proc_bsdinfo()
    let bytes = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(witness, PROC_PIDTBSDINFO, 0, &info, bytes) == bytes,
          info.pbi_pid == UInt32(witness), info.pbi_uid == getuid(),
          info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec == launch,
          let focused = ax(AXUIElementCreateApplication(witness), kAXFocusedWindowAttribute),
          CFGetTypeID(focused) == AXUIElementGetTypeID() else { stop("enrolled witness unavailable") }
    let element = focused as! AXUIElement
    var owner: pid_t = 0
    guard AXUIElementGetPid(element, &owner) == .success, owner == witness,
          ax(element, kAXIdentifierAttribute) as? String == run.uuidString + "/A",
          (ax(element, "AXFullScreen") as? NSNumber)?.boolValue == true,
          let af = box(element),
          let records = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]],
          records.count == 1, let record = records.first,
          record[kCGWindowOwnerPID as String] as? Int32 == witness,
          record[kCGWindowNumber as String] as? UInt32 == number,
          record[kCGWindowIsOnscreen as String] as? Bool == true,
          let fields = record[kCGWindowBounds as String] as? NSDictionary,
          let actual = CGRect(dictionaryRepresentation: fields), af.equalTo(actual),
          NSScreen.screens.count == 2, NSScreen.screensHaveSeparateSpaces,
          NSScreen.screens.contains(where: { screen in
              guard let n = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
                    n.uint32Value != CGMainDisplayID(), CGDisplayIsInMirrorSet(n.uint32Value) == 0,
                    let id = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue(),
                    UUID(uuidString: CFUUIDCreateString(nil, id) as String) == display else { return false }
              let area = CGDisplayBounds(n.uint32Value)
              return area.contains(rect) && area.contains(actual)
          }) else { stop("target no longer occupies the enrolled fullscreen display") }
}
verifyLiveWitness()
let root=AXUIElementCreateApplication(pid)
let ownerWindows = ax(root,"AXWindows") as? [AXUIElement] ?? []
let matches=ownerWindows.filter{box($0)==rect}
// The supervised Host supplies its actual EdgePanel window number. Read only this
// process's window list; never traverse children or invoke an action on an edge.
if a[3] == "read-edge-frame" {
    guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != pid,
          !app.isActive, matches.count <= 1 else { stop("ambiguous edge or unexpected foreground") }
    var row: [String:Any] = ["wid":wid, "cg":[rect.minX,rect.minY,rect.width,rect.height],
                             "front":front, "uptime":ProcessInfo.processInfo.systemUptime]
    let numbered = ownerWindows.filter { (ax($0,"AXWindowNumber") as? NSNumber)?.uint32Value == wid }
    guard numbered.count <= 1 else { stop("ambiguous numbered AX window") }
    let geometric = matches.first { ax($0,"AXWindowNumber") == nil }
    if let match = numbered.first ?? geometric {
        var owner: pid_t = 0
        guard AXUIElementGetPid(match,&owner) == .success, owner == pid,
              ax(match,"AXRole") as? String == "AXWindow", let ar = box(match)
        else { stop("unexpected AX edge identity") }
        row["ax"] = [ar.minX,ar.minY,ar.width,ar.height]
        row["axEvidence"] = numbered.isEmpty ? "unique geometry in owned process" : "numbered AX window"
    } else { row["axEvidence"] = "no corresponding AX window exposed" }
    print(String(decoding:try JSONSerialization.data(withJSONObject:row), as:UTF8.self))
    exit(0)
}
guard matches.count==1 else {stop("no unique secondary panel")}
if a.count == 10, let mapped = ax(matches[0], "AXWindowNumber") as? NSNumber, mapped.uint32Value != wid {
    stop("conflicting tool window identity")
}
var nodes:[AXUIElement]=[],seen=Set<AXUIElement>()
func visit(_ e:AXUIElement) {
 guard seen.insert(e).inserted,nodes.count<1000 else {return}
 var id:pid_t=0;guard AXUIElementGetPid(e,&id) == .success,id==pid else {return}
 nodes.append(e);for child in ax(e,"AXChildren") as? [AXUIElement] ?? [] {visit(child)}
}
visit(matches[0])
func string(_ e:AXUIElement,_ k:String)->String {(ax(e,k) as? String) ?? ""}

if a[3] == "read-desktop-outlines" {
    guard id == "com.holdsnow.nearpane.alpha", !app.isActive,
          NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { stop("unexpected active Host") }
    let pattern = #"^窗口 [1-9][0-9]*，左距 [0-9]{1,3}%，上距 [0-9]{1,3}%，宽 [0-9]{1,3}%，高 [0-9]{1,3}%$"#
    var outlines: [String] = []
    for node in nodes where string(node, "AXIdentifier") == "desktop-window-outline" {
        let labels = ["AXValue", "AXDescription", "AXTitle"].map { string(node, $0) }
        guard let description = labels.first(where: { $0.range(of: pattern, options: .regularExpression) != nil }),
              string(node, "AXRole") == "AXStaticText" else { stop("unexpected outline semantics") }
        var actions: CFArray?
        guard AXUIElementCopyActionNames(node, &actions) == .success,
              !(actions as? [String] ?? []).contains("AXPress") else { stop("unexpected outline action") }
        outlines.append(description)
    }
    print(String(decoding: try JSONEncoder().encode(outlines), as: UTF8.self))
    exit(0)
}

if a[3] == "read-appearance" {
    guard id == "com.holdsnow.nearpane.alpha", !app.isActive,
          NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { stop("appearance target active") }
    func visibleThroughParents(_ e: AXUIElement, frame: CGRect) -> Bool {
        var node = e
        var visited = Set<AXUIElement>()
        while visited.insert(node).inserted, visited.count <= 64 {
            if ax(node, "AXHidden") as? Bool == true { return false }
            if string(node, "AXRole") == "AXScrollArea" {
                guard let clip = box(node), clip.contains(frame) else { return false }
            }
            if CFEqual(node, matches[0]) { return true }
            guard let parent = ax(node, "AXParent"), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            node = parent as! AXUIElement
        }
        return false
    }
    // Export geometry and semantic types only. No AXValue, transcript, or private window text.
    let visible = nodes.compactMap { e -> [String:Any]? in
        let role = string(e, "AXRole"), kind: String
        if role == "AXTextArea" && string(e, "AXHelp") == "修改这段文字…" { kind = "transcript" }
        else if role == "AXButton", ax(e, "AXEnabled") as? Bool == true,
                [string(e, "AXDescription"), string(e, "AXTitle")].contains("开始或恢复收音") {
            kind = "startCapture"
        }
        else if ["AXImage", "AXButton"].contains(role),
                string(e, "AXDescription").range(of: #"^(?:附加到草稿，)?截图 [0-9]+$"#, options: .regularExpression) != nil { kind = "thumbnail" }
        else { return nil }
        guard let frame = box(e), !frame.isEmpty, rect.contains(frame), visibleThroughParents(e, frame: frame) else { return nil }
        return ["kind":kind, "frame":[frame.minX,frame.minY,frame.width,frame.height]]
    }
    print(String(decoding:try JSONSerialization.data(withJSONObject:[
        "pid": pid, "window":wid, "panel":[rect.minX,rect.minY,rect.width,rect.height], "visible":visible
    ]),as:UTF8.self))
    exit(0)
}

let commands = ["np.fullscreen.open.voice": "AXPress", "np.fullscreen.open.capture": "AXPress",
                "np.fullscreen.close": "AXPress", "np.fullscreen.move": "AXDecrement"]
let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
guard front != nil, front != pid else { stop("test panel stole foreground") }
let command = a[3]
let known = nodes.compactMap { node -> String? in
    let id = string(node, "AXIdentifier")
    return id.hasPrefix("np.fullscreen.") ? id : nil
}
if command == "read" {
    let details: [[String:Any]] = nodes.map { node in
        var actions: CFArray?
        _ = AXUIElementCopyActionNames(node, &actions)
        let f = box(node)
        return ["id":string(node,"AXIdentifier"),"role":string(node,"AXRole"),
                "enabled":ax(node,"AXEnabled") as? Bool as Any? ?? NSNull(),
                "bounds":f.map { [$0.minX,$0.minY,$0.width,$0.height] } as Any? ?? NSNull(),
                "actions":actions as? [String] ?? []]
    }
    let receipt: [String:Any] = ["controls":known, "frontPID":front!, "bounds":[rect.minX,rect.minY,rect.width,rect.height], "details":details]
    print(String(decoding:try JSONSerialization.data(withJSONObject:receipt),as:UTF8.self))
} else {
    guard let action = commands[command] else { stop("unsupported control") }
    let controls = nodes.filter { string($0,"AXIdentifier") == command }
    guard controls.count == 1, let control = controls.first, let frame = box(control), !frame.isEmpty,
          rect.contains(frame) else { stop("no unique control inside panel: " + command) }
    var available: CFArray?
    let role = string(control,"AXRole")
    let enabled = ax(control,"AXEnabled") as? Bool
    guard AXUIElementCopyActionNames(control, &available) == .success,
          (available as? [String])?.contains(action) == true,
          action == "AXDecrement" ? (role == "AXSlider" && enabled != false) : (role == "AXButton" && enabled == true)
    else { stop("control does not advertise this action: " + command) }
    verifyLiveWitness()
    guard AXUIElementPerformAction(control, action as CFString) == .success else { stop("AX action denied: " + command) }
}
