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
            if memberDisplays.count == 1, let owner = memberDisplays.first {
                return slices.contains(where: { $0.displayID == owner }) ? owner : nil
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
        let trusted = AXIsProcessTrusted()
        let backgroundInventory = canRead && trusted ? NPReadInventory().flatMap { SpaceInventory($0 as [AnyObject], displays:topology.displays) } : nil
        let first = try windowList(overview: true, backgroundInventory:backgroundInventory)
        let activeBeforeRead = observedActiveNumbers()
        let activeBefore = activeBeforeRead ?? []
        let ids = first.windows.map(\.windowID)
        let firstLogical = Dictionary(uniqueKeysWithValues: ids.compactMap { id in Self.logicalFrame(id).map { (id, $0) } })
        let firstBoundary = canRead ? SpaceBoundary.read(displays: topology.displays, windowIDs: ids) : nil
        if let backgroundInventory, backgroundInventory != firstBoundary?.inventory { throw DesktopActionError.unsupported }
        let currentIDs = firstBoundary?.inventory.map { inventory in
            Set(inventory.scopes.flatMap(\.records).filter { $0.isCurrent && $0.nativeKind != nil }.map(\.id))
        }
        let firstFullMembers = firstBoundary?.inventory?.fullscreenMembers() ?? [:]
        let fullscreenNumbers = Set(firstFullMembers.values.flatMap { $0 })
        let targets = Self.roleTargets(first, active: activeBefore, currentIDs: currentIDs,
                                       memberships: firstBoundary?.membership ?? [:])
        let otherIDs = Set(firstBoundary?.inventory?.scopes.flatMap(\.records).map(\.id) ?? []).subtracting(currentIDs ?? [])
        let others = Self.roleTargets(first, active: activeBefore, currentIDs: otherIDs,
                                      memberships: firstBoundary?.membership ?? [:], background: true)
        let currentNumbers = Set(targets.flatMap(\.numbers))
        let sharedSpaces = topology.displays.count > 1 && !topology.separateSpaces
        let otherNumbers = Set(others.flatMap(\.numbers)).subtracting(currentNumbers)
        let roles = trusted ? OverviewWindowRole.read(targets: targets, revision: request.revision, deadline: start + 0.8,
                                                     frameNumbers: sharedSpaces ? currentNumbers : fullscreenNumbers) : [:]
        // Preserve the entire current-desktop budget. Spend a separate bounded slice
        // on known background members for the other Space cards.
        let otherRoles = trusted ? OverviewWindowRole.read(targets: others, revision: request.revision,
                                                           deadline: min(start + 1, clock.systemUptime + 0.2)) : [:]
        let lastLogical = Dictionary(uniqueKeysWithValues: ids.compactMap { id in Self.logicalFrame(id).map { (id, $0) } })
        let second = try windowList(overview: true, backgroundInventory:backgroundInventory)
        let activeAfterRead = observedActiveNumbers()
        let activeAfter = activeAfterRead ?? []
        let active = activeBefore.intersection(activeAfter)
        let observedActive = activeBefore.union(activeAfter)
        let lastBoundary = firstBoundary?.inventory == nil ? nil : SpaceBoundary.read(displays: topology.displays, windowIDs: ids)
        guard topology == (try Topology()), WindowServerSession.available, !first.limited, !second.limited else {
            throw DesktopActionError.unsupported
        }
        let inventory = firstBoundary?.inventory == lastBoundary?.inventory ? lastBoundary?.inventory : nil
        if firstBoundary?.inventory != lastBoundary?.inventory { throw DesktopActionError.unsupported }
        let lastFullMembers = inventory?.fullscreenMembers() ?? [:]
        let previous = Dictionary(uniqueKeysWithValues: first.windows.map { ($0.windowID, $0) })
        let currentByDisplay = Dictionary(uniqueKeysWithValues: (inventory?.scopes ?? []).map { scope in
            (scope.displayID, scope.records.first(where: \.isCurrent))
        }).compactMapValues { $0 }
        let stageAfter = StageManagerPreference.read()
        let stageManager = stageBefore == stageAfter ? stageAfter : nil
        var windows = [WindowObservation]()
        // Absence only proves emptiness when every eligible CG surface was accounted for.
        let hasBackground = inventory?.scopes.flatMap(\.records).contains { !$0.isCurrent && $0.ordinaryUUID != nil } == true
        var complete = true
        var catalogIssues = [String]()
        var catalogIssueWindows = [CatalogIssueWindowFacts]()
        func incomplete(_ reason: String, window: CGWindowMetadata? = nil) {
            complete = false
            guard catalogIssues.count < 32 else { return }
            catalogIssues.append(window.map { "\(reason):pid=\($0.process.pid),window=\($0.windowID)" } ?? reason)
            guard let window, catalogIssueWindows.count < CatalogIssueWindowFacts.limit else { return }
            let number = window.windowID, before = previous[number]
            func sample(_ row: CGWindowMetadata, list: List, active: Set<UInt32>?) -> CatalogIssueWindowFacts.Sample {
                .init(pid: row.process.pid, birth: row.process.launchEpochMicroseconds, frame: SurfaceRect(row.frame),
                      reportedOnscreen: row.isOnscreen, observedOnscreen: list.observedOnscreen.map { $0.contains(number) },
                      active: active.map { $0.contains(number) }, ordered: list.observedAcrossSpaces.map { $0.contains(number) },
                      ownerUnhidden: list.unhiddenOwners.contains(row.process.pid))
            }
            // The roles were read between CG inventories for the first PID.
            // Keep that identity explicit if this failed row changed owners.
            let source: CatalogIssueWindowFacts.Role.Source = currentNumbers.contains(number) ? .current :
                (otherNumbers.contains(number) ? .background : .notRequested)
            let owner = before.flatMap { row in
                source == .current ? roles[row.process.pid] : (source == .background ? otherRoles[row.process.pid] : nil)
            }
            let role = owner?.windows[number]
            catalogIssueWindows.append(.init(issueIndex: catalogIssues.count - 1, number: number,
                first: before.map { sample($0, list: first, active: activeBeforeRead) },
                second: sample(window, list: second, active: activeAfterRead),
                left: firstBoundary?.membership[number], right: lastBoundary?.membership[number],
                role: .init(firstPID: before?.process.pid, source: source, ownerRead: owner != nil, windowRead: role != nil,
                            everyNumberKnown: owner?.everyNumberKnown, allRolesRead: owner?.allRolesRead,
                            ordinary: role?.ordinary, minimized: role?.minimized, fullscreen: role?.fullscreen)))
        }
        if inventory == nil { incomplete("nativeInventoryUnavailable") }
        if hasBackground && (!first.backgroundCollectionComplete || !second.backgroundCollectionComplete ||
                             backgroundInventory != inventory) { incomplete("backgroundRosterIncomplete") }
        if Set(first.windows.map(\.windowID)) != Set(second.windows.map(\.windowID)) { incomplete("windowRosterChanged") }
        let admitted = inventory?.scopes.flatMap(\.records).filter { $0.ordinaryUUID != nil || $0.fullscreenUUID != nil } ?? []
        let supported = Set(admitted.map(\.id))
        for entry in second.windows {
            guard let before = previous[entry.windowID], let birth = entry.process.launchEpochMicroseconds, birth > 0,
                  before.process == entry.process,
                  min(entry.frame.width, entry.frame.height) > 1 else { incomplete("windowIdentityOrBounds", window: entry); continue }
            let visible = active.contains(entry.windowID) && before.isOnscreen == true && entry.isOnscreen == true
            if firstBoundary?.excludesUnplacedSurface(entry.windowID, through: lastBoundary,
                firstReportedOnscreen: before.isOnscreen, lastReportedOnscreen: entry.isOnscreen,
                firstOnscreen: first.observedOnscreen, lastOnscreen: second.observedOnscreen,
                firstActive: activeBeforeRead, lastActive: activeAfterRead,
                firstOrdered: first.observedAcrossSpaces, lastOrdered: second.observedAcrossSpaces) == true { continue }
            // Our inactive group windows can remain in CG's all-window list.
            // Their independently confirmed hidden membership is not a failed
            // ordinary-desktop read. The retained engine witness still owns and
            // verifies those windows; no directory row or write lease is minted.
            if firstBoundary?.excludesNonManagedWindow(entry.windowID, through: lastBoundary,
                firstOnscreen: first.observedOnscreen.map { $0.contains(entry.windowID) || before.isOnscreen == true } ?? before.isOnscreen,
                lastOnscreen: second.observedOnscreen.map { $0.contains(entry.windowID) || entry.isOnscreen == true } ?? entry.isOnscreen,
                active: activeBeforeRead != nil && activeAfterRead != nil ? observedActive.contains(entry.windowID) : nil) == true { continue }
            let left = firstBoundary?.membership[entry.windowID], right = lastBoundary?.membership[entry.windowID]
            guard left == right else { incomplete("membershipChanged", window: entry); continue }
            if right == nil || right == .unknown {
                func presence(_ numbers: Set<UInt32>?) -> String {
                    numbers.map { $0.contains(entry.windowID) ? "yes" : "no" } ?? "unknown"
                }
                let reason = "membershipUnavailable(emptyInclusive=\(firstBoundary?.unplaced.contains(entry.windowID) == true),\(lastBoundary?.unplaced.contains(entry.windowID) == true)" +
                    ";CG=\(presence(first.observedOnscreen)),\(presence(second.observedOnscreen))" +
                    ";active=\(presence(activeBeforeRead)),\(presence(activeAfterRead))" +
                    ";allSpaces=\(presence(first.observedAcrossSpaces)),\(presence(second.observedAcrossSpaces)))"
                incomplete(reason, window: entry)
            }
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
                  let display = topology.displays.first(where: { $0.id == displayID }) else { incomplete("displayUnresolved", window: entry); continue }
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
                guard memberDisplays.contains(display.id) else { incomplete("membershipDisplayMismatch", window: entry); continue }
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
            let fullID = record.flatMap { current -> String? in
                guard current.nativeKind == .fullscreen, membership == .known(recordIDs: [current.id]),
                      firstFullMembers[current.id]?.contains(entry.windowID) == true,
                      lastFullMembers[current.id]?.contains(entry.windowID) == true else { return nil }
                return current.id
            }
            let fullPresented = fullID != nil && role?.ordinary == true && role?.minimized == false &&
                first.unhiddenOwners.contains(entry.process.pid) && second.unhiddenOwners.contains(entry.process.pid) &&
                before.isOnscreen == true && entry.isOnscreen == true &&
                display.frame.geometry.intersection(entry.frame) == entry.frame &&
                display.frame.geometry.intersection(before.frame) == before.frame
            let tile = fullID.flatMap { inventory?.activeTiles[$0] }.map { tiles in
                tiles.count == 2 && tiles.contains { $0.pid == entry.process.pid && $0.number == entry.windowID &&
                    ($0.frame.componentError(from: local.geometry) <= 2 || $0.frame.componentError(from: entry.frame) <= 2) }
            }
            let axConfirmsFrame = role?.frame.map { $0.componentError(from: entry.frame) <= 2 } == true
            let fullGeometry = fullPresented && before.frame == entry.frame && (geometry.usualPresentation || tile == true || axConfirmsFrame)
            let publicGeometry = sharedSpaces && visible && before.frame == entry.frame && axConfirmsFrame
            let presented = fullPresented || Self.presentedInOverview(publiclyVisible: visible,
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
                hasCatalogGeometry: fullID != nil ? fullGeometry :
                    (geometry.usualPresentation || publicGeometry) && afterSlices.contains(where: { $0.displayID == display.id }),
                catalogLogicalFrame: geometry.logical.map(SurfaceRect.init), overviewIsPresented: presented,
                overviewOrdinaryRole: OverviewWindowRole.classification(of: entry.windowID, owner: ownerRoles, current: proof != nil || fullID != nil),
                activeFullscreenSpaceID: fullID, matchesNativeTile: tile)
            windows.append(.init(id: "\(entry.process.pid)/\(birth)/\(entry.windowID)",
                displayID: display.id, bounds: local, membership: membership, confidence: .unknown, metadata: meta))
        }
        var result = DesktopSnapshot.observed(request, from: from, to: Date(), build: clock.operatingSystemVersionString,
            topology: topology.fingerprint, consistent: true, separateSpaces: topology.separateSpaces,
            displays: topology.displays, scopes: inventory?.scopes ?? [], windows: windows,
            evidence: .init(population: .workWindows, accessibility: trusted ? (targets.allSatisfy { roles[$0.pid]?.everyNumberKnown == true && roles[$0.pid]?.allRolesRead == true } ? .available : .partial) : .denied,
                spaces: inventory == nil ? .disabled : .observed, rows: [], windowLimitReached: false,
                beganUptime: start, endedUptime: clock.systemUptime, stageManagerEnabled: stageManager,
                catalogComplete: inventory != nil && complete))
        result.native?.catalogIssues = catalogIssues.isEmpty ? nil : catalogIssues
        result.native?.catalogIssueWindows = catalogIssueWindows.isEmpty ? nil : catalogIssueWindows
        if !complete, let firstCensus = first.census, let secondCensus = second.census {
            result.native?.catalogCensus = .init(first: firstCensus, second: secondCensus)
        }
        if let targets = request.sidebarAuditWindows {
            result.native?.sidebarWindowAudit = targets.prefix(2).map { key in
                var flags = ["catalogueAvailable": canRead, "readerAXTrusted": trusted, "backgroundInventory": backgroundInventory != nil,
                             "firstAccepted": first.windows.contains { $0.windowID == key.number && $0.process.pid == key.pid &&
                                 $0.process.launchEpochMicroseconds == key.birth },
                             "secondAccepted": second.windows.contains { $0.windowID == key.number && $0.process.pid == key.pid &&
                                 $0.process.launchEpochMicroseconds == key.birth },
                             "currentRoleRequested": currentNumbers.contains(key.number), "backgroundRoleRequested": otherNumbers.contains(key.number),
                             "scopedMetadataEmitted": windows.contains { $0.metadata?.number == key.number && $0.metadata?.pid == key.pid &&
                                 $0.metadata?.launchMicroseconds == key.birth }]
                for (k,v) in first.audit[key.number] ?? [:] { flags["first." + k] = v }
                for (k,v) in second.audit[key.number] ?? [:] { flags["second." + k] = v }
                let prior = firstBoundary?.membership[key.number], latest = lastBoundary?.membership[key.number]
                flags["membershipStable"] = prior != nil && prior == latest
                if case let .known(ids) = latest { flags["membershipExclusive"] = ids.count == 1 }
                let owner = currentNumbers.contains(key.number) ? roles[key.pid] : otherRoles[key.pid]
                flags["ownerAXListRead"] = owner != nil
                flags["ownerAllNumbersRead"] = owner?.everyNumberKnown
                flags["listedAXWindow"] = owner?.windows[key.number] != nil
                return .init(key, flags: flags)
            }
        }
        return result
    }
}

private enum WindowServerSession {
    static var available: Bool {
        let console = CGSessionCopyCurrentDictionary() as? [String: Any]
        return console?[kCGSessionOnConsoleKey as String] as? Bool == true &&
            console?[kCGSessionLoginDoneKey as String] as? Bool == true && console?["CGSSessionScreenIsLocked"] as? Bool != true
    }
}
