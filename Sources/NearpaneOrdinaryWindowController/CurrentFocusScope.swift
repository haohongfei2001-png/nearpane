import AppKit
import CReadOnlySpaces
import NearpaneCore

/// Metadata for one selected window. The reverse lookup never opens other owners' AX trees.
package enum CurrentFocusScope {
    package typealias Evidence = OrdinaryFocusScopeEvidence
    package typealias Finding = OrdinaryFocusScopeFinding

    package final class Trace {
        package private(set) var findings = [Finding]()
        let includeConfirmed: Bool
        package init(includeConfirmed: Bool = false) { self.includeConfirmed = includeConfirmed }
        func note(_ point: Finding.Point, _ reason: Finding.Reason, _ state: Evidence,
                  _ expected: Int? = nil, _ observed: Int? = nil) -> Evidence {
            if (includeConfirmed || state != .confirmed), findings.count < 48 {
                findings.append(.init(point, reason, state, expected, observed))
            }
            return state
        }
    }

    static func decide(_ evidence: Evidence...) -> Evidence {
        if evidence.contains(.changed) { return .changed }
        return evidence.contains(.fullRosterRequired) ? .fullRosterRequired : .confirmed
    }

    static func authorizeStep(input: () -> [UInt32] = WindowSelectionInput.counters,
                              permit: () throws -> Void, revalidate: () throws -> Void) throws {
        let original = input()
        try permit()
        try revalidate()
        try require(input() == original, "用户已发出新的输入，原选窗操作已取消。")
    }

    static func topology(_ fingerprint: String?, for scope: OrdinaryFocusScope) -> Evidence {
        guard let fingerprint else { return .fullRosterRequired }
        return fingerprint == scope.topology ? .confirmed : .changed
    }

    static func inventory(_ rows: [[String: Any]]?, for scope: OrdinaryFocusScope, point: Finding.Point = .opening,
                          trace: Trace = Trace()) -> Evidence {
        func note(_ reason: Finding.Reason, _ state: Evidence, _ expected: Int? = nil, _ observed: Int? = nil) -> Evidence {
            trace.note(point, reason, state, expected, observed)
        }
        guard let rows, !rows.isEmpty, let display = UUID(uuidString: scope.desktop.display) else { return note(.spaceInventory, .fullRosterRequired) }
        let displays = rows.compactMap { ($0["Display Identifier"] as? String).flatMap(UUID.init(uuidString:)) }
        guard displays.count == rows.count, Set(displays).count == rows.count else { return note(.displaySet, .fullRosterRequired, rows.count, Set(displays).count) }
        guard displays == [display] else { return note(.displaySet, .changed, 1, displays.count) }
        let row = rows[0]
        guard let current = row["Current Space"] as? [String: Any], let currentNumber = current["id64"] as? UInt64 else {
            return note(.currentRecord, .fullRosterRequired)
        }
        guard String(currentNumber) == scope.desktop.record else { return note(.currentRecord, .changed) }
        if let raw = current["type"] {
            guard let type = raw as? Int else { return note(.currentType, .fullRosterRequired) }
            if type != 0 { return note(.currentType, .changed, 0, type) }
        }
        if let raw = current["uuid"] {
            guard let uuid = (raw as? String).flatMap(UUID.init(uuidString:)) else { return note(.currentUUID, .fullRosterRequired) }
            if scope.desktop.uuid != uuid { return note(.currentUUID, .changed) }
        }
        guard let spaces = row["Spaces"] as? [[String: Any]], !spaces.isEmpty, spaces.count <= 256 else { return note(.spaceOrder, .fullRosterRequired) }
        let ids = spaces.compactMap { $0["id64"] as? UInt64 }
        guard ids.count == spaces.count, !ids.contains(0), Set(ids).count == spaces.count else { return note(.spaceOrder, .fullRosterRequired, spaces.count, Set(ids).count) }
        guard ids.map(String.init) == scope.order.map(\.id) else { return note(.spaceOrder, .changed, scope.order.count, ids.count) }
        var result = Evidence.confirmed
        for (live, original) in zip(spaces, scope.order) {
            let expectedType = original.ordinaryUUID != nil ? 0 : 4
            if let type = live["type"] as? Int {
                if type != expectedType { return note(.recordType, .changed, expectedType, type) }
            } else { result = note(.recordType, .fullRosterRequired) }
            if let uuid = (live["uuid"] as? String).flatMap(UUID.init(uuidString:)) {
                if uuid != (original.ordinaryUUID ?? original.fullscreenUUID) { return note(.recordUUID, .changed) }
            } else { result = note(.recordUUID, .fullRosterRequired) }
        }
        return note(.spaceInventory, result, scope.order.count, spaces.count)
    }

    static func membership(number: UInt32, record: UInt64, forward: [UInt64]?, reverse: [UInt32]?,
                           point: Finding.Point = .opening, trace: Trace = Trace()) -> Evidence {
        var f = Evidence.fullRosterRequired
        if let forward, !forward.isEmpty, forward.count <= 256, !forward.contains(0), Set(forward).count == forward.count {
            f = forward == [record] ? .confirmed : .changed
        }
        let matches = reverse?.filter { $0 == number }.count
        var r = Evidence.fullRosterRequired
        if let reverse, reverse.count <= 8192, !reverse.contains(0) {
            if matches == 0 { r = .changed }
            if matches == 1 { r = .confirmed }
        }
        return decide(trace.note(point, .forwardMembership, f, 1, forward?.count),
                      trace.note(point, .reverseMembership, r, 1, matches))
    }

    typealias Physical = (displays: [DisplayObservation], separate: Bool, fingerprint: String)
    static func physical(_ actual: Physical?, for scope: OrdinaryFocusScope, point: Finding.Point, trace: Trace) -> Evidence {
        let state = topology(actual?.fingerprint, for: scope)
        if let actual, let expected = scope.physicalDisplay, state != .confirmed || trace.includeConfirmed {
            func note(_ reason: Finding.Reason, _ agree: Bool, _ wanted: Int? = nil, _ observed: Int? = nil) {
                _ = trace.note(point, reason, agree ? .confirmed : .changed, wanted, observed)
            }
            note(.physicalDisplayCount, actual.displays.count == 1, 1, actual.displays.count)
            if let screen = actual.displays.first {
                note(.physicalDisplayID, expected.id == screen.id)
                let mask = frameMask(screen.frame, expected.frame)
                note(.physicalFrame, mask == 0, 0, mask)
                if let a = screen.usable, let b = expected.usable {
                    let usable = frameMask(a, b)
                    note(.usableFrame, usable == 0, 0, usable)
                } else if screen.usable != expected.usable { note(.usableFrame, false) }
                note(.backingScale, screen.backingScale == expected.backingScale)
                note(.rotation, screen.rotationDegrees == expected.rotationDegrees, expected.rotationDegrees, screen.rotationDegrees)
            }
            note(.separateSpaces, scope.separateSpaces == actual.separate)
        }
        return trace.note(point, .physicalTopology, state)
    }

    private static func readPhysical(windowlessHelper: Bool) -> Physical? {
        MainActor.assumeIsolated {
            // Match the AppKit state of the windowless desktop reader that published the fingerprint.
            let app = NSApplication.shared
            if windowlessHelper && app.activationPolicy() != .prohibited { app.setActivationPolicy(.prohibited) }
            guard let sample = try? DesktopDisplayTopology() else { return nil }
            return (sample.displays, sample.separateSpaces, sample.fingerprint)
        }
    }

    package static func inspect(_ scope: OrdinaryFocusScope, number: UInt32, trace: Trace, windowlessHelper: Bool = true,
                        selectedWindow: () throws -> Evidence) rethrows -> Evidence {
        guard let record = UInt64(scope.desktop.record), record > 0 else { return trace.note(.opening, .currentRecord, .changed) }
        let before = physical(readPhysical(windowlessHelper: windowlessHelper), for: scope, point: .opening, trace: trace)
        if before == .changed { return .changed }
        func stage(_ point: Finding.Point) -> Evidence {
            let value = StageManagerPreference.read()
            return trace.note(point, .stagePreference, value.map { $0 ? Evidence.changed : .confirmed } ?? .fullRosterRequired,
                              0, value.map { $0 ? 1 : 0 })
        }
        let firstStage = stage(.opening)
        if firstStage == .changed { return .changed }
        let available = NPReadOnlySpacesOpen() == 1
        let opening = inventory(available ? NPReadInventory() as? [[String: Any]] : nil, for: scope, point: .opening, trace: trace)
        if opening == .changed { return .changed }
        let first = available ? NPReadWindowSpaces(number) as? [UInt64] : nil
        let reverse = available ? NPReadCatalogSpaceWindowNumbers(record) as? [UInt32] : nil
        let exact = try selectedWindow()
        if exact == .changed { return .changed }
        let second = available ? NPReadWindowSpaces(number) as? [UInt64] : nil
        let closing = inventory(available ? NPReadInventory() as? [[String: Any]] : nil, for: scope, point: .closing, trace: trace)
        return decide(before, firstStage, opening, exact, membership(number: number, record: record, forward: first, reverse: reverse, point: .opening, trace: trace),
                      membership(number: number, record: record, forward: second, reverse: reverse, point: .closing, trace: trace), closing,
                      physical(readPhysical(windowlessHelper: windowlessHelper), for: scope, point: .closing, trace: trace), stage(.closing))
    }

    static func retainedIdentity(_ number: UInt32, candidates: [(number: UInt32?, original: Bool)]) -> Evidence {
        let matches = candidates.filter { $0.number == number }
        if matches.count > 1 || matches.contains(where: { !$0.original }) ||
            candidates.contains(where: { $0.original && $0.number != nil && $0.number != number }) { return .changed }
        guard candidates.allSatisfy({ $0.number != nil }) else { return .fullRosterRequired }
        return matches.isEmpty ? .changed : .confirmed
    }

    static func frameMask(_ actual: SurfaceRect, _ expected: SurfaceRect) -> Int {
        (actual.x == expected.x ? 0 : 1) | (actual.y == expected.y ? 0 : 2) |
            (actual.width == expected.width ? 0 : 4) | (actual.height == expected.height ? 0 : 8)
    }

    static func surface(owner: Int32, pid: Int32, layer: Int, visible: Bool?, drawn: Bool?,
                        frame: SurfaceRect, expected: SurfaceRect, trace: Trace = Trace()) -> Evidence {
        func flag(_ reason: Finding.Reason, _ value: Bool?) -> Evidence {
            trace.note(.surface, reason, value.map { $0 ? Evidence.confirmed : .changed } ?? .fullRosterRequired, 1, value.map { $0 ? 1 : 0 })
        }
        let mask = frameMask(frame, expected)
        return decide(flag(.surfaceOwner, owner == pid), trace.note(.surface, .surfaceLayer, layer == 0 ? .confirmed : .changed, 0, layer),
                      flag(.surfaceVisibility, visible), flag(.surfaceAlpha, drawn),
                      trace.note(.surface, .surfaceFrame, mask == 0 ? .confirmed : .changed, 0, mask))
    }

    package static func original(_ id: ManagedWindowID, element: AXUIElement, frame: SurfaceRect, display: String, trace: Trace) -> Evidence {
        let presented = WindowSurfaceRecord(number: id.number).map {
            surface(owner: $0.pid, pid: id.pid, layer: $0.layer, visible: $0.reportedOnscreen, drawn: $0.reportedAlpha.map { $0 > 0 },
                    frame: $0.frame, expected: frame, trace: trace)
        } ?? trace.note(.surface, .surfaceMissing, .fullRosterRequired)
        let currentDisplay = try? displayID(frame)
        let screen = trace.note(.surface, .frameDisplay, currentDisplay.map { $0 == display ? Evidence.confirmed : .changed } ?? .fullRosterRequired)
        if decide(presented, screen) == .changed { return .changed }
        guard let list = try? windows(id.pid) else { return trace.note(.retainedAX, .axList, .fullRosterRequired) }
        let candidates = list.map { (number: number($0), original: CFEqual($0, element)) }
        let original = trace.note(.retainedAX, .originalElement, retainedIdentity(id.number, candidates: candidates),
                                  1, candidates.filter { $0.number == id.number && $0.original }.count)
        if original == .changed { return .changed }
        guard let fields = OrdinaryFocusAttributes(element) else {
            let required: [(String, String)] = [(kAXRoleAttribute, kAXWindowRole), (kAXSubroleAttribute, kAXStandardWindowSubrole)]
            let wrongRole = required.contains { key, expected in (attribute(element, key) as? String).map { $0 != expected } == true }
            let excluded = [kAXModalAttribute, "AXFullScreen"].contains { attribute(element, $0) as? Bool == true }
            return trace.note(.retainedAX, .axRole, wrongRole || excluded ? .changed : .fullRosterRequired)
        }
        let ax = SurfaceRect(x: fields.frame.minX, y: fields.frame.minY, width: fields.frame.width, height: fields.frame.height)
        let mask = frameMask(ax, frame)
        return decide(presented, screen, original, trace.note(.retainedAX, .axFrame, mask == 0 ? .confirmed : .changed, 0, mask),
                      trace.note(.retainedAX, .axMinimized, fields.minimized.map { $0 ? Evidence.changed : .confirmed } ?? .fullRosterRequired,
                                 0, fields.minimized.map { $0 ? 1 : 0 }))
    }
}
