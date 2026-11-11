// Operates only on marked controls in an exact, secondary-only P5.0 candidate window.
import AppKit
import ApplicationServices
import Darwin
func stop(_ s:String)->Never {FileHandle.standardError.write(Data((s+"\n").utf8));exit(2)}
let a=Array(CommandLine.arguments.dropFirst())
guard a.count==4, let pid=Int32(a[0]), let wid=UInt32(a[1]),AXIsProcessTrusted() else { stop("arguments or AX authority") }
let exe=URL(fileURLWithPath:a[2]).resolvingSymlinksInPath()
guard let app=NSRunningApplication(processIdentifier:pid),app.executableURL?.resolvingSymlinksInPath().path==exe.path,
      let bundle=app.bundleURL, Bundle(url:bundle)?.bundleIdentifier=="com.holdsnow.nearpane.candidate.p50",
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



let expected = ["expand": "展开截图方式", "capture": "系统截图"]
guard let labelText = expected[a[3]] else { stop("unsupported action") }
let buttons = nodes.filter { string($0, "AXRole") == "AXButton" && label($0).trimmingCharacters(in:.whitespaces) == labelText }
guard buttons.count == 1, let button = buttons.first, let f = box(button), rect.contains(f), !f.isEmpty,
      (ax(button,"AXEnabled") as? Bool) == true,
      AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { stop("no unique visible capture control") }
