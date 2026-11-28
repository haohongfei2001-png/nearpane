import AppKit
import ApplicationServices
import Foundation

// Optional photographic placement through the actual native Accessibility API.
// No application scripting-dictionary window classes or fabricated UI are used.
let args=Array(CommandLine.arguments.dropFirst())
guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",args.count>=2 else { exit(2) }
let bundle=args[0];let output=URL(fileURLWithPath:args[1])
var report:[String:Any]=["bundleID":bundle,"accessibilityTrusted":AXIsProcessTrusted(),"uptime":ProcessInfo.processInfo.systemUptime]
func attr(_ e:AXUIElement,_ name:String)->CFTypeRef? { AXUIElementSetMessagingTimeout(e,0.25);var x:CFTypeRef?;return AXUIElementCopyAttributeValue(e,name as CFString,&x) == .success ? x : nil }
func bounds(_ e:AXUIElement)->[String:Double]? {
    guard let a=attr(e,kAXPositionAttribute),let b=attr(e,kAXSizeAttribute),CFGetTypeID(a)==AXValueGetTypeID(),CFGetTypeID(b)==AXValueGetTypeID() else {return nil}
    var p=CGPoint.zero;var s=CGSize.zero
    guard AXValueGetValue(a as! AXValue,.cgPoint,&p),AXValueGetValue(b as! AXValue,.cgSize,&s) else{return nil}
    return ["x":p.x,"y":p.y,"width":s.width,"height":s.height]
}
if let app=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first,AXIsProcessTrusted() {
    report["pid"]=app.processIdentifier
    _=app.activate(options:[.activateIgnoringOtherApps])
    RunLoop.main.run(until:Date().addingTimeInterval(0.3))
    let root=AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(root,1.0)
    let windows=(attr(root,kAXWindowsAttribute) as? [AXUIElement]) ?? []
    report["windows"]=windows.map { ["title":attr($0,kAXTitleAttribute) as? String ?? "","bounds":bounds($0) as Any? ?? NSNull()] }
    if args.count>=6,let x=Double(args[2]),let y=Double(args[3]),let w=Double(args[4]),let h=Double(args[5]) {
        var chosen:AXUIElement?
        if args.contains("--focused"),let focused=attr(root,kAXFocusedWindowAttribute),CFGetTypeID(focused)==AXUIElementGetTypeID(){chosen=(focused as! AXUIElement)}
        if chosen == nil {chosen=windows.max { a,b in let aa=bounds(a);let bb=bounds(b);return (aa?["width"] ?? 0)*(aa?["height"] ?? 0)<(bb?["width"] ?? 0)*(bb?["height"] ?? 0)}}
        if let window=chosen {
            report["before"]=bounds(window)
            var position=CGPoint(x:x,y:y);var size=CGSize(width:w,height:h)
            if let value=AXValueCreate(.cgPoint,&position){report["positionResult"]=AXUIElementSetAttributeValue(window,kAXPositionAttribute as CFString,value).rawValue}
            if let value=AXValueCreate(.cgSize,&size){report["sizeResult"]=AXUIElementSetAttributeValue(window,kAXSizeAttribute as CFString,value).rawValue}
            report["raiseResult"]=AXUIElementPerformAction(window,kAXRaiseAction as CFString).rawValue
            RunLoop.main.run(until:Date().addingTimeInterval(0.2))
            report["after"]=bounds(window)
        }
    }
    if let index=args.firstIndex(of:"--key"),index+1<args.count,NSWorkspace.shared.frontmostApplication?.bundleIdentifier==bundle {
        let key=args[index+1];let code:CGKeyCode;let flags:CGEventFlags
        switch key {
        case "miniplayer":code=46;flags=[.maskCommand,.maskShift]
        case "fit":code=25;flags=[.maskCommand]
        case "hide-sidebar":code=18;flags=[.maskCommand,.maskAlternate]
        default:code=UInt16.max;flags=[]
        }
        if code != UInt16.max {
            for down in [true,false] {let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down);event?.flags=flags;event?.post(tap:.cghidEventTap);RunLoop.main.run(until:Date().addingTimeInterval(0.06))}
            report["actualShortcutPosted"]=key
        }
    }
} else {report["reason"]="No matching running application or existing Accessibility access"}
let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
try data.write(to:output,options:.atomic)
