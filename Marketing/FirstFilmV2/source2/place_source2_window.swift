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
func nodes(_ root:AXUIElement)->[AXUIElement]{var result:[AXUIElement]=[];func walk(_ e:AXUIElement,_ d:Int){guard d<15,result.count<1400 else{return};result.append(e);for c in (attr(e,kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(100){walk(c,d+1)}};walk(root,0);return result}
func labels(_ e:AXUIElement)->[String]{[kAXTitleAttribute,kAXDescriptionAttribute,kAXValueAttribute].map{str(e,$0)}.filter{!$0.isEmpty}}
func supportsPress(_ e:AXUIElement)->Bool{var names:CFArray?;return AXUIElementCopyActionNames(e,&names) == .success && ((names as? [String]) ?? []).contains(kAXPressAction)}
// "本地·1" was actually observed in the first take. Re-inspect its native node;
// press only this local-library control, never recommendations or sign-in.
let localNodes=nodes(window).filter{labels($0).contains{label in label == "本地" || label.hasPrefix("本地·") || label == "本地音乐"}}
var action:[String:Any]=["observedMatchingNodes":localNodes.count,"performed":false]
for node in localNodes{
 var target:AXUIElement?=node
 var pressed=false
 for _ in 0..<3{
  guard let e=target else{break}
  if supportsPress(e){let r=AXUIElementPerformAction(e,kAXPressAction as CFString);action=["performed":r == .success,"method":"Freshly observed AXPress","labels":labels(node),"result":r.rawValue];pressed=r == .success;break}
  if let parent=attr(e,kAXParentAttribute){target=parent as! AXUIElement}else{target=nil}
 }
 if !pressed{
  let p=point(node,kAXPositionAttribute),s=size(node)
  if p.count==2,s.count==2,s[0]>4,s[0]<280,s[1]>4,s[1]<80,p[0]>=x,p[0]<x+310,p[1]>y+80,p[1]<y+650{
   let center=CGPoint(x:p[0]+s[0]/2,y:p[1]+s[1]/2)
   CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:center,mouseButton:.left)?.post(tap:.cghidEventTap)
   CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:center,mouseButton:.left)?.post(tap:.cghidEventTap)
   CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:center,mouseButton:.left)?.post(tap:.cghidEventTap)
   action=["performed":true,"method":"Real CGEvent on freshly observed AX element bounds","labels":labels(node),"bounds":p+s];pressed=true
  }
 }
 if pressed{break}
}
RunLoop.current.run(until:Date().addingTimeInterval(1.2))
let afterLabels=nodes(window).flatMap{labels($0)}
let text=afterLabels.joined(separator:"\n")
let localConfirmed=(action["performed"] as? Bool == true) && !text.contains("专属热门节目") && text.contains("Good To Go")
report["localLibraryAction"]=action;report["localLibraryConfirmedFromAX"]=localConfirmed;report["labelsAfterLocalAction"]=afterLabels
CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:CGPoint(x:x-60,y:y+830),mouseButton:.left)?.post(tap:.cghidEventTap)
let ok=actualPos.count==2 && actualSize.count==2 && abs(actualPos[0]-x)<30 && abs(actualPos[1]-y)<30 && actualSize[0]<=1450 && actualSize[1]<=900 && localConfirmed
report["status"]=ok ? "PLACED":"GEOMETRY_NOT_CONFIRMED"
report["uiPixelsModified"]=false
save();exit(ok ? 0:5)
