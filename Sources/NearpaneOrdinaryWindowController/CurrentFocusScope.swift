import AppKit
import CReadOnlySpaces
import NearpaneCore

/// Metadata for one selected window. The reverse query returns numbers for one Space;
/// neither its other windows' owners nor the other applications' AX trees are opened.
enum CurrentFocusScope {
    typealias Evidence = OrdinaryFocusScopeEvidence

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

    static func inventory(_ rows: [[String: Any]]?, for scope: OrdinaryFocusScope) -> Evidence {
        guard let rows, !rows.isEmpty, let display = UUID(uuidString: scope.desktop.display) else { return .fullRosterRequired }
        let displays = rows.compactMap { ($0["Display Identifier"] as? String).flatMap(UUID.init(uuidString:)) }
        guard displays.count == rows.count, Set(displays).count == rows.count else { return .fullRosterRequired }
        guard displays == [display] else { return .changed }
        let row = rows[0]
        guard let current = row["Current Space"] as? [String: Any], let currentNumber = current["id64"] as? UInt64 else {
            return .fullRosterRequired
        }
        guard String(currentNumber) == scope.desktop.record else { return .changed }
        if let type = current["type"] as? Int, type != 0 { return .changed }
        if let raw = current["uuid"] {
            guard let uuid = (raw as? String).flatMap(UUID.init(uuidString:)) else { return .fullRosterRequired }
            if scope.desktop.uuid != uuid { return .changed }
        }
        guard let spaces = row["Spaces"] as? [[String: Any]], !spaces.isEmpty, spaces.count <= 256 else { return .fullRosterRequired }
        let ids = spaces.compactMap { $0["id64"] as? UInt64 }
        guard ids.count == spaces.count, !ids.contains(0), Set(ids).count == spaces.count else { return .fullRosterRequired }
        guard ids.map(String.init) == scope.order.map(\.id) else { return .changed }
        var result = Evidence.confirmed
        for (live, original) in zip(spaces, scope.order) {
            if let type = live["type"] as? Int {
                if type != (original.ordinaryUUID != nil ? 0 : 4) { return .changed }
            } else { result = .fullRosterRequired }
            if let uuid = (live["uuid"] as? String).flatMap(UUID.init(uuidString:)) {
                if uuid != (original.ordinaryUUID ?? original.fullscreenUUID) { return .changed }
            } else { result = .fullRosterRequired }
        }
        return result
    }

    static func membership(number: UInt32, record: UInt64, forward: [UInt64]?, reverse: [UInt32]?) -> Evidence {
        // A missing getter cannot obscure a positively witnessed move, reassignment, or loss of exclusivity.
        var result = Evidence.confirmed
        if let forward, !forward.isEmpty, forward.count <= 256, !forward.contains(0), Set(forward).count == forward.count {
            if forward != [record] { return .changed }
        } else { result = .fullRosterRequired }
        if let reverse, reverse.count <= 8192, !reverse.contains(0) {
            switch reverse.filter({ $0 == number }).count {
            case 0: return .changed
            case 1: break
            default: result = .fullRosterRequired
            }
        } else { result = .fullRosterRequired }
        return result
    }

    static func displayFingerprint() -> String? {
        // This worker serves its command pipe on its main CFRunLoop.
        MainActor.assumeIsolated { try? DesktopDisplayTopology().fingerprint }
    }

    static func inspect(_ scope: OrdinaryFocusScope, number: UInt32, selectedWindow: () throws -> Evidence) rethrows -> Evidence {
        guard let record = UInt64(scope.desktop.record), record > 0 else { return .changed }
        let before = topology(displayFingerprint(), for: scope)
        if before == .changed { return .changed }
        let stage = StageManagerPreference.read()
        if stage == true { return .changed }
        let available = NPReadOnlySpacesOpen() == 1
        let opening = inventory(available ? NPReadInventory() as? [[String: Any]] : nil, for: scope)
        if opening == .changed { return .changed }
        let first = available ? NPReadWindowSpaces(number) as? [UInt64] : nil
        let reverse = available ? NPReadCatalogSpaceWindowNumbers(record) as? [UInt32] : nil
        let exactWindow = try selectedWindow()
        if exactWindow == .changed { return .changed }
        let second = available ? NPReadWindowSpaces(number) as? [UInt64] : nil
        let closing = inventory(available ? NPReadInventory() as? [[String: Any]] : nil, for: scope)
        let endStage = StageManagerPreference.read()
        return decide(before, opening, exactWindow, membership(number: number, record: record, forward: first, reverse: reverse),
                      membership(number: number, record: record, forward: second, reverse: reverse), closing,
                      topology(displayFingerprint(), for: scope),
                      endStage == true ? .changed : (stage == false && endStage == false ? .confirmed : .fullRosterRequired))
    }

    static func retainedIdentity(_ number: UInt32, candidates: [(number: UInt32?, original: Bool)]) -> Evidence {
        let matches = candidates.filter { $0.number == number }
        if matches.count > 1 || matches.contains(where: { !$0.original }) ||
            candidates.contains(where: { $0.original && $0.number != nil && $0.number != number }) { return .changed }
        guard candidates.allSatisfy({ $0.number != nil }) else { return .fullRosterRequired }
        return matches.isEmpty ? .changed : .confirmed
    }

    static func surface(owner: Int32, pid: Int32, layer: Int, visible: Bool, drawn: Bool,
                        frame: SurfaceRect, expected: SurfaceRect) -> Evidence {
        owner == pid && layer == 0 && visible && drawn && frame == expected ? .confirmed : .changed
    }

    static func original(_ id: ManagedWindowID, element: AXUIElement, frame: SurfaceRect, display: String) -> Evidence {
        let presented = WindowSurfaceRecord(number: id.number).map {
            surface(owner: $0.pid, pid: id.pid, layer: $0.layer, visible: $0.isOnscreen, drawn: $0.isDrawn,
                    frame: $0.frame, expected: frame)
        } ?? .fullRosterRequired
        let screen = (try? displayID(frame)).map { $0 == display ? Evidence.confirmed : .changed } ?? .fullRosterRequired
        if decide(presented, screen) == .changed { return .changed }
        guard let list = try? windows(id.pid) else { return .fullRosterRequired }
        let original = retainedIdentity(id.number, candidates: list.map { (number($0), CFEqual($0, element)) })
        if original == .changed { return .changed }
        guard let fields = OrdinaryFocusAttributes(element) else {
            let required: [(String, String)] = [(kAXRoleAttribute, kAXWindowRole), (kAXSubroleAttribute, kAXStandardWindowSubrole)]
            if required.contains(where: { key, expected in (attribute(element, key) as? String).map { $0 != expected } == true }) ||
                [kAXModalAttribute, "AXFullScreen"].contains(where: { attribute(element, $0) as? Bool == true }) { return .changed }
            return .fullRosterRequired
        }
        let ax = SurfaceRect(x: fields.frame.minX, y: fields.frame.minY, width: fields.frame.width, height: fields.frame.height)
        guard fields.minimized != true, ax == frame else { return .changed }
        return decide(presented, screen, original, fields.minimized == false ? .confirmed : .fullRosterRequired)
    }
}
