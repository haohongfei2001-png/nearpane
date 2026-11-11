import Foundation
import WindowGeometryCore

public enum DesktopRowKind: Equatable, Sendable {
    case witnessedSpace(String), visibleDisplay
}

public struct DesktopPreviewWindow: Equatable, Sendable {
    public let id: String
    public let frame: SurfaceRect
    public let confidence: IdentityConfidence
}

public struct DesktopPreviewRow: Sendable {
    public let displayID: String
    public let kind: DesktopRowKind
    public let rowFrame: SurfaceRect
    public let desktop: SurfaceRect
    /// Frontmost first. Unknown-membership windows are never attributed to a witnessed Space.
    public let windows: [DesktopPreviewWindow]
    public let hasUnassignedWindows: Bool
    fileprivate let regions: [HitRegion]
}

public struct DesktopPreview: Sendable {
    private let snapshot: DesktopSnapshot
    public let rows: [DesktopPreviewRow]

    public init?(snapshot: DesktopSnapshot, displayID: String?, viewport: SurfaceRect, now: Date, uptime: Double,
                 restrictToDisplay: Bool = false, rowGap: Double = 6, rowViewport: SurfaceRect? = nil) {
        guard snapshot.isStructurallyValid, snapshot.nativeIsFresh(now: now, uptime: uptime), let native = snapshot.native,
              !native.windowLimitReached, viewport.geometry.isValid else { return nil }
        let plans: [(String, DesktopRowKind)]
        let witnesses = native.rows.filter { !restrictToDisplay || $0.displayID == displayID }
        if witnesses.isEmpty {
            guard let displayID, snapshot.displays.contains(where: { $0.id == displayID }) else { return nil }
            plans = [(displayID, .visibleDisplay)]
        } else {
            plans = witnesses.map { ($0.displayID, .witnessedSpace($0.recordID)) }
        }
        let gap = min(max(0, rowGap), viewport.height / Double(plans.count * 6))
        let height = (viewport.height - Double(plans.count - 1) * gap) / Double(plans.count)
        var result = [DesktopPreviewRow]()
        for (index, plan) in plans.enumerated() {
            guard let display = snapshot.displays.first(where: { $0.id == plan.0 }), let usable = display.usable else { return nil }
            let source = Rect(display.frame.x + usable.x, display.frame.y + usable.y, usable.width, usable.height)
            let slot = Rect(viewport.x, viewport.y + Double(index) * (height + gap), viewport.width, height)
            guard let map = try? PreviewTransform(source: source, viewport: slot) else { return nil }
            var shapes = [DesktopPreviewWindow](), regions = [HitRegion](), unknown = false
            for w in snapshot.windows.sorted(by: { ($0.metadata?.frontToBack ?? .max) < ($1.metadata?.frontToBack ?? .max) }) {
                guard let m = w.metadata, let clip = source.intersection(m.globalFrame.geometry),
                      let geometry = try? map.project(clip) else { continue }
                var belongs = true
                if case let .witnessedSpace(id) = plan.1 {
                    switch w.membership {
                    case .known(let ids): guard ids.contains(id) else { continue }
                    case .unknown: belongs = false; unknown = true
                    }
                }
                // Unassigned shapes may occlude a physical point. They cannot become a target behind a front window.
                regions.append(.init(key: w.id, bounds: geometry, frontToBackIndex: m.frontToBack,
                    identityEligible: plan.1 != .visibleDisplay && belongs && w.confidence == .corroboratedMetadata &&
                                      m.presentation == .confirmed && m.minimized == false && m.fullScreen == false))
                if belongs { shapes.append(.init(id: w.id, frame: SurfaceRect(geometry), confidence: w.confidence)) }
            }
            let rowFrame = rowViewport.map { full in
                let rowHeight = (full.height - Double(plans.count - 1) * gap) / Double(plans.count)
                return SurfaceRect(x:full.x,y:full.y + Double(index) * (rowHeight + gap),width:full.width,height:rowHeight)
            } ?? SurfaceRect(slot)
            guard rowFrame.geometry.isValid else { return nil }
            result.append(.init(displayID: display.id, kind: plan.1, rowFrame:rowFrame, desktop: SurfaceRect(map.content),
                                windows: shapes, hasUnassignedWindows: unknown, regions: regions))
        }
        self.snapshot = snapshot; rows = result
    }

    /// Pure geometry query for verification. This type has no action provider.
    public func hit(x: Double, y: Double, current: DesktopSnapshot, now: Date, uptime: Double) -> HitResult {
        let p = Point(x, y)
        guard current == snapshot, current.nativeIsFresh(now: now, uptime: uptime),
              let row = rows.first(where: { $0.desktop.geometry.contains(p) }) else { return .none }
        return (try? HitTesting.hit(p, regions: row.regions)) ?? .none
    }
}

public extension DesktopSnapshot {
    func presentationDemand(for displayID: String, now: Date, uptime: Double) -> DisplayDemand {
        guard isStructurallyValid, nativeIsFresh(now: now, uptime: uptime), let native, !native.windowLimitReached else { return .init() }
        let onDisplay = windows.filter { $0.displayID == displayID }
        if onDisplay.contains(where: { $0.metadata?.fullScreen == true && $0.metadata?.minimized == false }) {
            return .init(blocked: true)
        }
        let records = Set(native.rows.filter { $0.displayID == displayID }.map(\.recordID))
        let eligible = onDisplay.filter { w in
            guard w.metadata?.presentation == .confirmed, ManagedWindowID(w) != nil, case let .known(ids) = w.membership else { return false }
            return ids.count == 1 && records.contains(ids[0])
        }
        // A lone witnessed current record says nothing about the number of other desktops.
        let inventory = scopes.filter { $0.displayID == displayID }
        let complete = records.count == 1 && inventory.count == 1 && inventory[0].records.count == 1 &&
            native.accessibility == .available && onDisplay.count == eligible.count
        return .init(spaces: records.count, windows: eligible.count, complete: complete)
    }
}
