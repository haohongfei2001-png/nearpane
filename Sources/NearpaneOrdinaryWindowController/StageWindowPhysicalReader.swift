import AppKit
import CReadOnlySpaces
import NearpaneCore

/// The helper retains this AX object from its original list. An off-Space owner's AXWindows can be empty;
/// a fresh matching number alone can never recreate the binding. No title or document AX attributes.
/// This witness includes classic hidden Spaces (mask 15); the ordinary catalogue
/// intentionally keeps its separate managed-only membership view (mask 7).
enum StageWindowPhysicalReader {
    struct InventoryDifference {
        let paths: [String]
        let truncated: Bool
        let inspected: Int
    }

    /// Failure diagnostics for two already-read inventories. No native reads,
    /// values, titles or document contents leave this bounded in-memory walk.
    static func inventoryDifference(_ opening: NSArray, _ closing: NSArray) -> InventoryDifference {
        var paths = [String](), truncated = false, inspected = 0
        func note(_ path: String) { paths.append(path) }
        func visit(_ before: Any?, _ after: Any?, path: String, depth: Int) {
            guard paths.count < 12, inspected < 256, depth <= 8 else { truncated = true; return }
            inspected += 1
            guard let before, let after else { note(path); return }
            if let a = before as? NSArray {
                guard let b = after as? NSArray else { note(path); return }
                if a.count != b.count { note(path + ".count") }
                guard depth < 8 || min(a.count, b.count) == 0 else { truncated = true; return }
                for index in 0..<min(a.count, b.count) {
                    guard paths.count < 12, inspected < 256 else { truncated = true; break }
                    visit(a[index], b[index], path: path + "[\(index)]", depth: depth + 1)
                }
                return
            }
            if after is NSArray { note(path); return }
            if let a = before as? NSDictionary {
                guard let b = after as? NSDictionary else { note(path); return }
                guard depth < 8 || (a.count == 0 && b.count == 0) else { truncated = true; return }
                guard a.count <= 256, b.count <= 256 else { truncated = true; return }
                guard let aKeys = a.allKeys as? [String], let bKeys = b.allKeys as? [String] else {
                    note(path + ".<key-type>"); return
                }
                for key in Set(aKeys).union(bKeys).sorted() {
                    guard paths.count < 12, inspected < 256 else { truncated = true; break }
                    // Native field names are short ASCII constants. Redact other
                    // keys without ever formatting a value into a path.
                    let safe = key.utf8.prefix(65).count <= 64 && key.utf8.allSatisfy {
                        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                        $0 == 32 || $0 == 45 || $0 == 95
                    }
                    visit(a[key], b[key], path: path + "." + (safe ? key : "<key>"), depth: depth + 1)
                }
                return
            }
            if after is NSDictionary { note(path); return }
            guard let a = before as? NSObject, let b = after as? NSObject else { note(path); return }
            if !a.isEqual(b) { note(path) }
        }
        visit(opening, closing, path: "$", depth: 0)
        return .init(paths: paths, truncated: truncated, inspected: inspected)
    }

    /// A managed-display roster omits classic hidden Spaces. Use the complete
    /// positive all-Space list, then an actual empty member read for any surviving
    /// former ID. Neither nil nor a missing managed row establishes destruction.
    static func hiddenSpacesReleased(_ hidden: [UInt64]) -> Bool {
        guard hidden.count <= 64, hidden.allSatisfy({ $0 > 0 }),
              NPProbeReadOnlyCatalog() == 1,
              let all = NPReadAllSpaceNumbers() as? [UInt64], !all.isEmpty,
              let managed = NPReadInventory() as? [[String: Any]], !managed.isEmpty else { return false }
        let present = Set(all)
        for display in managed {
            guard let spaces = display["Spaces"] as? [[String: Any]], !spaces.isEmpty else { return false }
            for space in spaces {
                guard let id = space["id64"] as? UInt64, id > 0, present.contains(id) else { return false }
            }
        }
        return hiddenSpacesReleased(hidden, inventory: all) { NPReadCatalogSpaceWindowNumbers($0) as? [UInt32] }
    }

    static func hiddenSpacesReleased(_ hidden: [UInt64], inventory: [UInt64]?,
                                    occupants: (UInt64) -> [UInt32]?) -> Bool {
        guard let inventory, !inventory.isEmpty, inventory.count <= 2048,
              inventory.allSatisfy({ $0 > 0 }), hidden.count <= 64, hidden.allSatisfy({ $0 > 0 }) else { return false }
        return hidden.allSatisfy { id in
            if !inventory.contains(id) { return true }
            guard let members = occupants(id) else { return false }
            return members.isEmpty
        }
    }

    /// Unlike admission and normal switching, this read does not require the home desktop to
    /// be current. It observes only the retained AX window and the real Space membership.
    static func returnedHome(_ id: ManagedWindowID, original: AXUIElement, home: OrdinaryDesktopIdentity,
                             frame: SurfaceRect, allowMinimized: Bool, retainedStandardWindow: Bool = false) throws -> Bool {
        guard AXIsProcessTrusted(), NPProbeReadOnlyCatalog() == 1, let homeNumber = UInt64(home.record), homeNumber > 0 else {
            throw StageSwitchError.unavailable
        }
        func read() -> Bool {
            var pid: pid_t = 0
            guard AXUIElementGetPid(original, &pid) == .success, pid == id.pid, number(original) == id.number,
                  let fields = OrdinaryFocusAttributes(original, retainedStandardWindow: retainedStandardWindow),
                  let inventory = NPReadInventory() as? [[String: Any]],
                  let forward = NPReadWindowSpacesIncludingHidden(id.number) as? [UInt64],
                  let reverse = NPReadCatalogSpaceWindowNumbers(homeNumber) as? [UInt32],
                  let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id.number) as? [[String: Any]],
                  rows.count == 1, let row = rows.first else { return false }
            return returnedHomeMatches(id, home: home, expected: frame, frame: fields.frame, minimized: fields.minimized,
                allowMinimized: allowMinimized, inventory: inventory, forward: forward, reverse: reverse, window: row)
        }
        // The two independent samples also reject a Space deletion or membership change
        // during the read. Neither sample changes focus, desktop, window order or geometry.
        return read() && read()
    }

    static func returnedHomeMatches(_ id: ManagedWindowID, home: OrdinaryDesktopIdentity, expected: SurfaceRect,
                                    frame: CGRect, minimized: Bool?, allowMinimized: Bool = false,
                                    inventory: [[String: Any]], forward: [UInt64], reverse: [UInt32],
                                    window: [String: Any]) -> Bool {
        guard let record = UInt64(home.record),
              OrdinaryDesktopMembership.restored(display: home.display, record: record, uuid: home.uuid,
                  inventory: inventory, members: forward),
              reverse.filter({ $0 == id.number }).count == 1,
              window[kCGWindowNumber as String] as? UInt32 == id.number,
              window[kCGWindowOwnerPID as String] as? Int32 == id.pid,
              window[kCGWindowLayer as String] as? Int == 0,
              minimized == false || (allowMinimized && minimized == true),
              frame.width > 0, frame.height > 0, [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame == CGRect(x: expected.x, y: expected.y, width: expected.width, height: expected.height) else { return false }
        // Mission Control may transform CG bounds. The original AX frame is the layout
        // being restored; visibility and transformed screen geometry are not its identity.
        return true
    }

    static func read(_ id: ManagedWindowID, original: AXUIElement, home: OrdinaryDesktopIdentity,
                     retainedStandardWindow: Bool = false) throws -> StageWindowPhysicalObservation {
        var step = "environment", completed = false, frontPID: pid_t = 0
        var frontNumber: UInt32 = 0, frontHasElement = false, frontNumberReadAttempted = false
        var diagnosticFocus: AXUIElement?
        var finalNumber: UInt32?, finalNumberMatches: Bool?
        var finalForward: [UInt64]?, finalForwardMatches: Bool?
        var finalInventory: NSArray?, finalInventoryMatches: Bool?
        var rejectedInventory: (NSArray, NSArray)?
        var finalStageManager: Bool?, finalStageManagerAttempted = false
        defer {
            if !completed, ProcessInfo.processInfo.environment["NP_SPACES_LAUNCH_TRACE"] != nil {
                var event: [String: Any] = ["event": "stagePhysicalReadRejected", "step": step,
                    "pid": id.pid, "window": id.number, "frontPID": frontPID,
                    "frontWindow": frontNumber, "frontHasElement": frontHasElement,
                    "frontNumberReadAttempted": frontNumberReadAttempted,
                    "uptime": ProcessInfo.processInfo.systemUptime]
                event["finalOriginalNumberMatches"] = finalNumberMatches.map { $0 as Any } ?? "NOT_RUN"
                if finalNumberMatches != nil { event["finalOriginalNumber"] = finalNumber.map { $0 as Any } ?? NSNull() }
                event["finalForwardMatches"] = finalForwardMatches.map { $0 as Any } ?? "NOT_RUN"
                if finalForwardMatches != nil {
                    event["finalForwardReadable"] = finalForward != nil
                    event["finalForwardCount"] = finalForward.map { $0.count as Any } ?? NSNull()
                }
                event["finalInventoryMatches"] = finalInventoryMatches.map { $0 as Any } ?? "NOT_RUN"
                if finalInventoryMatches != nil {
                    event["finalInventoryReadable"] = finalInventory != nil
                    event["finalInventoryDisplayCount"] = finalInventory.map { $0.count as Any } ?? NSNull()
                }
                if let (before, after) = rejectedInventory {
                    let difference = inventoryDifference(before, after)
                    event["inventoryDifferencePaths"] = difference.paths
                    event["inventoryDifferenceTruncated"] = difference.truncated
                    event["inventoryDifferenceInspected"] = difference.inspected
                }
                event["finalStageManager"] = finalStageManagerAttempted ?
                    finalStageManager.map { $0 ? "on" : "off" } ?? "unavailable" : "NOT_RUN"
                // These are additional read-only failure diagnostics, not the
                // observations that authorized a window action. Never read titles.
                if let diagnosticFocus {
                    for (name, key) in [("role", kAXRoleAttribute), ("subrole", kAXSubroleAttribute)] {
                        var value: CFTypeRef?
                        let error = AXUIElementCopyAttributeValue(diagnosticFocus, key as CFString, &value)
                        let text = value as? String
                        event["focusDiagnostic" + name + "Error"] = error.rawValue
                        event["focusDiagnostic" + name] = text.map { $0.hasPrefix("AX") && $0.count <= 64 ? $0 : "nonconstant" } ?? "unavailable"
                    }
                    var value: CFTypeRef?
                    let error = AXUIElementCopyAttributeValue(diagnosticFocus, "AXWindowNumber" as CFString, &value)
                    event["focusDiagnosticNumberAttributeError"] = error.rawValue
                    if let value = value as? NSNumber { event["focusDiagnosticNumberAttribute"] = value }
                    else { event["focusDiagnosticNumberAttribute"] = NSNull() }
                }
                if var data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) {
                    data.append(0x0a); try? FileHandle.standardError.write(contentsOf: data)
                }
            }
        }
        guard AXIsProcessTrusted(), NPProbeReadOnlyCatalog() == 1, let homeNumber = UInt64(home.record), homeNumber > 0,
              StageManagerPreference.read() == false,
              let inventory = NPReadInventory() as? [[String:Any]],
              OrdinaryDesktopMembership.matches(display:home.display,record:homeNumber,uuid:home.uuid,exclusive:true,
                  inventory:inventory,members:[homeNumber]) else { throw StageSwitchError.unavailable }
        step = "front-focus"
        let focus = try FrontFocus()
        frontPID = focus.pid; frontHasElement = focus.element != nil; diagnosticFocus = focus.element
        var pid: pid_t = 0
        step = "original-ax-attributes"
        guard AXUIElementGetPid(original,&pid) == .success, pid == id.pid, number(original) == id.number,
              let fields = OrdinaryFocusAttributes(original, retainedStandardWindow: retainedStandardWindow),
              let minimized = fields.minimized else { throw StageSwitchError.incomplete }
        step = "cg-identity-and-geometry"
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow,id.number) as? [[String:Any]], rows.count == 1,
              let row = rows.first, row[kCGWindowNumber as String] as? UInt32 == id.number, row[kCGWindowOwnerPID as String] as? Int32 == id.pid,
              row[kCGWindowLayer as String] as? Int == 0,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary, let cg = CGRect(dictionaryRepresentation:bounds),
              cg.width > 0, cg.height > 0, [cg.minX,cg.minY,cg.width,cg.height].allSatisfy(\.isFinite),
              cg == fields.frame else { throw StageSwitchError.incomplete }
        step = "bidirectional-membership"
        guard let forward = NPReadWindowSpacesIncludingHidden(id.number) as? [UInt64], forward.count == 1,
              let member = forward.first, member > 0, let reverse = NPReadCatalogSpaceWindowNumbers(member) as? [UInt32],
              reverse.filter({ $0 == id.number }).count == 1 else { throw StageSwitchError.incomplete }
        if member != homeNumber {
            guard let atHome = NPReadCatalogSpaceWindowNumbers(homeNumber) as? [UInt32], !atHome.contains(id.number) else {
                throw StageSwitchError.incomplete
            }
        }
        // kCGWindowIsOnscreen is optional in window dictionaries. Missing is ambiguous for background members.
        step = "onscreen-observation"
        var enrolled = id.number
        guard let visible = NPReadVisibleWindowDescriptions(&enrolled,1) as? [[String:Any]], visible.count <= 1,
              visible.allSatisfy({ $0[kCGWindowNumber as String] as? UInt32 == id.number && $0[kCGWindowOwnerPID as String] as? Int32 == id.pid }) else {
            throw StageSwitchError.incomplete
        }
        let showing = visible.count == 1
        guard (row[kCGWindowIsOnscreen as String] as? Bool).map({ $0 == showing }) != false else { throw StageSwitchError.interrupted }
        if member == homeNumber, showing && !minimized {
            step = "original-ax-list-membership"
            let candidates = try windows(id.pid).filter { number($0) == id.number }
            guard candidates.count == 1, CFEqual(candidates[0],original) else { throw StageSwitchError.ownership }
        }
        let focused: NativeSpaceWindow?
        var desktopFocus = false
        step = "focused-window-identity"
        if let element = focus.element {
            var receiver: pid_t = 0
            let n = number(element); frontNumber = n ?? 0; frontNumberReadAttempted = true
            guard AXUIElementGetPid(element,&receiver) == .success, receiver == focus.pid else { throw StageSwitchError.incomplete }
            if let n {
                guard let birth = try? OrdinaryProcessImage.read(receiver).launch else { throw StageSwitchError.incomplete }
                focused = .init(pid:receiver,birth:birth,number:n)
                if receiver == id.pid, n == id.number, !CFEqual(element,original) { throw StageSwitchError.ownership }
            } else {
                guard focus.isFinderDesktop() else { throw StageSwitchError.incomplete }
                desktopFocus = true; focused = nil
            }
        } else { focused = nil }
        step = "final-focus-continuity"
        try focus.check()
        step = "final-desktop-focus"
        guard !desktopFocus || focus.isFinderDesktop() else { throw StageSwitchError.interrupted }
        // Retain the original order and short circuit: each authoritative read
        // runs once, and later checks remain NOT_RUN after an earlier rejection.
        step = "final-original-number"
        finalNumber = number(original); finalNumberMatches = finalNumber == id.number
        guard finalNumberMatches == true else { throw StageSwitchError.interrupted }
        step = "final-membership"
        finalForward = NPReadWindowSpacesIncludingHidden(id.number) as? [UInt64]
        finalForwardMatches = finalForward == forward
        guard finalForwardMatches == true else { throw StageSwitchError.interrupted }
        step = "final-inventory"
        finalInventory = NPReadInventory() as? NSArray
        finalInventoryMatches = finalInventory == inventory as NSArray
        guard finalInventoryMatches == true else {
            if let finalInventory { rejectedInventory = (inventory as NSArray, finalInventory) }
            throw StageSwitchError.interrupted
        }
        step = "final-stage-manager"
        finalStageManagerAttempted = true; finalStageManager = StageManagerPreference.read()
        guard finalStageManager == false else { throw StageSwitchError.interrupted }
        completed = true
        return .init(id:id,frame:.init(x:cg.minX,y:cg.minY,width:cg.width,height:cg.height),membership:member,
                     onscreen:showing,minimized:minimized,focus:focused)
    }
}
