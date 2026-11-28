import AppKit
import ApplicationServices
import Foundation

let args=CommandLine.arguments
guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true", args.count == 7,
      let x=Double(args[2]), let y=Double(args[3]), let w=Double(args[4]), let h=Double(args[5]) else { exit(2) }
let bundle=args[1], output=URL(fileURLWithPath:args[6])
var report:[String:Any]=["bundleID":bundle,"AXAlreadyTrusted":AXIsProcessTrusted(),"requestedPosition":[x,y],"requestedSize":[w,h],"accountUsed":false,"newPermissionRequested":false]
func save(){if let d=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]){try? d.write(to:output,options:.atomic)}}
func attr(_ e:AXUIElement,_ key:String)->CFTypeRef?{var v:CFTypeRef?;return AXUIElementCopyAttributeValue(e,key as CFString,&v) == .success ? v:nil}
func str(_ e:AXUIElement,_ key:String)->String{attr(e,key) as? String ?? ""}
func point(_ e:AXUIElement,_ key:String)->[Double]{guard let v=attr(e,key),CFGetTypeID(v)==AXValueGetTypeID() else{return []};var p=CGPoint.zero;return AXValueGetValue(v as! AXValue,.cgPoint,&p) ? [p.x,p.y]:[]}
func size(_ e:AXUIElement)->[Double]{guard let v=attr(e,kAXSizeAttribute),CFGetTypeID(v)==AXValueGetTypeID() else{return []};var s=CGSize.zero;return AXValueGetValue(v as! AXValue,.cgSize,&s) ? [s.width,s.height]:[]}
guard AXIsProcessTrusted(),let app=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first else{report["status"]="BLOCKED";report["reason"]="Actual client or existing AX permission unavailable";save();exit(3)}
let root=AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root,0.4)
let windows=attr(root,kAXWindowsAttribute) as? [AXUIElement] ?? []
var inventory:[[String:Any]]=[]
for win in windows{
 var labels:[String]=[]
 func visit(_ e:AXUIElement,_ depth:Int){guard depth<12,labels.count<220 else{return};for k in [kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute]{let v=str(e,k);if !v.isEmpty{labels.append(String(v.prefix(300)))}};for child in (attr(e,kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(60){visit(child,depth+1)}}
 visit(win,0)
 inventory.append(["title":str(win,kAXTitleAttribute),"role":str(win,kAXRoleAttribute),"subrole":str(win,kAXSubroleAttribute),"position":point(win,kAXPositionAttribute),"size":size(win),"observedLabels":labels])
}
report["windowsBefore"]=inventory
let choices=windows.filter{let s=size($0);return s.count==2 && s[0]>=600 && s[1]>=360}
guard let window=choices.max(by:{let a=size($0),b=size($1);return a[0]*a[1]<b[0]*b[1]}) else{report["status"]="BLOCKED";report["reason"]="No actual main client window of useful size";save();exit(4)}
app.activate(options:[.activateAllWindows])
var pos=CGPoint(x:x,y:y),sz=CGSize(width:w,height:h)
let setSize=AXUIElementSetAttributeValue(window,kAXSizeAttribute as CFString,AXValueCreate(.cgSize,&sz)!)
let setPos=AXUIElementSetAttributeValue(window,kAXPositionAttribute as CFString,AXValueCreate(.cgPoint,&pos)!)
_ = AXUIElementPerformAction(window,kAXRaiseAction as CFString)
RunLoop.current.run(until:Date().addingTimeInterval(0.6))
let actualPos=point(window,kAXPositionAttribute),actualSize=size(window)
report["setPositionResult"]=setPos.rawValue;report["setSizeResult"]=setSize.rawValue
report["actualPosition"]=actualPos;report["actualSize"]=actualSize
report["selectedTitle"]=str(window,kAXTitleAttribute)
let ok=actualPos.count==2 && actualSize.count==2 && abs(actualPos[0]-x)<30 && abs(actualPos[1]-y)<30 && actualSize[0]<=1450 && actualSize[1]<=900
report["status"]=ok ? "PLACED":"GEOMETRY_NOT_CONFIRMED"
report["uiPixelsModified"]=false
save();exit(ok ? 0:5)
