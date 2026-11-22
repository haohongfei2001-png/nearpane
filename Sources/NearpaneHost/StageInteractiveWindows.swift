import AppKit
import NearpaneOrdinaryWindowRuntime

/// Exact AX references plus WindowServer and the signed application's local window generations.
@MainActor struct StageInteractiveWindows {
    struct Row: Decodable {
        let role: String, window: UInt32, lifetime: UUID, frame: [Double]
        let sameOriginal, visible, onActiveSpace, minimized, key, main, firstResponderIsContent, acceptsMouse: Bool
        let alpha: Double
        var rect: CGRect? {
            guard frame.count == 4, frame.allSatisfy(\.isFinite), frame[2] >= 100, frame[3] >= 80 else { return nil }
            return CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
        }
        var eligible: Bool { window > 0 && sameOriginal && visible && onActiveSpace && !minimized && alpha == 1 && acceptsMouse && rect != nil }
    }
    struct Bound {
        let row: Row, element: AXUIElement, ax: CGRect, cg: CGRect
        var evidence: [String: Any] {
            func fields(_ r: CGRect) -> [Double] { [r.minX,r.minY,r.width,r.height] }
            return ["role":row.role,"window":row.window,"fixtureLifetime":row.lifetime.uuidString,
                    "fixtureFrame":row.frame,"originalAXFrame":fields(ax),"windowServerFrame":fields(cg),
                    "fixtureKey":row.key,"fixtureMain":row.main,"fixtureContentFirstResponder":row.firstResponderIsContent]
        }
    }
    let rows: [Bound]
    static func evidence(_ raw: Any?) -> [[String: Any]] {
        guard let raw, JSONSerialization.isValidJSONObject(raw),
              let local = try? JSONDecoder().decode([Row].self, from: JSONSerialization.data(withJSONObject: raw)),
              local.count == 2, local.map(\.role) == ["target","sibling"] else { return [] }
        return local.map { ["role":$0.role,"window":$0.window,"lifetime":$0.lifetime.uuidString,"frame":$0.frame,
                            "sameOriginal":$0.sameOriginal,"key":$0.key,"main":$0.main,"firstResponderIsContent":$0.firstResponderIsContent] }
    }
    static func decoded(_ raw: Any?) throws -> [Row] {
        guard let raw, JSONSerialization.isValidJSONObject(raw),
              let rows = try? JSONDecoder().decode([Row].self, from: JSONSerialization.data(withJSONObject: raw)),
              rows.map(\.role) == ["target","sibling"], rows.allSatisfy(\.eligible),
              Set(rows.map(\.window)).count == 2, Set(rows.map(\.lifetime)).count == 2,
              let a = rows[0].rect, let b = rows[1].rect, !a.intersects(b)
        else { throw StagePairRefusal("twoDistinctOrdinaryFixtureRowsRequired") }
        return rows
    }
    static func equalFrame(_ x: CGRect, _ y: CGRect) -> Bool {
        zip([x.minX,x.minY,x.width,x.height], [y.minX,y.minY,y.width,y.height]).allSatisfy { $0.isFinite && $1.isFinite && abs($0-$1) <= 0.75 }
    }
    private static func attr(_ e: AXUIElement,_ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e,key as CFString,&value) == .success ? value : nil
    }
    private static func axFrame(_ e: AXUIElement) -> CGRect? {
        guard let a = attr(e,kAXPositionAttribute), let b = attr(e,kAXSizeAttribute),
              CFGetTypeID(a) == AXValueGetTypeID(), CFGetTypeID(b) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(a as! AXValue,.cgPoint,&point), AXValueGetValue(b as! AXValue,.cgSize,&size) else { return nil }
        return CGRect(origin:point,size:size)
    }
    init(raw: Any?, pid: Int32, previous: Self? = nil) throws {
        let local = try Self.decoded(raw)
        let application = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(application, 0.18) == .success,
              let windows = Self.attr(application,kAXWindowsAttribute) as? [AXUIElement] else {
            throw StagePairRefusal("registeredFixtureAXWindowsUnavailable")
        }
        let standard = windows.filter { Self.attr($0,kAXRoleAttribute) as? String == kAXWindowRole &&
                                       Self.attr($0,kAXSubroleAttribute) as? String == kAXStandardWindowSubrole }
        guard standard.count >= 2 else { throw StagePairRefusal("fixtureAXRosterNotYetComplete") }
        guard standard.count == 2 else { throw StagePairRefusal("unexpectedStandardFixtureWindowCount") }
        rows = try local.enumerated().map { i, row in
            let exact = standard.filter { NearpaneOrdinaryWindowRuntime.number($0) == row.window }
            var owner = pid_t()
            guard exact.count == 1, let element = exact.first, AXUIElementGetPid(element,&owner) == .success, owner == pid,
                  Self.attr(element,kAXMinimizedAttribute) as? Bool == false,
                  Self.attr(element,"AXFullScreen") as? Bool == false,
                  let ax = Self.axFrame(element), let own = row.rect, Self.equalFrame(ax, own),
                  let cgRows = CGWindowListCopyWindowInfo(.optionIncludingWindow,row.window) as? [[String: Any]],
                  StageCanaryOverview.matchesForeground(cgRows,pid:pid,number:row.window),
                  let bounds = cgRows[0][kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation:bounds as CFDictionary), Self.equalFrame(ax,cg)
            else { throw StagePairRefusal("fixtureAXAndWindowServerGeometryDisagree") }
            if let previous {
                let old = previous.rows[i]
                guard CFEqual(old.element, element), old.row.window == row.window, old.row.lifetime == row.lifetime,
                      Self.equalFrame(old.ax,ax), Self.equalFrame(old.cg,cg) else { throw StagePairRefusal("registeredWindowOrGeometryChanged") }
            }
            return .init(row:row, element:element, ax:ax, cg:cg)
        }
    }
    static func removed(_ ids: [UInt32]) -> Bool {
        ids.count == 2 && Set(ids).count == 2 && ids.allSatisfy { id in
            guard id > 0, let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] else { return false }
            return rows.isEmpty
        }
    }
}
