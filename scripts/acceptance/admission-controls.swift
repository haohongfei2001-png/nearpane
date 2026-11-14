// Operates only on marked controls in the identified candidate window on the secondary display.
import AppKit
import ApplicationServices
import Darwin
func stop(_ s:String)->Never {FileHandle.standardError.write(Data((s+"\n").utf8));exit(2)}
let a=Array(CommandLine.arguments.dropFirst())
let ordinary = a.count == 5 && a[4] == "--ordinary-secondary"
let sizing = a.count == 5 && a[4] == "--sizes-secondary"
let services = a.count == 5 && a[4] == "--services-secondary"
guard (a.count == 4 || ordinary || sizing || services), let pid=Int32(a[0]), let wid=UInt32(a[1]),AXIsProcessTrusted() else { stop("arguments or AX authority") }
let exe=URL(fileURLWithPath:a[2]).resolvingSymlinksInPath()
guard let app=NSRunningApplication(processIdentifier:pid),app.executableURL?.resolvingSymlinksInPath().path==exe.path,
      let bundle=app.bundleURL, let candidateID = Bundle(url:bundle)?.bundleIdentifier,
      ["com.holdsnow.nearpane.candidate.p49", "com.holdsnow.nearpane.alpha"].contains(candidateID),
      Bundle(url:bundle)?.executableURL?.resolvingSymlinksInPath().path==exe.path else {stop("running bundle identity")}
let sessions=CGSessionCopyCurrentDictionary() as? [String:Any]
guard sessions?["kCGSSessionOnConsoleKey"] as? Bool==true,sessions?["CGSSessionScreenIsLocked"] as? Bool != true else {stop("console")}
let windows=CGWindowListCopyWindowInfo([.optionIncludingWindow],wid) as? [[String:Any]]
guard let own=windows?.first else {stop("panel not ordered")}
guard own[kCGWindowOwnerPID as String] as? Int32==pid, own[kCGWindowNumber as String] as? UInt32==wid else {stop("panel identity changed")}
guard own[kCGWindowIsOnscreen as String] as? Bool==true else {stop("panel not ordered")}
guard let raw=own[kCGWindowBounds as String] as? [String:Double], let rect=CGRect(dictionaryRepresentation:raw as CFDictionary),
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
guard !(ordinary || sizing || services) || profile else { stop("candidate identity") }
let ordinaryFixed = ["admission-open", "admission-ordinary-app", "admission-read",
                     "ordinary-confirm", "ordinary-stop", "ordinary-pause", "ordinary-resume", "ordinary-pair", "ordinary-keep-current",
                     "nearpane-open-panel", "nearpane-close-panel"]
let sizeFixed = ["sizes-reset-group", "sizes-reset-display", "sizes-reset-cancel", "sizes-reset-apply",
                 "com.holdsnow.nearpane.clock-sample", "nearpane-module-close"]
let fixed = services ? ["np.feedback.open", "np.feedback.preview", "np.services.quit"] : sizing ? sizeFixed : ordinary ? ordinaryFixed : profile ? ["np.profile.preview", "np.profile.import", "np.profile.quit"] : ["admission-open", "admission-fixture-app", "admission-read", "admission-docked", "admission-current", "admission-custom",
             "admission-floating", "admission-refresh", "nearpane-open-panel", "nearpane-close-panel"]
func identifier(_ e: AXUIElement) -> String { string(e, "AXIdentifier") }
if command == "read" {
    let facts = nodes.compactMap { e -> [String: Any]? in
        let id = identifier(e)
        guard ((!profile || ordinary) && id.hasPrefix("admission-")) || (ordinary && id.hasPrefix("ordinary-")) || fixed.contains(id) || (sizing && id == "clock-local-time") || (services && (id.hasPrefix("np.feedback.") || id.hasPrefix("np.update."))) else { return nil }
        var fact: [String:Any] = ["id": id, "role": string(e, "AXRole"), "name": label(e), "value": string(e, "AXValue"), "enabled": ax(e,"AXEnabled") as? Bool ?? false]
        if sizing || services { fact["contained"] = box(e).map { !$0.isEmpty && rect.contains($0) } ?? false }
        return fact
    }
    print(String(decoding: try JSONSerialization.data(withJSONObject: ["bounds": [rect.minX,rect.minY,rect.width,rect.height],
          "frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, "nodes": facts]), as: UTF8.self))
} else if (sizing || services) && command == "scroll-settings-end" {
    guard !app.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
          nodes.contains(where: { identifier($0) == (services ? "np.feedback.open" : "sizes-reset-display") }) else { stop("unverified settings controls") }
    let bars = nodes.filter { string($0,"AXRole") == "AXScrollArea" }.compactMap { node -> AXUIElement? in
        guard let frame = box(node), rect.intersects(frame),
              !services || frame.height > 150, // the services text editor is limited to 140 pt
              let bar = ax(node,"AXVerticalScrollBar"),
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        return (bar as! AXUIElement)
    }
    guard bars.count == 1 else {
        let details = nodes.filter { string($0,"AXRole") == "AXScrollArea" }.map { node in
            "frame=\(box(node).map(NSStringFromRect) ?? "unknown") bar=\(ax(node,"AXVerticalScrollBar") != nil)"
        }
        stop("ambiguous settings scrollbar: candidates=\(bars.count); " + details.joined(separator: "; "))
    }
    if let upper = ax(bars[0],"AXMaxValue") as? NSNumber {
        guard AXUIElementSetAttributeValue(bars[0],"AXValue" as CFString,upper) == .success else { stop("settings scroll refused") }
    } else {
        // SwiftUI can expose page actions on the scroll area instead of a
        // numeric scrollbar range. Execute only the action actually advertised.
        let areas = nodes.filter { string($0,"AXRole") == "AXScrollArea" &&
            box($0).map { $0.height > 150 && rect.contains($0) } == true }
        guard services, areas.count == 1, !app.isTerminated, !app.isActive else { stop("settings page unavailable") }
        var raw: CFArray?
        guard AXUIElementCopyActionNames(areas[0], &raw) == .success else { stop("settings page actions unavailable") }
        let names = raw as? [String] ?? []
        guard names.contains("AXScrollDownByPage") else { stop("settings page cannot scroll: " + names.joined(separator: ",")) }
        guard AXUIElementPerformAction(areas[0], "AXScrollDownByPage" as CFString) == .success else { stop("settings page scroll refused") }
        print("one advertised AXScrollDownByPage action")
    }
} else {
    let suffix = command.hasPrefix("admission-window-") ? String(command.dropFirst("admission-window-".count)) : ""
    let excluded = command.hasPrefix("ordinary-exclude-") ? String(command.dropFirst("ordinary-exclude-".count)) : ""
    let enrolledApp = command.hasPrefix("admission-ordinary-app-") ? String(command.dropFirst("admission-ordinary-app-".count)) : ""
    guard fixed.contains(command) || (ordinary && Int32(enrolledApp).map { $0 > 1 && String($0) == enrolledApp } == true) || ((!profile || ordinary) && UInt32(suffix).map({String($0) == suffix}) == true)
            || (ordinary && UInt32(excluded).map({String($0) == excluded}) == true) else { stop("control not allowed") }
    if profile && (app.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid) { stop("unexpected activation") }
    let matches = nodes.filter { identifier($0) == command }
    guard matches.count == 1, let e = matches.first, let f = box(e), !f.isEmpty,
          ["AXButton","AXCheckBox","AXRadioButton","AXDisclosureTriangle"].contains(string(e,"AXRole")),
          (ax(e,"AXEnabled") as? Bool) == true else { stop("missing, disabled or ambiguous: "+command) }
    guard profile ? rect.contains(f) : rect.intersects(f) else { stop("control outside panel: "+command+" "+NSStringFromRect(f)) }
    let result = AXUIElementPerformAction(e, kAXPressAction as CFString)
    if profile && ["np.profile.quit", "np.services.quit"].contains(command) && result == .cannotComplete {
        // AppKit may destroy this element before replying. The driver must independently wait for exit 0.
        print("quit requested; awaiting process exit")
    } else if result != .success {
        stop("AXPress returned "+String(result.rawValue)+" for "+command)
    }
}
