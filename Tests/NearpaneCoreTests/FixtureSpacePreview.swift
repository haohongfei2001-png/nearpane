import Foundation
import CoreGraphics
@testable import NearpaneCore

/// Geometry experiment only. A fixture explicitly supplies row semantics, the usable display frame
/// in display-local top-left points, and front-to-back order. P1 cannot supply these for real Spaces yet.
struct FixtureSpacePreview {
    struct Plan {
        let spaceID, displayID: String
        let usable: CGRect
        let frontToBack: [String]
    }
    struct Window {
        let id: String
        let frame: CGRect
        let exposed: [CGRect]
    }
    struct Row {
        let spaceID: String
        let desktop: CGRect
        let windows: [Window]
    }
    enum Hit: Equatable { case space(DesktopTarget), window(DesktopTarget) }
    private let snapshot: DesktopSnapshot
    let rows: [Row]

    init?(snapshot: DesktopSnapshot, plans: [Plan], in viewport: CGRect, now: Date) {
        guard snapshot.isStructurallyValid, snapshot.source == "synthetic-fixture",
              snapshot.identityConfidence == .synthetic, snapshot.capabilities.observation == .mockOnly,
              snapshot.effectiveFreshness(at: now) == .fresh, !plans.isEmpty,
              Set(plans.map(\.spaceID)).count == plans.count, Self.valid(viewport) else { return nil }
        self.snapshot = snapshot
        let height = viewport.height / CGFloat(plans.count)
        var projected: [Row] = []
        for (index, plan) in plans.enumerated() {
            guard let display = snapshot.displays.first(where: { $0.id == plan.displayID }),
                  snapshot.scopes.contains(where: { $0.displayID == display.id && $0.records.contains { $0.id == plan.spaceID } }),
                  Self.valid(plan.usable), CGRect(x: 0, y: 0, width: display.frame.width, height: display.frame.height).contains(plan.usable)
            else { return nil }
            let scale = min(viewport.width / plan.usable.width, height / plan.usable.height)
            let size = CGSize(width: plan.usable.width * scale, height: plan.usable.height * scale)
            let desktop = CGRect(x: viewport.midX - size.width/2,
                y: viewport.minY + height * CGFloat(index) + (height - size.height)/2, width: size.width, height: size.height)
            var frames: [String: CGRect] = [:]
            for window in snapshot.windows where window.displayID == display.id {
                guard case .known(let spaces) = window.membership else { return nil }
                guard spaces.contains(plan.spaceID) else { continue }
                guard window.confidence == .synthetic else { return nil }
                let b = window.bounds
                let visible = CGRect(x: b.x, y: b.y, width: b.width, height: b.height).intersection(plan.usable)
                guard !visible.isEmpty else { continue }
                frames[window.id] = CGRect(x: desktop.minX + (visible.minX - plan.usable.minX) * scale,
                    y: desktop.minY + (visible.minY - plan.usable.minY) * scale,
                    width: visible.width * scale, height: visible.height * scale)
            }
            guard frames.count == plan.frontToBack.count, Set(plan.frontToBack) == Set(frames.keys) else { return nil }
            var windows: [Window] = []
            for id in plan.frontToBack {
                guard let frame = frames[id] else { return nil }
                let exposed = windows.reduce([frame]) { portions, front in
                    portions.flatMap { Self.subtract(front.frame, from: $0) }
                }
                windows.append(Window(id: id, frame: frame, exposed: exposed))
            }
            projected.append(Row(spaceID: plan.spaceID, desktop: desktop, windows: windows))
        }
        self.rows = projected
    }

    func hit(at point: CGPoint, current: DesktopSnapshot, now: Date) -> Hit? {
        guard current == snapshot, current.effectiveFreshness(at: now) == .fresh,
              let row = rows.first(where: { $0.desktop.contains(point) }) else { return nil }
        func target(_ id: String) -> DesktopTarget {
            DesktopTarget(sessionID: current.sessionID, revision: current.revision, runtimeID: id)
        }
        if let window = row.windows.first(where: { $0.frame.contains(point) }) { return .window(target(window.id)) }
        return .space(target(row.spaceID))
    }

    private static func valid(_ r: CGRect) -> Bool {
        [r.origin.x, r.origin.y, r.size.width, r.size.height].allSatisfy(\.isFinite) && r.size.width > 0 && r.size.height > 0
    }

    private static func subtract(_ cover: CGRect, from frame: CGRect) -> [CGRect] {
        let overlap = cover.intersection(frame)
        guard !overlap.isEmpty else { return [frame] }
        return [
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: overlap.minY - frame.minY),
            CGRect(x: frame.minX, y: overlap.maxY, width: frame.width, height: frame.maxY - overlap.maxY),
            CGRect(x: frame.minX, y: overlap.minY, width: overlap.minX - frame.minX, height: overlap.height),
            CGRect(x: overlap.maxX, y: overlap.minY, width: frame.maxX - overlap.maxX, height: overlap.height)
        ].filter { !$0.isEmpty }
    }
}
