import Foundation
import WindowGeometryCore

public enum DesktopRowKind: Equatable, Sendable {
    case witnessedSpace(String), previouslyWitnessedSpace(String), visibleDisplay
}

public struct DesktopPreviewWindow: Equatable, Sendable {
    public let id: String
    public let frame: SurfaceRect
    public let confidence: IdentityConfidence
    public let presentation: WindowPresentationGeometry
    /// Geometry and identity prerequisite only. It does not grant permission to read pixels.
    public let canShowContent: Bool
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
        let displays = snapshot.displays.filter { !restrictToDisplay || $0.id == displayID }
        let plans = displays.flatMap { display in
            snapshot.previewRowKinds(for: display.id, allowVisibleFallback: display.id == displayID)
                .map { (display.id, $0) }
        }
        guard !plans.isEmpty else { return nil }
        let gap = min(max(0, rowGap), viewport.height / Double(plans.count * 6))
        let height = (viewport.height - Double(plans.count - 1) * gap) / Double(plans.count)
        var result = [DesktopPreviewRow]()
        for (index, plan) in plans.enumerated() {
            guard let display = snapshot.displays.first(where: { $0.id == plan.0 }), let usable = display.usable else { return nil }
            let source = Rect(display.frame.x + usable.x, display.frame.y + usable.y, usable.width, usable.height)
            let slot = Rect(viewport.x, viewport.y + Double(index) * (height + gap), viewport.width, height)
            guard let map = try? PreviewTransform(source: source, viewport: slot) else { return nil }
            var shapes = [DesktopPreviewWindow](), regions = [HitRegion](), unknown = false
            // The reader enumerates visible windows. A background desktop's current
            // layout cannot be reconstructed from the foreground sample.
            let visibleWindows: [WindowObservation]
            if case .previouslyWitnessedSpace = plan.1 { visibleWindows = [] } else { visibleWindows = snapshot.windows }
            for w in visibleWindows.sorted(by: { ($0.metadata?.frontToBack ?? .max) < ($1.metadata?.frontToBack ?? .max) }) {
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
                if belongs {
                    shapes.append(.init(id: w.id, frame: SurfaceRect(geometry), confidence: w.confidence,
                                        presentation: m.presentation, canShowContent: w.canWitnessCurrentSpace))
                }
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
    /// Mission Control exposes each visible window on the active desktop, including a fully overlapped sibling.
    /// This public observation works even when the optional private Space inventory is disabled.
    func currentDesktopWindows(on displayID: String, now: Date, uptime: Double) -> [WindowObservation] {
        guard isStructurallyValid, nativeIsFresh(now: now, uptime: uptime), native?.windowLimitReached == false else { return [] }
        let current = native?.rows.first { $0.displayID == displayID }?.recordID
        return windows.filter { window in
            guard window.displayID == displayID, let m = window.metadata, m.number > 0, m.fullScreen != true else { return false }
            let publiclyVisible = m.onActiveDesktop == true && m.isOnscreen == true && m.minimized != true
            guard publiclyVisible || m.overviewSpaceID != nil else { return false }
            if let current, case .known(let records) = window.membership { return records.contains(current) }
            return true
        }.sorted { a, b in
            // WindowServer IDs preserve the ordering when raising changes the stacking order.
            (a.metadata?.number ?? 0) < (b.metadata?.number ?? 0)
        }
    }

    func desktopPreviewRowCount(for displayID: String?) -> Int {
        displayID.map { previewRowKinds(for: $0, allowVisibleFallback: true).count } ?? 0
    }

    fileprivate func previewRowKinds(for displayID: String, allowVisibleFallback: Bool) -> [DesktopRowKind] {
        let witness = native?.rows.first { $0.displayID == displayID }
        let records = scopes.first { $0.displayID == displayID }?.records ?? []
        var result = records.compactMap { record -> DesktopRowKind? in
            if record.isCurrent {
                if witness?.recordID == record.id { return .witnessedSpace(record.id) }
                return allowVisibleFallback ? .visibleDisplay : nil
            }
            return record.previouslyWitnessed ? .previouslyWitnessedSpace(record.id) : nil
        }
        if result.isEmpty && allowVisibleFallback { result.append(.visibleDisplay) }
        return result
    }

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
        let previouslyWitnessed = inventory.flatMap(\.records).filter(\.previouslyWitnessed).count
        var demand = DisplayDemand(spaces: records.count + previouslyWitnessed, windows: eligible.count, complete: complete)
        demand.hasCurrentDesktopWindows = !currentDesktopWindows(on: displayID, now: now, uptime: uptime).isEmpty
        return demand
    }
}
