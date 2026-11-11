// Operates only on marked controls in an exact, secondary-only P5.1 candidate window.
import AppKit
import ApplicationServices
import Darwin
func stop(_ s:String)->Never {FileHandle.standardError.write(Data((s+"\n").utf8));exit(2)}
_ = NSApplication.shared.setActivationPolicy(.prohibited)
let a=Array(CommandLine.arguments.dropFirst())
if a == ["preflight"] {
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
    print(CFUUIDCreateString(nil,uuid) as String)
    exit(0)
}
guard a.count==4, let pid=Int32(a[0]), let wid=UInt32(a[1]),AXIsProcessTrusted() else { stop("arguments or AX authority") }
let exe=URL(fileURLWithPath:a[2]).resolvingSymlinksInPath()
guard let app=NSRunningApplication(processIdentifier:pid),app.executableURL?.resolvingSymlinksInPath().path==exe.path,
      let bundle=app.bundleURL, Bundle(url:bundle)?.bundleIdentifier=="com.holdsnow.nearpane.candidate.p51",
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
let root=AXUIElementCreateApplication(pid)
let matches=(ax(root,"AXWindows") as? [AXUIElement] ?? []).filter{box($0)==rect}
guard matches.count==1 else {stop("no unique secondary panel")}
var nodes:[AXUIElement]=[],seen=Set<AXUIElement>()
func visit(_ e:AXUIElement) {
 guard seen.insert(e).inserted,nodes.count<1000 else {return}
 var id:pid_t=0;guard AXUIElementGetPid(e,&id) == .success,id==pid else {return}
 nodes.append(e);for child in ax(e,"AXChildren") as? [AXUIElement] ?? [] {visit(child)}
}
visit(matches[0])
func string(_ e:AXUIElement,_ k:String)->String {(ax(e,k) as? String) ?? ""}

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
    guard AXUIElementPerformAction(control, action as CFString) == .success else { stop("AX action denied: " + command) }
}
