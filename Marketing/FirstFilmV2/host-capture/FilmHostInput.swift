// Real native pointer input in an owned disposable CI Host. All actionable
// controls are selected from current AX labels/identifiers, never drawn UI.
import AppKit
import ApplicationServices
import Foundation

let args=Array(CommandLine.arguments.dropFirst())
guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",args.count>=3,
      let pid=Int32(args[0]),let app=NSRunningApplication(processIdentifier:pid),
      app.bundleIdentifier == "com.holdsnow.nearpane.alpha",AXIsProcessTrusted(),CGPreflightPostEventAccess()
else { exit(2) }
let action=args[1],output=URL(fileURLWithPath:args[2])
var report:[String:Any]=["action":action,"pid":pid,"uptime":ProcessInfo.processInfo.systemUptime,"actualCGEvents":true]
func save(){if let bytes=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]){try? bytes.write(to:output,options:.atomic)}}
func attr(_ e:AXUIElement,_ key:String)->CFTypeRef?{var value:CFTypeRef?;return AXUIElementCopyAttributeValue(e,key as CFString,&value) == .success ? value:nil}
func str(_ e:AXUIElement,_ key:String)->String{attr(e,key) as? String ?? ""}
func rect(_ e:AXUIElement)->CGRect?{
    guard let a=attr(e,kAXPositionAttribute),let b=attr(e,kAXSizeAttribute),CFGetTypeID(a)==AXValueGetTypeID(),CFGetTypeID(b)==AXValueGetTypeID() else{return nil}
    var p=CGPoint.zero;var s=CGSize.zero
    guard AXValueGetValue(a as! AXValue,.cgPoint,&p),AXValueGetValue(b as! AXValue,.cgSize,&s),s.width>0,s.height>0 else{return nil}
    return CGRect(origin:p,size:s)
}
func info(_ e:AXUIElement)->[String:Any]{
    var result:[String:Any]=["role":str(e,kAXRoleAttribute),"id":str(e,kAXIdentifierAttribute),"title":str(e,kAXTitleAttribute),"description":str(e,kAXDescriptionAttribute)]
    if let r=rect(e){result["rect"]=[r.minX,r.minY,r.width,r.height]};return result
}
let root=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(root,0.3)
var nodes:[AXUIElement]=[]
func visit(_ e:AXUIElement,_ depth:Int){guard depth<18,nodes.count<3000 else{return};nodes.append(e);for child in (attr(e,kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(120){visit(child,depth+1)}}
visit(root,0)
report["observedControls"]=nodes.filter{!str($0,kAXIdentifierAttribute).isEmpty || str($0,kAXRoleAttribute)==kAXButtonRole}.map(info)
func named(_ name:String)->AXUIElement?{nodes.first{str($0,kAXIdentifierAttribute)==name || str($0,kAXTitleAttribute)==name || str($0,kAXDescriptionAttribute)==name}}
func point(_ e:AXUIElement)->CGPoint?{rect(e).map{CGPoint(x:$0.midX,y:$0.midY)}}
// This is a separate input process, not the UI process. Thread.sleep keeps the
// intended event cadence; RunLoop's minimum wake interval stretched each 25 ms
// sample toward 100 ms on this CI image and made a nominal 1 s drag take 4 s.
func pump(_ seconds:Double){Thread.sleep(forTimeInterval:seconds)}
func post(_ type:CGEventType,_ p:CGPoint){CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:p,mouseButton:.left)?.post(tap:.cghidEventTap)}
func move(_ target:CGPoint,_ seconds:Double=0.45){
    let initial=CGEvent(source:nil)?.location ?? target
    for i in 1...24 {let t=Double(i)/24;let eased=t*t*(3-2*t);post(.mouseMoved,CGPoint(x:initial.x+(target.x-initial.x)*eased,y:initial.y+(target.y-initial.y)*eased));pump(seconds/24)}
}
func hit(_ p:CGPoint)->Bool{
    var element:AXUIElement?;let system=AXUIElementCreateSystemWide()
    let status=AXUIElementCopyElementAtPosition(system,Float(p.x),Float(p.y),&element)
    var owner:pid_t=0;if let element{_ = AXUIElementGetPid(element,&owner)}
    report["hitTest"]=["result":status.rawValue,"ownerPID":owner,"point":[p.x,p.y]]
    return status == .success && owner==pid
}
func click(_ e:AXUIElement)->Bool{guard let p=point(e) else{return false};move(p);guard hit(p) else{return false};post(.leftMouseDown,p);pump(0.08);post(.leftMouseUp,p);return true}
func drag(_ from:CGPoint,_ to:CGPoint,moved:Bool=false){
    if !moved{move(from)};post(.leftMouseDown,from);pump(0.25)
    for i in 1...40 {let t=Double(i)/40;let u=t*t*(3-2*t);post(.leftMouseDragged,CGPoint(x:from.x+(to.x-from.x)*u,y:from.y+(to.y-from.y)*u));pump(0.025)}
    pump(0.15);post(.leftMouseUp,to)
}
var ok=false
switch action {
case "inspect":ok=true
case "reorder":
    if let from=named("module-open-com.holdsnow.nearpane.riftlet"),let to=named("module-open-com.holdsnow.nearpane.lyrictile"),let p=point(from),let q=point(to){
        report["source"]=info(from);report["destination"]=info(to)
        move(p);if hit(p){drag(p,q,moved:true);ok=true}
    }
case "close-management":
    let windows=attr(root,kAXWindowsAttribute) as? [AXUIElement] ?? []
    if let window=windows.first(where:{str($0,kAXTitleAttribute)=="Nearpane"}),let raw=attr(window,kAXCloseButtonAttribute),CFGetTypeID(raw)==AXUIElementGetTypeID(){ok=click(raw as! AXUIElement)}
case "camera":if let e=named("tray-camera-entry"){report["selected"]=info(e);ok=click(e)}
case "region":if let e=named("区域截图"){report["selected"]=info(e);ok=click(e)}
case "select-region":
    // Coordinates are restricted to the middle water photograph of our own
    // Preview PDF; its actual window geometry is supplied by the driver.
    if args.count==7,let x=Double(args[3]),let y=Double(args[4]),let w=Double(args[5]),let h=Double(args[6]),w>20,h>20,w<1500,h<900 {
        let from=CGPoint(x:x,y:y),to=CGPoint(x:x+w,y:y+h)
        report["ownedDocumentRegion"]=[x,y,w,h];drag(from,to);ok=true
    }
case "leave":
    if let camera=named("film-riftlet-card"),let r=rect(camera){move(CGPoint(x:r.minX-100,y:r.maxY+50));ok=true}
default:break
}
report["status"]=ok ? "INPUT_POSTED":"NO_ACTIONABLE_NATIVE_TARGET";report["endedUptime"]=ProcessInfo.processInfo.systemUptime
save();exit(ok ? 0:3)
