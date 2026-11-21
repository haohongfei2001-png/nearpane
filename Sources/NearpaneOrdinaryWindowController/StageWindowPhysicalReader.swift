import AppKit
import CReadOnlySpaces
import NearpaneCore

/// The helper retains this AX object from its original list. An off-Space owner's AXWindows can be empty;
/// a fresh matching number alone can never recreate the binding. No title or document AX attributes.
enum StageWindowPhysicalReader {
    static func read(_ id: ManagedWindowID, original: AXUIElement, home: OrdinaryDesktopIdentity) throws -> StageWindowPhysicalObservation {
        guard AXIsProcessTrusted(), NPProbeReadOnlyCatalog() == 1, let homeNumber = UInt64(home.record), homeNumber > 0,
              StageManagerPreference.read() == false,
              let inventory = NPReadInventory() as? [[String:Any]],
              OrdinaryDesktopMembership.matches(display:home.display,record:homeNumber,uuid:home.uuid,exclusive:true,
                  inventory:inventory,members:[homeNumber]) else { throw StageSwitchError.unavailable }
        let focus = try FrontFocus()
        var pid: pid_t = 0
        guard AXUIElementGetPid(original,&pid) == .success, pid == id.pid, number(original) == id.number,
              let fields = OrdinaryFocusAttributes(original), let minimized = fields.minimized,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow,id.number) as? [[String:Any]], rows.count == 1,
              let row = rows.first, row[kCGWindowNumber as String] as? UInt32 == id.number, row[kCGWindowOwnerPID as String] as? Int32 == id.pid,
              row[kCGWindowLayer as String] as? Int == 0,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary, let cg = CGRect(dictionaryRepresentation:bounds),
              cg.width > 0, cg.height > 0, [cg.minX,cg.minY,cg.width,cg.height].allSatisfy(\.isFinite),
              cg == fields.frame, let forward = NPReadWindowSpaces(id.number) as? [UInt64], forward.count == 1,
              let member = forward.first, member > 0, let reverse = NPReadCatalogSpaceWindowNumbers(member) as? [UInt32],
              reverse.filter({ $0 == id.number }).count == 1 else { throw StageSwitchError.incomplete }
        if member != homeNumber {
            guard let atHome = NPReadCatalogSpaceWindowNumbers(homeNumber) as? [UInt32], !atHome.contains(id.number) else {
                throw StageSwitchError.incomplete
            }
        }
        // kCGWindowIsOnscreen is optional in window dictionaries. Missing is ambiguous for background members.
        var enrolled = id.number
        guard let visible = NPReadVisibleWindowDescriptions(&enrolled,1) as? [[String:Any]], visible.count <= 1,
              visible.allSatisfy({ $0[kCGWindowNumber as String] as? UInt32 == id.number && $0[kCGWindowOwnerPID as String] as? Int32 == id.pid }) else {
            throw StageSwitchError.incomplete
        }
        let showing = visible.count == 1
        guard (row[kCGWindowIsOnscreen as String] as? Bool).map({ $0 == showing }) != false else { throw StageSwitchError.interrupted }
        if member == homeNumber, showing && !minimized {
            let candidates = try windows(id.pid).filter { number($0) == id.number }
            guard candidates.count == 1, CFEqual(candidates[0],original) else { throw StageSwitchError.ownership }
        }
        let focused: NativeSpaceWindow?
        if let element = focus.element {
            var receiver: pid_t = 0
            guard AXUIElementGetPid(element,&receiver) == .success, receiver == focus.pid, let n = number(element),
                  let birth = try? OrdinaryProcessImage.read(receiver).launch else { throw StageSwitchError.incomplete }
            focused = .init(pid:receiver,birth:birth,number:n)
            if receiver == id.pid, n == id.number, !CFEqual(element,original) { throw StageSwitchError.ownership }
        } else { focused = nil }
        try focus.check()
        guard number(original) == id.number, NPReadWindowSpaces(id.number) as? [UInt64] == forward,
              NPReadInventory() as? NSArray == inventory as NSArray, StageManagerPreference.read() == false else {
            throw StageSwitchError.interrupted
        }
        return .init(id:id,frame:.init(x:cg.minX,y:cg.minY,width:cg.width,height:cg.height),membership:member,
                     onscreen:showing,minimized:minimized,focus:focused)
    }
}
