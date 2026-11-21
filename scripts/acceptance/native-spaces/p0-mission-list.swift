// Read only the signed macOS overview's desktop list on the enrolled physical display.
// Private window titles, descriptions and application AX trees are never queried.
import AppKit
import ApplicationServices
import Security

struct P0Tiles {
    let owner:OverviewProcess
    let container,spaces,list:AXUIElement
    let elements:[AXUIElement]
    let listFrame:CGRect

    private static func ownerPID(_ el:AXUIElement)->pid_t {
        var pid:pid_t=0
        return AXUIElementGetPid(el,&pid) == .success ? pid : 0
    }
    private static func childRecords(_ el:AXUIElement,_ name:String)->[AXUIElement] {
        (try? children(el,named:name)) ?? []
    }
    private static func box(_ frame:CGRect)->[CGFloat] {[frame.minX,frame.minY,frame.width,frame.height]}
    static func read(_ request:WorkspaceRequest,display:UUID,index:Int,diagnostics:inout [String:Any]) throws -> Self {
        var n:UInt32=0,physical=CGDirectDisplayID(),online:UInt32=0
        guard CGGetOnlineDisplayList(0,nil,&online) == .success,online==1,CGGetActiveDisplayList(0,nil,&n) == .success,n==1,
              CGGetActiveDisplayList(1,&physical,&n) == .success,n==1,CGDisplayIsInMirrorSet(physical)==0,
              let id=CGDisplayCreateUUIDFromDisplayID(physical)?.takeRetainedValue(),UUID(uuidString:CFUUIDCreateString(nil,id) as String)==display else {
            throw Refusal("requested physical display is no longer the one active unmirrored display")
        }
        let bounds=CGDisplayBounds(physical),owners=try OverviewProcess.owners(dock:SystemDock.identity())
        diagnostics["physicalDisplay"]=physical;diagnostics["bounds"]=box(bounds);diagnostics["expectedTiles"]=request.records.count
        var candidates=[Self](),sourceDiagnostics=[[String:Any]]()
        for owner in owners {
            let root=AXUIElementCreateApplication(owner.pid);AXUIElementSetMessagingTimeout(root,0.24)
            let groups=childRecords(root,"mc")
            var containers=Set<AXUIElement>(childRecords(root,"mc.display"))
            for g in groups {containers.formUnion(childRecords(g,"mc.display"))}
            // WindowManager can temporarily omit its display from the application's AXChildren while rebuilding the menu strip.
            // A real hit is read only. It contributes a container only if its signed ancestry reaches the system's mc.display.
            var hitContainers=0
            for x in [0.16,0.5,0.84] {
                var node:AXUIElement?
                guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),Float(bounds.minX+bounds.width*x),Float(bounds.minY+35),&node) == .success else {continue}
                for _ in 0..<10 {
                    guard let el=node,ownerPID(el)==owner.pid else {break}
                    if attr(el,kAXIdentifierAttribute) as? String=="mc.display" {containers.insert(el);hitContainers+=1;break}
                    guard let next=attr(el,kAXParentAttribute),CFGetTypeID(next)==AXUIElementGetTypeID() else {break}
                    node=(next as! AXUIElement)
                }
            }
            var seen=[[String:Any]]()
            for container in containers {
                let cid=(attr(container,"AXDisplayID") as? NSNumber)?.uint32Value,rect=P0MissionControl.TileSample.geometry(container)
                let displayMatch=(cid==nil || cid==physical) && rect==bounds
                let strips=childRecords(container,"mc.spaces")
                var shape:[String:Any]=["displayID":cid as Any? ?? NSNull(),"containerOwnerPID":ownerPID(container),
                                       "containerFrame":rect.map(box) as Any? ?? NSNull(),"physicalMatch":displayMatch,"stripCount":strips.count]
                var listCount=0,counts=[Int](),orderChecks=[Bool](),listOwners=[pid_t]()
                for strip in strips {
                    for list in childRecords(strip,"mc.spaces.list") {
                        listCount+=1;listOwners.append(ownerPID(list))
                        guard let items=attr(list,kAXChildrenAttribute) as? [AXUIElement],items.count<=256 else {counts.append(-1);continue}
                        counts.append(items.count)
                        let frames=items.compactMap(P0MissionControl.TileSample.geometry)
                        let distinctGeometry=frames.count==items.count && Set(frames.map(\.midX)).count==frames.count
                        let reversed=distinctGeometry && !zip(frames,frames.dropFirst()).allSatisfy{$0.midX<$1.midX}
                        guard displayMatch,ownerPID(container)==owner.pid,ownerPID(strip)==owner.pid,ownerPID(list)==owner.pid,
                              let visible=P0MissionControl.TileSample.geometry(list),bounds.contains(visible),
                              items.count==request.records.count,items.indices.contains(index),Set(items).count==items.count,!reversed,
                              items.allSatisfy({ownerPID($0)==owner.pid && attr($0,kAXRoleAttribute) as? String==kAXButtonRole && belongs($0,to:list,owner:owner.pid)}) else {continue}
                        let candidate=Self(owner:owner,container:container,spaces:strip,list:list,elements:items,listFrame:visible)
                        var order=distinctGeometry
                        if !order {
                            let actual=items.indices.compactMap{try? candidate.point($0,fraction:0.5)}
                            order=actual.count==items.count && zip(actual,actual.dropFirst()).allSatisfy{$0.x<$1.x}
                        }
                        orderChecks.append(order)
                        if order && !candidates.contains(where:{$0.owner==owner && CFEqual($0.list,list)}) {candidates.append(candidate)}
                    }
                }
                shape["listCount"]=listCount;shape["tileCounts"]=counts;shape["horizontalOrderChecks"]=orderChecks;shape["listOwnerPIDs"]=listOwners;seen.append(shape)
            }
            sourceDiagnostics.append(["owner":owner.identifier,"pid":owner.pid,"birth":owner.birth,"signed":true,"mcRoots":groups.count,
                                      "containerCount":containers.count,"hitContainerRefs":hitContainers,"containers":seen])
        }
        diagnostics["ownerReads"]=sourceDiagnostics;diagnostics["validLists"]=candidates.count
        if candidates.count>1 {
            // Duplicate semantic proxies are admissible only if ONE owner-bound ordered list receives the exact desktop body hit.
            let positive=candidates.filter{(try? $0.point(index,fraction:0.5)) != nil}
            diagnostics["positiveTargetHitLists"]=positive.count
            if positive.count==1 {return positive[0]}
            // Two independent root traversals sometimes produce different AX proxies for the very same list.
            if let first=positive.first, let hit=try? first.point(index,fraction:0.5),
               positive.allSatisfy({ $0.owner==first.owner && $0.listFrame==first.listFrame && $0.elements.count==first.elements.count &&
                                    (try? $0.point(index,fraction:0.5))==hit && CFEqual($0.elements[index],first.elements[index]) }) {
                diagnostics["duplicateReferencesToOneTarget"]=true;return first
            }
        }
        guard candidates.count==1 else {throw Refusal("signed single-display system desktop list count \(candidates.count)")}
        return candidates[0]
    }
    func point(_ index:Int,fraction:CGFloat)throws->CGPoint {
        let tile=elements[index]
        if let rect=P0MissionControl.TileSample.geometry(tile) {
            let visible=rect.intersection(listFrame)
            if !visible.isNull && !visible.isEmpty {
                for y in [0.50,0.68,0.31] {
                    let p=CGPoint(x:visible.minX+visible.width*fraction,y:visible.minY+visible.height*y)
                    if hit(p,tile,owner.pid) {return p}
                }
            }
        }
        let points=stride(from:listFrame.minX+3,through:listFrame.maxX-3,by:8).map{CGPoint(x:$0,y:listFrame.midY)}.filter{hit($0,tile,owner.pid)}
        guard !points.isEmpty else {throw Refusal("no actual system hit bound to this ordered desktop tile")}
        return points[Int(CGFloat(points.count-1)*fraction)]
    }
    func expandedBody(_ index:Int)throws->(CGPoint,String,CGRect) {
        guard listFrame.height>=48 else {throw Refusal("native desktop strip has not expanded")}
        let tile=elements[index], area=P0MissionControl.TileSample.geometry(tile)?.intersection(listFrame) ?? listFrame
        guard !area.isEmpty, !area.isNull,area.width>=40,area.height>=36 else {throw Refusal("native target body has no positive geometry")}
        let center=try point(index,fraction:0.5)
        for vertical in [0.54,0.62,0.46] {
            let p=CGPoint(x:center.x,y:area.minY+area.height*vertical),other=CGPoint(x:center.x,y:area.minY+area.height*vertical+10)
            if area.contains(other),let role=tileBodyRole(p,tile:tile,owner:owner.pid),tileBodyRole(other,tile:tile,owner:owner.pid) != nil {return(p,role,area)}
        }
        throw Refusal("system hit-test did not identify the target's desktop button or image at two body points")
    }
}
