import AppKit
import CReadOnlySpaces
import NearpaneCore
import WindowGeometryCore

extension Reader {
    /// A read-only catalogue for the sidebar, independent of AX responsiveness.
    /// The current-window cards and the per-Space navigator share one double-read inventory.
    func windowOverview() throws -> DesktopSnapshot {
        guard WindowServerSession.available, request.fixtureWindows == nil, request.anchors.isEmpty else {
            throw DesktopActionError.unsupported
        }
        let start = clock.systemUptime, from = Date(), topology = try Topology()
        let canRead = NPReadOnlySpacesOpen() == 1 && (topology.displays.count == 1 || topology.separateSpaces)
        let first = try windowList(overview: true)
        let activeBefore = activeNumbers()
        let ids = first.windows.map(\.windowID)
        let firstBoundary = canRead ? SpaceBoundary.read(displays: topology.displays, windowIDs: ids) : nil
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
            if case .known = right {} else { complete = false }
            let slice = try topology.geometry.slices(of: entry.frame).max(by: { $0.fractionOfWindow < $1.fractionOfWindow })
            let display: DisplayObservation
            if let hit = topology.displays.first(where: { $0.id == slice?.displayID }) {
                display = hit
            } else if case .known(let ids) = right {
                let matches = topology.displays.filter { d in inventory?.scopes.contains { $0.displayID == d.id && $0.records.contains { ids.contains($0.id) } } == true }
                guard matches.count == 1, let only = matches.first else { complete = false; continue }
                display = only
            } else { complete = false; continue }
            let record = currentByDisplay[display.id]
            var proof: String?
            var membership = WindowMembership.unknown
            var nativeMember = false
            if case .known(let ids) = right, !supported.isDisjoint(with: ids) {
                guard inventory?.scopes.contains(where: { scope in
                    scope.displayID == display.id && scope.records.contains(where: { ids.contains($0.id) })
                }) == true else { complete = false; continue }
                nativeMember = true
                membership = .known(recordIDs: ids)
                if let record, record.ordinaryUUID != nil, ids.contains(record.id) { proof = record.id }
            }
            guard visible || nativeMember else { continue }
            // Unlocatable background surfaces cannot supply a desktop frame.
            guard slice?.displayID == display.id || proof != nil else { complete = false; continue }
            if proof == nil {
                let previousDisplay = try topology.geometry.slices(of: before.frame).max(by: { $0.fractionOfWindow < $1.fractionOfWindow })?.displayID
                guard previousDisplay == display.id else { complete = false; continue }
            }
            let global = SurfaceRect(entry.frame)
            let local = SurfaceRect(x: global.x - display.frame.x, y: global.y - display.frame.y, width: global.width, height: global.height)
            let meta = ObservedWindowMetadata(number: entry.windowID, pid: entry.process.pid,
                launchMicroseconds: entry.process.launchEpochMicroseconds, element: nil, globalFrame: global,
                frontToBack: windows.count, minimized: nil, fullScreen: nil, isOnscreen: entry.isOnscreen,
                onActiveDesktop: visible, overviewSpaceID: proof)
            windows.append(.init(id: "\(entry.process.pid)/\(birth)/\(entry.windowID)",
                displayID: display.id, bounds: local, membership: membership, confidence: .unknown, metadata: meta))
        }
        return .observed(request, from: from, to: Date(), build: clock.operatingSystemVersionString,
            topology: topology.fingerprint, consistent: true, separateSpaces: topology.separateSpaces,
            displays: topology.displays, scopes: inventory?.scopes ?? [], windows: windows,
            evidence: .init(population: .workWindows, accessibility: AXIsProcessTrusted() ? .available : .denied,
                spaces: inventory == nil ? .disabled : .observed, rows: [], windowLimitReached: false,
                beganUptime: start, endedUptime: clock.systemUptime,
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
