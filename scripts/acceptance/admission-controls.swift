// Operates only on marked controls in the identified candidate window on the secondary display.
import AppKit
import ApplicationServices
import Darwin
func stop(_ s:String)->Never {FileHandle.standardError.write(Data((s+"\n").utf8));exit(2)}
let a=Array(CommandLine.arguments.dropFirst())
guard a.count==4, let pid=Int32(a[0]), let wid=UInt32(a[1]),AXIsProcessTrusted() else { stop("arguments or AX authority") }
let exe=URL(fileURLWithPath:a[2]).resolvingSymlinksInPath()
guard let app=NSRunningApplication(processIdentifier:pid),app.executableURL?.resolvingSymlinksInPath().path==exe.path,
      let bundle=app.bundleURL, let candidateID = Bundle(url:bundle)?.bundleIdentifier,
      ["com.holdsnow.nearpane.candidate.p49", "com.holdsnow.nearpane.alpha"].contains(candidateID),
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
func label(_ e:AXUIElement)->String {[string(e,"AXTitle"),string(e,"AXDescription")].joined(separator:" ")}


let command = a[3]
let profile = candidateID == "com.holdsnow.nearpane.alpha"
let fixed = profile ? ["np.profile.preview", "np.profile.import", "np.profile.quit"] : ["admission-open", "admission-fixture-app", "admission-read", "admission-docked", "admission-current", "admission-custom",
             "admission-floating", "admission-refresh", "nearpane-open-panel", "nearpane-close-panel"]
func identifier(_ e: AXUIElement) -> String { string(e, "AXIdentifier") }
if command == "read" {
    let facts = nodes.compactMap { e -> [String: Any]? in
        let id = identifier(e)
        guard (!profile && id.hasPrefix("admission-")) || fixed.contains(id) else { return nil }
        return ["id": id, "role": string(e, "AXRole"), "name": label(e), "value": string(e, "AXValue"), "enabled": ax(e,"AXEnabled") as? Bool ?? false]
    }
    print(String(decoding: try JSONSerialization.data(withJSONObject: ["bounds": [rect.minX,rect.minY,rect.width,rect.height],
          "frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, "nodes": facts]), as: UTF8.self))
} else {
    let suffix = command.hasPrefix("admission-window-") ? String(command.dropFirst("admission-window-".count)) : ""
    guard fixed.contains(command) || (!profile && UInt32(suffix).map({String($0) == suffix}) == true) else { stop("control not allowed") }
    if profile && (app.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid) { stop("unexpected activation") }
    let matches = nodes.filter { identifier($0) == command }
    guard matches.count == 1, let e = matches.first, let f = box(e), !f.isEmpty,
          ["AXButton","AXCheckBox","AXRadioButton","AXDisclosureTriangle"].contains(string(e,"AXRole")),
          (ax(e,"AXEnabled") as? Bool) == true else { stop("missing, disabled or ambiguous: "+command) }
    guard profile ? rect.contains(f) : rect.intersects(f) else { stop("control outside panel: "+command+" "+NSStringFromRect(f)) }
    let result = AXUIElementPerformAction(e, kAXPressAction as CFString)
    if profile && command == "np.profile.quit" && result == .cannotComplete {
        // AppKit may destroy this element before replying. The driver must independently wait for exit 0.
        print("quit requested; awaiting process exit")
    } else if result != .success {
        stop("AXPress returned "+String(result.rawValue)+" for "+command)
    }
}
