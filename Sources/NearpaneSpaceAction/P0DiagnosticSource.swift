#if NEARPANE_P0_DIAGNOSTIC
import AppKit
import CReadOnlySpaces
import NearpaneCore

/// WindowServer membership in both directions and the actual system-wide focused source
/// are independently bound immediately before the ordinary posting implementation.
@MainActor func verifyDiagnosticSource(_ grant: P0DiagnosticGrant, inventory: ActionInventory) throws -> Bool {
    guard inventory.displays.count == 1, let display = inventory.displays[grant.topology.display],
          display.current == String(grant.topology.current), display.spaces.count == grant.topology.records.count,
          zip(display.spaces,grant.topology.records).allSatisfy({ $0.id == String($1.id) && $0.uuid == $1.uuid && $0.kind?.rawValue == $1.type }),
          try ActionInventory.read() == inventory else { return false }
    for (window, place) in [(grant.sourceWindow,grant.topology.current),(grant.targetWindow,grant.target)] {
        guard let reverse = NPReadWindowSpaces(window.number) as? [NSNumber], reverse.map(\.uint64Value) == [place],
              let forward = ActionInventory.memberNumbers(in:String(place)), forward.contains(window.number)
        else { return false }
    }
    let system = AXUIElementCreateSystemWide()
    var app: CFTypeRef?, window: CFTypeRef?, owner: pid_t = 0
    guard AXUIElementCopyAttributeValue(system,kAXFocusedApplicationAttribute as CFString,&app) == .success,
          let app, CFGetTypeID(app) == AXUIElementGetTypeID() else { return false }
    let application = unsafeDowncast(app,to:AXUIElement.self)
    return AXUIElementGetPid(application,&owner) == .success && owner == grant.sourceWindow.pid &&
        AXUIElementCopyAttributeValue(application,kAXFocusedWindowAttribute as CFString,&window) == .success &&
        window.map { CFGetTypeID($0) == AXUIElementGetTypeID() && NPReadAXWindowNumber($0) == grant.sourceWindow.number } == true
}
#endif
