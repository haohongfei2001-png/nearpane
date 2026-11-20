// Fixture setup only. Shares the existing Dock signature, topology and accessibility validators.
import AppKit
import ApplicationServices
import Foundation
@main enum P0MissionControl {
    static func select(_ r: WorkspaceRequest, issued: inout Bool, report: inout [String:Any]) throws {
        guard r.command=="select",let display=UUID(uuidString:r.display),let target=r.target,
              r.owned.contains(target),target != r.current,
              let index=r.records.firstIndex(where:{$0.id==target && $0.type==0}),
              r.records.contains(where:{$0.id==r.current && $0.type==0}) else {throw Refusal("enrolled ordinary destination and ordinary setup source required")}
        try guardState(r,stage:"before-direct-AX-setup")
        _=try requireEmpty(target,host:r.hostPID)
        let beforeOverview=try publicWindowNumbers()
        if try overviewVisible() {guard try awaitDismissal(of:nil,request:r,timeout:1.5) else {throw Refusal("unowned Mission Control already open")}}
        try guardState(r,stage:"opening-system-overview");try runOverviewLauncher()
        var group:AXUIElement?
        defer { if let group {finishOverview(group,request:r,proof:&report)} }
        let deadline=ProcessInfo.processInfo.systemUptime+4
        var tiles:Tiles?, detail="system space list not exposed"
        repeat {
            do {group=try overviewGroup();guard group != nil else {throw Refusal("signed Dock overview not ready")};tiles=try Tiles(r,display);break}
            catch let e as Refusal {detail=e.reason};usleep(80_000)
        } while ProcessInfo.processInfo.systemUptime<deadline
        guard let left=tiles,let group else {throw Refusal(detail)}
        try guardState(r,stage:"first-complete-list")
        let right=try Tiles(r,display),node=right.elements[index];var actions:CFArray?
        guard left.bar.owner.processIdentifier==right.bar.owner.processIdentifier,CFEqual(left.bar.add,right.bar.add),
              left.elements.count==right.elements.count,zip(left.elements,right.elements).allSatisfy({CFEqual($0,$1)}),
              belongs(node,to:group,owner:right.bar.owner.processIdentifier),attr(node,kAXRoleAttribute) as? String==kAXButtonRole,
              attr(node,kAXEnabledAttribute) as? Bool==true,AXUIElementCopyActionNames(node,&actions) == .success,
              let names=actions as? [String],names.contains(kAXPressAction),names.contains("AXRemoveDesktop") else {throw Refusal("the same removable ordinary Dock AX button was not confirmed twice")}
        report["action"]="AXPress";report["dockPID"]=right.bar.owner.processIdentifier
        report["tile"]=["index":index,"id":target,"uuid":r.records[index].uuid,"count":right.elements.count,"ordinaryRemovalAdvertised":true]
        if let transient=try requireEmpty(target,host:r.hostPID,beforeOverview:beforeOverview) {report["overviewComposite"]=transient}
        try guardState(r,stage:"immediately-before-AXPress")
        issued=true;let result=AXUIElementPerformAction(node,kAXPressAction as CFString)
        report["axError"]=result.rawValue;report["acknowledged"]=result == .success
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
        do {let r=try JSONDecoder().decode(WorkspaceRequest.self,from:FileHandle.standardInput.readDataToEndOfFile());try select(r,issued:&issued,report:&out)}
        catch {out["error"]=(error as? Refusal)?.reason ?? String(describing:error)}
        out["issued"]=issued
        print(String(decoding:try! JSONSerialization.data(withJSONObject:out,options:.sortedKeys),as:UTF8.self))
    }
}
