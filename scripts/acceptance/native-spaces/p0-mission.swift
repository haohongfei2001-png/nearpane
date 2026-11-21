// Fixture setup only. Shares the existing Dock signature, topology and accessibility validators.
import AppKit
import ApplicationServices
import Foundation
#if !PREVIEW_SCOPE_SELECTOR
@main
#endif
enum P0MissionControl {
    struct TileSample {
        let proxy:AXUIElement, owner:pid_t, birth:UInt64?, role:String?, enabled:Bool?, names:[String]
        let actionRead:Bool, parentList:Bool, parentStrip:Bool, parentContainer:Bool, listCount:Int
        let rect:CGRect?, listRect:CGRect, uniqueRect:Bool, hitPoint:CGPoint?
        let chain:[[String:Any]]
        static func geometry(_ element:AXUIElement)->CGRect? {
            let split=frame(element)
            var direct:CGRect?
            if let raw=attr(element,"AXFrame"),CFGetTypeID(raw)==AXValueGetTypeID(),AXValueGetType(raw as! AXValue) == .cgRect {
                var r=CGRect.zero
                if AXValueGetValue(raw as! AXValue,.cgRect,&r),r.width>0,r.height>0 {direct=r}
            }
            if let split,let direct,split != direct {return nil}
            return direct ?? split
        }
        init(_ tiles:P0Tiles,index:Int) throws {
            let tile=tiles.elements[index],pid=tiles.owner.pid
            proxy=tile;owner=pid;birth=operatorBirth(pid);role=attr(tile,kAXRoleAttribute) as? String;enabled=attr(tile,kAXEnabledAttribute) as? Bool
            var actions:CFArray?;actionRead=AXUIElementCopyActionNames(tile,&actions) == .success;names=actions as? [String] ?? []
            let list=tiles.list
            listCount=tiles.elements.count;parentList=belongs(tile,to:list,owner:pid)
            parentStrip=belongs(tile,to:tiles.spaces,owner:pid);parentContainer=belongs(tile,to:tiles.container,owner:pid)
            listRect=tiles.listFrame;let targetRect=Self.geometry(tile);rect=targetRect
            uniqueRect=targetRect.map { r in tiles.listFrame.contains(r) && tiles.elements.compactMap(Self.geometry).filter{$0==r}.count==1 } ?? false
            hitPoint=try? tiles.point(index,fraction:0.5)
            var branch=[[String:Any]](),el:AXUIElement?=tile
            for _ in 0..<12 {
                guard let element=el else {break};var owner:pid_t=0
                guard AXUIElementGetPid(element,&owner) == .success, owner==pid else {break}
                let identifier=attr(element,kAXIdentifierAttribute) as? String ?? ""
                branch.append(["role":attr(element,kAXRoleAttribute) as? String ?? "missing","systemIdentifier":identifier.hasPrefix("mc") ? identifier : ""])
                guard let parent=attr(element,kAXParentAttribute),CFGetTypeID(parent)==AXUIElementGetTypeID() else {break};el=(parent as! AXUIElement)
            }
            chain=branch
        }
        var fields:[String:Any] {
            func box(_ r:CGRect)->[CGFloat] { [r.minX,r.minY,r.width,r.height] }
            return ["role":role as Any? ?? NSNull(),"actions":names,"actionRead":actionRead,"enabled":enabled as Any? ?? NSNull(),
                    "ownerPID":owner,"ownerBirth":birth as Any? ?? NSNull(),"boundToList":parentList,"boundToStrip":parentStrip,"boundToContainer":parentContainer,
                    "parentChain":chain,"listCount":listCount,"rect":rect.map(box) as Any? ?? NSNull(),"listRect":box(listRect),"uniqueTargetRect":uniqueRect,
                    "hitPoint":hitPoint.map {[$0.x,$0.y]} as Any? ?? NSNull()]
        }
    }
    static func select(_ r: WorkspaceRequest, requestedClick:Bool, issued: inout Bool, report: inout [String:Any],
                       allowOriginal:Bool=false, validateOccupancy:((Set<UInt32>?) throws -> [String:Any]?)?=nil) throws {
        guard r.command=="select",let display=UUID(uuidString:r.display),let target=r.target,
              (r.owned.contains(target) || (allowOriginal && target==r.original)),target != r.current,
              let index=r.records.firstIndex(where:{$0.id==target && $0.type==0}),
              r.records.contains(where:{$0.id==r.current && $0.type==0}) else {throw Refusal("enrolled ordinary destination and ordinary setup source required")}
        report["tile"]=["index":index,"id":target,"uuid":r.records[index].uuid,"source":r.current]
        try guardState(r,stage:"before-direct-AX-setup")
        func occupants(_ prior:Set<UInt32>?) throws -> [String:Any]? {
            if let validateOccupancy {return try validateOccupancy(prior)}
            return try requireEmpty(target,host:r.hostPID,beforeOverview:prior)
        }
        _=try occupants(nil)
        let beforeOverview=try publicWindowNumbers()
        if try overviewVisible() {guard try awaitDismissal(of:nil,request:r,timeout:1.5) else {throw Refusal("unowned Mission Control already open")}}
        try guardState(r,stage:"opening-system-overview");try runOverviewLauncher()
        var group:AXUIElement?
        var originalPointer:CGPoint?,clicked:CGPoint?
        defer {
            if let group {finishOverview(group,request:r,proof:&report)}
            if let originalPointer,let clicked,let now=CGEvent(source:nil)?.location,
               hypot(now.x-clicked.x,now.y-clicked.y)<5,hardware()==r.hid {CGWarpMouseCursorPosition(originalPointer)}
        }
        var discovery=[[String:Any]](),consecutiveMissingRoots=0
        let openedBy=try SystemDock.identity()
        func verifiedList(_ stage:String,timeout:Double) throws -> P0Tiles {
            let end=ProcessInfo.processInfo.systemUptime+timeout
            var reason="owned single-display desktop list not ready"
            repeat {
                try guardState(r,stage:stage)
                var details:[String:Any]=["stage":stage,"uptime":ProcessInfo.processInfo.systemUptime]
                do {
                    let root=try overviewGroup()
                    details["dockOverviewExposed"]=root != nil
                    if let root {
                        var owner:pid_t=0
                        try demand(AXUIElementGetPid(root,&owner) == .success && owner==openedBy.pid &&
                                   operatorBirth(owner)==openedBy.birth && attr(root,kAXIdentifierAttribute) as? String=="mc",
                                   "overview is no longer bound to the enrolled signed Dock process")
                        details["dockRootPID"]=owner
                        if let group {details["sameDockProxy"]=CFEqual(root,group)}
                        group=root;consecutiveMissingRoots=0
                    } else if group != nil {
                        consecutiveMissingRoots+=1
                    }
                    let list=try P0Tiles.read(r,display:display,index:index,diagnostics:&details)
                    try demand(root != nil,"signed Dock overview is not exposed")
                    discovery.append(details);report["listDiscovery"]=discovery;return list
                } catch let error as Refusal {reason=error.reason;details["error"]=reason}
                if discovery.count<24 {discovery.append(details)} else {discovery[discovery.count-1]=details}
                report["listDiscovery"]=discovery
                if consecutiveMissingRoots>=2 {throw Refusal("owned system overview disappeared between consecutive reads")}
                usleep(90_000)
            } while ProcessInfo.processInfo.systemUptime<end
            throw Refusal(stage+": "+reason)
        }
        let left=try verifiedList("first-list",timeout:4)
        guard let group else {throw Refusal("no owned signed Dock overview root")}
        try guardState(r,stage:"first-complete-list")
        let a=try TileSample(left,index:index)
        report["tile"]=["index":index,"id":target,"uuid":r.records[index].uuid,"source":r.current,"left":a.fields]
        usleep(110_000)
        let right=try verifiedList("second-list",timeout:3.0),b=try TileSample(right,index:index)
        let sameProxy=CFEqual(a.proxy,b.proxy),sameRect=a.uniqueRect && b.uniqueRect && a.rect==b.rect && a.listRect==b.listRect
        let sameHit=a.hitPoint != nil && a.hitPoint==b.hitPoint && a.listRect==b.listRect
        let sameOwner=a.owner==b.owner && a.birth != nil && a.birth==b.birth
        let dock=try SystemDock.identity()
        try right.owner.verify()
        let trusted=sameOwner && left.owner==right.owner && right.owner.pid==b.owner
        // Tiles proved the ordered full inventory and each button's association with this exact list.
        // Parent chains above the list can be flattened by AX or belong to WindowManager rather than Dock.
        let sameTarget=sameProxy || sameRect || sameHit
        let complete=a.listCount==r.records.count && b.listCount==r.records.count
        let press=a.actionRead && b.actionRead && a.names.contains(kAXPressAction) && b.names.contains(kAXPressAction)
        report["tile"]=["index":index,"id":target,"uuid":r.records[index].uuid,"left":a.fields,"right":b.fields,
                        "equalTargetProxy":sameProxy,"equalUniqueGeometry":sameRect,"equalPositiveHit":sameHit,
                        "sameTarget":sameTarget,"completeList":complete,"sameOwner":sameOwner,"trustedOwner":trusted,"advertisedPress":press,
                        "insideDockRoot":belongs(b.proxy,to:group,owner:b.owner),"dockPID":dock.pid]
        try demand(trusted,"system tile owner changed or lacks the macOS window-manager signature")
        try demand(complete && a.parentList && b.parentList,"the two complete, owner-bound AX space lists disagree")
        try demand(a.role==kAXButtonRole && b.role==kAXButtonRole && a.enabled != false && b.enabled != false,"tile is not a system button or is explicitly disabled")
        try demand(sameTarget,"no stable target proxy, unique geometry, or independent same-point system hit")
        if let transient=try occupants(beforeOverview) {report["overviewComposite"]=transient}
        try guardState(r,stage:"immediately-before-system-input")
        func verifyHeldTile() throws {
            try openedBy.verify();try right.owner.verify()
            try demand(try SystemDock.identity()==openedBy && right.owner.owns(b.proxy),"Dock generation or target AX owner changed before system input")
        }
        try verifyHeldTile()
        if !requestedClick {
            try demand(press,"the two reads did not both advertise AXPress for the owned target")
            report["action"]="AXPress";issued=true;let result=AXUIElementPerformAction(b.proxy,kAXPressAction as CFString)
            report["axError"]=result.rawValue;report["acknowledged"]=result == .success
        } else {
            // Only when no AXPress has been dispatched: native physical click on the actual thumbnail body.
            try demand(CGPreflightPostEventAccess(),"no event access for one system-owned thumbnail click")
            if (try? right.expandedBody(index))==nil {
                let hover=try right.point(index,fraction:0.5)
                try demand(hit(hover,b.proxy,b.owner),"verified native hover point lost")
                originalPointer=CGEvent(source:nil)?.location;clicked=hover
                guard CGWarpMouseCursorPosition(hover) == .success else {throw Refusal("could not hover native thumbnail")}
                try sendMouse(.mouseMoved,hover)
                report["setupHover"]=[hover.x,hover.y]
            }
            var seen:(CGPoint,String,CGRect)?,stable=false,detail="thumbnail body did not settle"
            let until=ProcessInfo.processInfo.systemUptime+2.3
            repeat {
                do {
                    try guardState(r,stage:"native-hover")
                    let updated=try verifiedList("hover-list",timeout:0.5),candidate=try updated.expandedBody(index)
                    try demand(updated.owner.pid==b.owner,"thumbnail owner changed")
                    if let seen,seen.0==candidate.0 && seen.1==candidate.1 && seen.2==candidate.2 {stable=true;break}
                    seen=candidate
                } catch let e as Refusal {detail=e.reason;seen=nil}
                usleep(90_000)
            } while ProcessInfo.processInfo.systemUptime<until
            guard stable,let (point,role,rect)=seen else {throw Refusal(detail)}
            try guardState(r,stage:"before-verified-native-tile-click")
            try verifyHeldTile()
            guard let down=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left),
                  let up=CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left) else {throw Refusal("system tile click unavailable")}
            down.setIntegerValueField(.mouseEventClickState,value:1);up.setIntegerValueField(.mouseEventClickState,value:1)
            report["action"]="native thumbnail click";report["verifiedBody"]=["role":role,"point":[point.x,point.y],"frame":[rect.minX,rect.minY,rect.width,rect.height]]
            if originalPointer==nil {originalPointer=CGEvent(source:nil)?.location};clicked=point
            issued=true;down.post(tap:.cgSessionEventTap);usleep(65_000);up.post(tap:.cgSessionEventTap);report["clickPosted"]=true
        }
        var readings=[[String:Any]]();var streak=0;var last:UInt64?;let end=ProcessInfo.processInfo.systemUptime+4
        repeat {
            let (current,records)=try live(r)
            if current != last {readings.append(["uptime":ProcessInfo.processInfo.systemUptime,"current":current]);last=current;report["observations"]=readings}
            try demand(records==r.records && hardware()==r.hid,"human input or complete native UUID order changed after AXPress")
            try demand(current==r.current || current==target,"a third Space became current after direct native selection")
            streak=current==target ? streak+1:0
            if streak>=3 {break};usleep(80_000)
        } while ProcessInfo.processInfo.systemUptime<end
        report["targetConfirmedBeforeOwnedOverviewClosed"]=streak>=3
    }
    static func main() {
        var out:[String:Any]=["setupOnly":true],issued=false
        do {
            let args=Array(CommandLine.arguments.dropFirst())
            try demand(args.isEmpty || args==["native-click"],"invalid setup input method")
            let r=try JSONDecoder().decode(WorkspaceRequest.self,from:FileHandle.standardInput.readDataToEndOfFile())
            try select(r,requestedClick:!args.isEmpty,issued:&issued,report:&out)
        }
        catch {out["error"]=(error as? Refusal)?.reason ?? String(describing:error)}
        out["issued"]=issued
        print(String(decoding:try! JSONSerialization.data(withJSONObject:out,options:.sortedKeys),as:UTF8.self))
    }
}
