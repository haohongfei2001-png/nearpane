import AppKit
import ApplicationServices
import Foundation

func p2StageBoundsMatch(_ rect: CGRect, on screen: CGRect, enrolled: [Double]) -> Bool {
    return screen.contains(rect) && rect.minX > screen.minX + screen.width * 0.75 &&
        rect.width > 2 && rect.height > 2 && rect.width <= screen.width * 0.15 &&
        rect.height <= screen.height * 0.15 && [rect.minX, rect.minY, rect.width, rect.height] == enrolled
}

func p2StageHidden(metadata: Any?, cg: Bool, appKit: Bool, ax: Bool) -> Bool {
    return (metadata == nil || (metadata as? Bool) == false) && !cg && !appKit && !ax
}

#if !P2_STAGE_OFFLINE
private struct P2StageSurface: Decodable {
    let number: UInt32, pid: pid_t, ownerBirth: UInt64, bounds: [Double]
}
private struct P2SurfaceRequest: Decodable {
    let space: UInt64, spaceUUID: String, display: String, boot: String
    let hostPID: pid_t, hostBirth: UInt64, hostHash: String
    let enrolled: [P2StageSurface], present: [UInt32]
}

private func p2Boot() -> String? {
    var count = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &count, nil, 0) == 0, (2...128).contains(count) else { return nil }
    var text = [CChar](repeating: 0, count: count)
    guard sysctlbyname("kern.bootsessionuuid", &text, &count, nil, 0) == 0 else { return nil }
    return String(cString: text)
}

private func p2StageOff() -> Bool {
    guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] == nil,
          let home = getpwuid(getuid())?.pointee.pw_dir, NSHomeDirectory() == String(cString: home),
          let flag = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString),
          CFGetTypeID(flag) == CFBooleanGetTypeID() else { return false }
    return (flag as? Bool) == false
}

private func p2StageDisplay(_ r: P2SurfaceRequest) -> CGRect? {
    guard let scopes = inventory(requireComplete: true), scopes.count == 1, let s = scopes.first,
          s["scope"] as? String == r.display, s["current"] as? UInt64 == r.space,
          let records = s["records"] as? [Object], records.filter({
              $0["id"] as? UInt64 == r.space && $0["type"] as? Int == 0 &&
                  ($0["uuid"] as? String)?.lowercased() == r.spaceUUID.lowercased()
          }).count == 1, NSScreen.screens.count == 1, displays().first?["uuid"] as? String == r.display,
          let id = NSScreen.screens.first?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    else { return nil }
    return CGDisplayBounds(id)
}

private func p2StageRow(_ number: UInt32) -> Object? {
    guard let ids = CFArrayCreateMutable(nil, 1, nil), let raw = UnsafeRawPointer(bitPattern: UInt(number)) else { return nil }
    CFArrayAppendValue(ids, raw)
    guard let scoped = CGWindowListCreateDescriptionFromArray(ids) as? [Object], scoped.count == 1,
          scoped[0][kCGWindowNumber as String] as? UInt32 == number else { return nil }
    return scoped[0]
}

func p2StageSurfaceReport(_ data: Data) -> Object {
    let uptime = ProcessInfo.processInfo.systemUptime
    func stop(_ reason: String) -> Object { ["status":"BLOCKED", "reason":reason, "uptime":uptime, "pixels":0] }
    guard data.count <= 8192, let r = try? JSONDecoder().decode(P2SurfaceRequest.self, from: data),
          r.enrolled.count <= 8, Set(r.enrolled.map(\.number)).count == r.enrolled.count,
          r.present == r.present.sorted(), Set(r.present).count == r.present.count,
          Set(r.present).isSubset(of: Set(r.enrolled.map(\.number))), r.hostPID > 1, r.hostBirth > 0,
          r.space > 0, UUID(uuidString:r.spaceUUID) != nil,
          r.enrolled.allSatisfy({ $0.pid > 1 && $0.number > 0 && $0.ownerBirth > 0 && $0.bounds.count == 4 &&
              $0.bounds.allSatisfy(\.isFinite) })
    else { return stop("invalidBoundStageSurfaceRequest") }
    func boundHost() -> Bool {
        let installedHosts = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            !$0.isTerminated && $0.bundleURL?.standardizedFileURL == installed.standardizedFileURL
        }
        return installedHosts.count == 1 && installedHosts.first?.processIdentifier == r.hostPID &&
            birthMicroseconds(r.hostPID) == r.hostBirth && runningCodeHash(r.hostPID) == r.hostHash
    }
    guard p2Boot() == r.boot, boundHost(), let screen = p2StageDisplay(r) else { return stop("stageSurfaceBootHostOrSpaceChanged") }
    guard p2StageOff() else { return stop("actualLoginStageOffUnconfirmed") }
    guard let forward = NPReadCatalogSpaceWindowNumbers(r.space) as? [UInt32] else { return stop("stageSurfaceForwardListUnavailable") }
    let present = Set(r.present)
    var proofs = [Object](), departed = [UInt32]()
    if let first = r.enrolled.first {
        guard let manager = try? OverviewProcess.current(.manager), manager.pid == first.pid, manager.birth == first.ownerBirth,
              r.enrolled.allSatisfy({ $0.pid == manager.pid && $0.ownerBirth == manager.birth })
        else { return stop("enrolledAppleWindowManagerGenerationChanged") }
        guard AXIsProcessTrusted(), let visible = NPContractOnscreenWindowNumbers() as? [UInt32], let publicList = NSWindow.windowNumbers(options: .allApplications)
        else { return stop("publicCGAppKitOrAccessibilityUnavailable") }
        let root = AXUIElementCreateApplication(manager.pid)
        _ = AXUIElementSetMessagingTimeout(root, 0.25)
        guard let windows = value(root, kAXWindowsAttribute) as? [AXUIElement], windows.count <= 128 else {
            return stop("windowManagerAXWindowListUnavailable")
        }
        var axNumbers = Set<UInt32>()
        for win in windows {
            guard manager.owns(win), value(win, kAXRoleAttribute) as? String == kAXWindowRole else {
                return stop("windowManagerAXMemberUnidentified")
            }
            let id = NPReadAXWindowNumber(win)
            guard id != 0 else { return stop("windowManagerAXNumberUnavailable") }
            axNumbers.insert(id)
        }
        for member in r.enrolled.sorted(by: { $0.number < $1.number }) {
            let id = member.number
            if !present.contains(id) {
                guard !forward.contains(id) && NPReadWindowNumberPresence(id) == 0 && !axNumbers.contains(id) &&
                        !visible.contains(id) && !publicList.contains(NSNumber(value:id)) else {
                    return stop("enrolledSurfaceDisappearedFromOrdinaryCensusOnly")
                }
                departed.append(id)
                continue
            }
            guard forward.contains(id), NPReadWindowSpaces(id) as? [UInt64] == [r.space] else { return stop("stageSurfaceForwardReverseChanged") }
            guard let row = p2StageRow(id), row[kCGWindowOwnerPID as String] as? pid_t == manager.pid,
                  row[kCGWindowLayer as String] as? Int == 0, let raw = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: raw), p2StageBoundsMatch(rect, on:screen, enrolled:member.bounds)
            else { return stop("stageSurfaceNumberOwnerLayerOrBoundsChanged") }
            guard p2StageHidden(metadata:row[kCGWindowIsOnscreen as String], cg:visible.contains(id),
                                 appKit:publicList.contains(NSNumber(value:id)), ax:axNumbers.contains(id)) else {
                return stop("stageSurfaceNowVisibleOrAXWindow")
            }
            proofs.append(["admitted":true, "category":"offscreenSignedWindowManagerSurface", "pixels":0,
                           "pid":manager.pid, "number":id, "ownerBirth":manager.birth, "bounds":windowReceiptRect(rect),
                           "publicOnscreen":false, "cgOnscreenListed":false, "appKitListed":false,
                           "listedAsOwnDocument":false, "forwardAndReverse":true])
        }
        guard (try? manager.verify()) != nil else { return stop("enrolledAppleWindowManagerGenerationChanged") }
    }
    // Reconcile every current ordinary member; a foreground document appearing since the enclosing read fails here.
    let selected = [NSNumber(value: r.space)] as CFArray
    guard let all = NPContractMemberReport(selected, r.hostPID) as? Object, let current = all[String(r.space)] as? Object,
          current["unresolved"] as? Int == 0, let ordinary = current["ordinary"] as? [Object],
          ordinary.count == r.present.count, ordinary.allSatisfy({ row in
              guard let id = row["number"] as? UInt32, let pid = row["pid"] as? pid_t else { return false }
              return present.contains(id) && r.enrolled.contains { $0.number == id && $0.pid == pid }
          }), Set(ordinary.compactMap { $0["number"] as? UInt32 }) == present,
          p2StageOff(), p2StageDisplay(r) == screen, boundHost() else { return stop("freshOrdinaryRosterOrHostChanged") }
    let scope: Object = ["boot":r.boot, "space":r.space, "spaceUUID":r.spaceUUID, "display":r.display,
                         "hostPID":r.hostPID, "hostBirth":r.hostBirth, "hostHash":r.hostHash]
    return ["status":"READ", "stageEnabled":false, "scope":scope, "surfaces":proofs, "departed":departed,
            "uptime":uptime, "pixels":0]
}
#endif
