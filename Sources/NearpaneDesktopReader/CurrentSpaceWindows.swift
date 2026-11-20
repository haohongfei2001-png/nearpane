import AppKit
import CReadOnlySpaces
import NearpaneCore
import WindowGeometryCore

extension Reader {
    private static func logicalFrame(_ number: UInt32) -> Rect? {
        var result = CGRect.zero
        guard NPReadCatalogLogicalBounds(number, &result) == 1 else { return nil }
        let frame = Rect(result.minX, result.minY, result.width, result.height)
        return frame.isValid ? frame : nil
    }

    nonisolated static func catalogGeometry(firstLogical: Rect?, lastLogical: Rect?, firstCG: Rect, lastCG: Rect,
                                            stageDefinitelyOff: Bool) -> (logical: Rect?, usualPresentation: Bool) {
        let logical = firstLogical == lastLogical ? lastLogical : nil
        let confirmed = logical.map { $0 == lastCG } ??
            (firstLogical == nil && lastLogical == nil && stageDefinitelyOff)
        return (logical, firstCG == lastCG && confirmed)
    }

    /// A window crosses screens during a drag. Publish its screen only when the
    /// two samples agree. Space membership can disambiguate an equal split or
    /// locate an offscreen member without inventing a visible frame for it.
    nonisolated static func overviewDisplay(before: [DisplaySlice], after: [DisplaySlice], memberDisplays: [String]) -> String? {
        func display(_ slices: [DisplaySlice]) -> String? {
            guard let largest = slices.map(\.fractionOfWindow).max() else {
                return memberDisplays.count == 1 ? memberDisplays.first : nil
            }
            let ties = slices.filter { $0.fractionOfWindow == largest }.map(\.displayID)
            if ties.count == 1 { return ties[0] }
            let matching = ties.filter(memberDisplays.contains)
            return matching.count == 1 ? matching[0] : nil
        }
        guard let first = display(before), first == display(after) else { return nil }
        return first
    }

    nonisolated static func presentedInOverview(publiclyVisible: Bool, orderedAcrossSpaces: Bool, currentMember: Bool,
                                                onDisplay: Bool, ownerUnhidden: Bool, readsAX: Bool,
                                                role: OverviewWindowRole?, drawnInStage: Bool = false) -> Bool {
        guard ownerUnhidden, onDisplay else { return false }
        guard let role else {
            // Public ordering across *all* Spaces also includes surfaces whose role
            // and minimized state we cannot attest. Keep only the doubly observed
            // current AppKit and onscreen CG surface as a read-only candidate.
            return !readsAX && publiclyVisible
        }
        guard role.ordinary == true, role.minimized == false, role.fullscreen != true else { return false }
        return publiclyVisible || (currentMember && (orderedAcrossSpaces || drawnInStage))
    }

    nonisolated static func roleTargets(_ list: List, active: Set<UInt32>, currentIDs: Set<String>?,
                                        memberships: [UInt32: WindowMembership], background: Bool = false) -> [OverviewWindowRole.Target] {
        var order: [Int32] = [], numbers: [Int32: Set<UInt32>] = [:]
        for w in list.windows {
            guard (background || list.unhiddenOwners.contains(w.process.pid)), w.process.hasLifecycleEvidence else { continue }
            if let currentIDs {
                guard case let .known(ids) = memberships[w.windowID], !currentIDs.isDisjoint(with: ids),
                      background || w.isOnscreen == true || active.contains(w.windowID) || list.orderedAcrossSpaces.contains(w.windowID) else { continue }
            } else {
                guard w.isOnscreen == true, active.contains(w.windowID) else { continue }
            }
            if numbers[w.process.pid] == nil { order.append(w.process.pid) }
            numbers[w.process.pid, default: []].insert(w.windowID)
        }
        return order.compactMap { pid in numbers[pid].map { .init(pid: pid, numbers: $0) } }
    }

    /// A read-only catalogue for this screen's window roster, independent of AX responsiveness.
    func windowOverview() throws -> DesktopSnapshot {
        guard WindowServerSession.available, request.fixtureWindows == nil, request.anchors.isEmpty else {
            throw DesktopActionError.unsupported
        }
        let start = clock.systemUptime, from = Date(), topology = try Topology()
        let canRead = NPProbeReadOnlyCatalog() == 1 && (topology.displays.count == 1 || topology.separateSpaces)
        let stageBefore = StageManagerPreference.read()
        let first = try windowList(overview: true)
        let activeBefore = activeNumbers()
        let ids = first.windows.map(\.windowID)
        let firstLogical = Dictionary(uniqueKeysWithValues: ids.compactMap { id in Self.logicalFrame(id).map { (id, $0) } })
        let firstBoundary = canRead ? SpaceBoundary.read(displays: topology.displays, windowIDs: ids) : nil
        let trusted = AXIsProcessTrusted()
        let currentIDs = firstBoundary?.inventory.map { inventory in
            Set(inventory.scopes.flatMap(\.records).filter { $0.isCurrent && $0.ordinaryUUID != nil }.map(\.id))
        }
        let targets = Self.roleTargets(first, active: activeBefore, currentIDs: currentIDs,
                                       memberships: firstBoundary?.membership ?? [:])
        let otherIDs = Set(firstBoundary?.inventory?.scopes.flatMap(\.records).map(\.id) ?? []).subtracting(currentIDs ?? [])
        let others = Self.roleTargets(first, active: activeBefore, currentIDs: otherIDs,
                                      memberships: firstBoundary?.membership ?? [:], background: true)
        let currentNumbers = Set(targets.flatMap(\.numbers))
        let otherNumbers = Set(others.flatMap(\.numbers)).subtracting(currentNumbers)
        let roles = trusted ? OverviewWindowRole.read(targets: targets, revision: request.revision, deadline: start + 0.8) : [:]
        // Preserve the entire current-desktop budget. Spend a separate bounded slice
        // on known background members for the other Space cards.
        let otherRoles = trusted ? OverviewWindowRole.read(targets: others, revision: request.revision,
                                                           deadline: min(start + 1, clock.systemUptime + 0.2)) : [:]
        let lastLogical = Dictionary(uniqueKeysWithValues: ids.compactMap { id in Self.logicalFrame(id).map { (id, $0) } })
        let second = try windowList(overview: true)
        let active = activeBefore.intersection(activeNumbers())
        let lastBoundary = firstBoundary?.inventory == nil ? nil : SpaceBoundary.read(displays: topology.displays, windowIDs: ids)
        guard topology == (try Topology()), WindowServerSession.available, !first.limited, !second.limited else {
            throw DesktopActionError.unsupported
        }
        let inventory = firstBoundary?.inventory == lastBoundary?.inventory ? lastBoundary?.inventory : nil
        if firstBoundary?.inventory != lastBoundary?.inventory { throw DesktopActionError.unsupported }
        let previous = Dictionary(uniqueKeysWithValues: first.windows.map { ($0.windowID, $0) })
        let currentByDisplay = Dictionary(uniqueKeysWithValues: (inventory?.scopes ?? []).map { scope in
            (scope.displayID, scope.records.first(where: \.isCurrent))
        }).compactMapValues { $0 }
        let stageAfter = StageManagerPreference.read()
        let stageManager = stageBefore == stageAfter ? stageAfter : nil
        var windows = [WindowObservation]()
        // Absence only proves emptiness when every eligible CG surface was accounted for.
        var complete = Set(first.windows.map(\.windowID)) == Set(second.windows.map(\.windowID))
        let admitted = inventory?.scopes.flatMap(\.records).filter { $0.ordinaryUUID != nil || $0.fullscreenUUID != nil } ?? []
        let supported = Set(admitted.map(\.id))
        for entry in second.windows {
            guard let before = previous[entry.windowID], let birth = entry.process.launchEpochMicroseconds, birth > 0,
                  before.process == entry.process,
                  min(entry.frame.width, entry.frame.height) > 1 else { complete = false; continue }
            let visible = active.contains(entry.windowID) && before.isOnscreen == true && entry.isOnscreen == true
            let left = firstBoundary?.membership[entry.windowID], right = lastBoundary?.membership[entry.windowID]
            guard left == right else { complete = false; continue }
            if right == nil || right == .unknown { complete = false }
            let memberDisplays: [String]
            if case .known(let ids) = right {
                memberDisplays = inventory?.scopes.filter { $0.records.contains { ids.contains($0.id) } }.map(\.displayID) ?? []
            } else { memberDisplays = [] }
            let firstRect = firstLogical[entry.windowID], lastRect = lastLogical[entry.windowID]
            let geometry = Self.catalogGeometry(firstLogical: firstRect, lastLogical: lastRect, firstCG: before.frame,
                                                lastCG: entry.frame, stageDefinitelyOff: stageManager == false)
            let afterSlices = try topology.geometry.slices(of: lastRect ?? entry.frame)
            let beforeSlices = try topology.geometry.slices(of: firstRect ?? before.frame)
            guard let displayID = Self.overviewDisplay(before: beforeSlices, after: afterSlices, memberDisplays: memberDisplays),
                  let display = topology.displays.first(where: { $0.id == displayID }) else { complete = false; continue }
            let record = currentByDisplay[display.id]
            var proof: String?
            var membership = WindowMembership.unknown
            var nativeMember = false
            if case .known(let ids) = right {
                // Preserve the negative evidence from internal/other-Space records.
                // Otherwise a public surface could be relabelled as unknown or current.
                membership = .known(recordIDs: ids)
            }
            if case .known(let ids) = right, !supported.isDisjoint(with: ids) {
                guard memberDisplays.contains(display.id) else { complete = false; continue }
                nativeMember = true
                if let record, record.ordinaryUUID != nil, ids.contains(record.id) { proof = record.id }
            }
            guard visible || nativeMember else { continue }
            // A background member can be stored outside the display. Keep its identity
            // for selection without inventing a frame in the Space miniature.
            let global = SurfaceRect(entry.frame)
            let local = SurfaceRect(x: global.x - display.frame.x, y: global.y - display.frame.y, width: global.width, height: global.height)
            let ownerRoles = currentNumbers.contains(entry.windowID) ? roles[entry.process.pid] :
                (otherNumbers.contains(entry.windowID) ? otherRoles[entry.process.pid] : nil)
            let role = ownerRoles?.windows[entry.windowID]
            let presented = Self.presentedInOverview(publiclyVisible: visible,
                orderedAcrossSpaces: first.orderedAcrossSpaces.contains(entry.windowID) && second.orderedAcrossSpaces.contains(entry.windowID),
                currentMember: proof != nil, onDisplay: afterSlices.contains { $0.displayID == display.id } &&
                    beforeSlices.contains { $0.displayID == display.id },
                ownerUnhidden: first.unhiddenOwners.contains(entry.process.pid) && second.unhiddenOwners.contains(entry.process.pid),
                readsAX: role != nil || ownerRoles?.everyNumberKnown == true, role: role,
                drawnInStage: stageManager == true && before.isOnscreen == true && entry.isOnscreen == true)
            let meta = ObservedWindowMetadata(number: entry.windowID, pid: entry.process.pid,
                launchMicroseconds: entry.process.launchEpochMicroseconds, element: nil, globalFrame: global,
                frontToBack: windows.count, minimized: role?.minimized, fullScreen: role?.fullscreen, isOnscreen: entry.isOnscreen,
                onActiveDesktop: visible, overviewSpaceID: proof,
                hasCatalogGeometry: geometry.usualPresentation && afterSlices.contains(where: { $0.displayID == display.id }),
                catalogLogicalFrame: geometry.logical.map(SurfaceRect.init), overviewIsPresented: presented,
                overviewOrdinaryRole: role?.ordinary ?? (role == nil && ownerRoles?.everyNumberKnown == true ? false : nil))
            windows.append(.init(id: "\(entry.process.pid)/\(birth)/\(entry.windowID)",
                displayID: display.id, bounds: local, membership: membership, confidence: .unknown, metadata: meta))
        }
        return .observed(request, from: from, to: Date(), build: clock.operatingSystemVersionString,
            topology: topology.fingerprint, consistent: true, separateSpaces: topology.separateSpaces,
            displays: topology.displays, scopes: inventory?.scopes ?? [], windows: windows,
            evidence: .init(population: .workWindows, accessibility: trusted ? (targets.allSatisfy { roles[$0.pid]?.everyNumberKnown == true && roles[$0.pid]?.allRolesRead == true } ? .available : .partial) : .denied,
                spaces: inventory == nil ? .disabled : .observed, rows: [], windowLimitReached: false,
                beganUptime: start, endedUptime: clock.systemUptime, stageManagerEnabled: stageManager,
                catalogComplete: inventory != nil && complete))
    }
}

private enum WindowServerSession {
    static var available: Bool {
        let console = CGSessionCopyCurrentDictionary() as? [String: Any]
        return console?[kCGSessionOnConsoleKey as String] as? Bool == true &&
            console?[kCGSessionLoginDoneKey as String] as? Bool == true && console?["CGSSessionScreenIsLocked"] as? Bool != true
    }
}
