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
            // The catalogue includes other Spaces and Stage Manager's strip. Only actual
            // presented frames belong in this screen's map. Unknown foreground surfaces
            // can still block hits at their observed location.
            let activeIDs: Set<String>? = native.catalogComplete.map { _ in
                Set(snapshot.activeSpaceWindows(on: display.id, now: now, uptime: uptime).map(\.id))
            }
            let visibleWindows: [WindowObservation]
            if case .previouslyWitnessedSpace = plan.1 {
                visibleWindows = []
            } else if let activeIDs {
                visibleWindows = snapshot.windows.filter { w in
                    guard w.displayID == display.id, let m = w.metadata, m.hasCatalogGeometry == true else { return false }
                    return activeIDs.contains(w.id) || (w.membership == .unknown && m.isOnscreen == true && m.onActiveDesktop == true)
                }
            } else {
                visibleWindows = snapshot.windows
            }
            for w in visibleWindows.sorted(by: { ($0.metadata?.frontToBack ?? .max) < ($1.metadata?.frontToBack ?? .max) }) {
                guard let m = w.metadata, let clip = source.intersection(m.globalFrame.geometry),
                      let geometry = try? map.project(clip) else { continue }
                var belongs = activeIDs?.contains(w.id) ?? true
                if !belongs { unknown = true }
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

    /// Select exactly the frontmost confirmed window under the pointer. An unknown
    /// occluder still covers the point even when it cannot be selected.
    public func presentedWindow(atX x: Double, y: Double, now: Date, uptime: Double) -> WindowObservation? {
        let p = Point(x, y)
        guard snapshot.nativeIsFresh(now: now, uptime: uptime),
              let row = rows.first(where: { $0.desktop.geometry.contains(p) }),
              let hit = try? HitTesting.hit(p, regions: row.regions) else { return nil }
        let id: String
        switch (row.kind, hit) {
        case (_, .candidate(let key)), (.visibleDisplay, .blocked(let key)): id = key
        default: return nil
        }
        guard let window = snapshot.windows.first(where: { $0.id == id && $0.displayID == row.displayID }),
              window.canWitnessCurrentSpace, window.metadata?.onActiveDesktop == true,
              snapshot.native?.catalogComplete == nil || snapshot.isCurrentDesktopWindow(window) else { return nil }
        return window
    }
}

public extension DesktopSnapshot {
    /// Mission Control exposes each visible window on the active desktop, including a fully overlapped sibling.
    /// This public observation works even when the optional private Space inventory is disabled.
    func currentDesktopWindows(on displayID: String, now: Date, uptime: Double) -> [WindowObservation] {
        guard isStructurallyValid, nativeIsFresh(now: now, uptime: uptime), native?.windowLimitReached == false else { return [] }
        return windows.filter { $0.displayID == displayID && isCurrentDesktopWindow($0) }.sorted { a, b in
            // WindowServer IDs preserve the ordering when raising changes the stacking order.
            (a.metadata?.number ?? 0) < (b.metadata?.number ?? 0)
        }
    }

    /// Used by both the card list and capture/selection target construction.
    func isCurrentDesktopWindow(_ window: WindowObservation) -> Bool {
        // The public CG/AppKit lists also contain ordinary-layer auxiliary panels.
        // The catalogue must supply an exact role before publishing a card or target.
        if native?.catalogComplete != nil {
            guard native?.accessibility != .denied, window.metadata?.overviewOrdinaryRole == true,
                  window.metadata?.minimized == false else { return false }
        }
        return isCurrentDesktopSurface(window)
    }

    /// Diagnostic count only. These public surfaces do not become cards, pixels or click targets.
    func unconfirmedCurrentDesktopWindowCount(on displayID: String, now: Date, uptime: Double) -> Int {
        guard native?.population == .workWindows, isStructurallyValid, nativeIsFresh(now: now, uptime: uptime),
              native?.windowLimitReached == false else { return 0 }
        if native?.catalogComplete == nil {
            return windows.filter { $0.displayID == displayID && isCurrentDesktopSurface($0) && !$0.canWitnessCurrentSpace }.count
        }
        return windows.filter {
            $0.displayID == displayID && $0.metadata?.overviewOrdinaryRole != false &&
                isCurrentDesktopSurface($0) && !isCurrentDesktopWindow($0)
        }.count
    }

    /// Visible surface discovery for an already authorized tiling session.
    /// The tiler revalidates the exact AX window before each write.
    func isCurrentDesktopSurface(_ window: WindowObservation) -> Bool {
        guard let m = window.metadata, m.number > 0, m.fullScreen != true, m.minimized != true,
              m.overviewIsPresented != false else { return false }
        let current = scopes.first { $0.displayID == window.displayID }?.records.first(where: \.isCurrent)
        if case let .known(ids) = window.membership, let current, !ids.contains(current.id) { return false }
        if let proof = m.overviewSpaceID {
            guard let current, current.id == proof, current.ordinaryUUID != nil,
                  case let .known(ids) = window.membership, ids.contains(proof) else { return false }
        } else if native?.catalogComplete != nil && native?.spaces == .observed {
            // A functioning native catalogue genuinely identified this display's current
            // record. Do not turn a conflicting or missing membership into an onscreen guess.
            return false
        }
        if m.onActiveDesktop == true && m.isOnscreen == true { return true }
        return native?.accessibility != .denied && m.minimized == false &&
            m.overviewSpaceID != nil && m.overviewIsPresented == true
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

/// Two read-only presentations in one current native fullscreen Space. Frames are measured
/// in top-left display-local logical points, including the actual divider between panes.
public struct NativeSplitViewLayout: Equatable, Sendable {
    public let displayID, spaceID: String
    public let spaceUUID: UUID
    public let displayFrame, leftFrame, rightFrame: SurfaceRect
    public let left, right: WindowObservation
}

public extension DesktopSnapshot {
    private func currentPreviewRecord(on displayID: String) -> SpaceRecord? {
        let scopesOnDisplay = scopes.filter { $0.displayID == displayID }
        guard scopesOnDisplay.count == 1, let record = scopesOnDisplay[0].records.first(where: \.isCurrent),
              let uuid = record.nativeUUID,
              scopes.flatMap(\.records).filter({ $0.nativeUUID == uuid }).count == 1 else { return nil }
        return record
    }

    /// Current regular windows for presentation. Native fullscreen members stay outside
    /// the ordinary-window selection, capture authorization and tiling contracts.
    func activeSpaceWindows(on displayID: String, now: Date, uptime: Double) -> [WindowObservation] {
        guard isStructurallyValid, nativeIsFresh(now: now, uptime: uptime),
              let native, native.population == .workWindows, !native.windowLimitReached,
              let display = displays.first(where: { $0.id == displayID }) else { return [] }
        if displays.count > 1 && separateSpaces != true {
            guard native.accessibility != .denied else { return [] }
            let current = scopes.first(where: { $0.displayID == displayID })?.records.first(where: \.isCurrent)
            guard current?.nativeKind != .fullscreen else { return [] }
            return windows.filter { w in
                guard w.displayID == displayID, let m = w.metadata, m.activeFullscreenSpaceID == nil,
                      m.onActiveDesktop == true && m.isOnscreen == true, m.minimized == false && m.fullScreen == false,
                      display.frame.geometry.intersection(m.globalFrame.geometry) == m.globalFrame.geometry,
                      !displays.contains(where: { $0.id != displayID && $0.frame.geometry.intersection(m.globalFrame.geometry) != nil })
                else { return false }
                if let current, case let .known(ids) = w.membership, !ids.contains(current.id) { return false }
                if native.catalogComplete == nil { return w.canWitnessCurrentSpace }
                return m.overviewIsPresented == true && m.overviewOrdinaryRole == true && m.hasCatalogGeometry == true
            }.sorted { ($0.metadata?.number ?? 0) < ($1.metadata?.number ?? 0) }
        }
        guard native.spaces == .observed, native.catalogComplete != nil else {
            return currentDesktopWindows(on: displayID, now: now, uptime: uptime)
        }
        guard let current = currentPreviewRecord(on: displayID) else { return [] }
        if current.nativeKind == .ordinary { return currentDesktopWindows(on: displayID, now: now, uptime: uptime) }
        guard current.nativeKind == .fullscreen, native.accessibility != .denied else { return [] }
        return windows.filter { w in
            guard w.displayID == displayID, w.membership == .known(recordIDs: [current.id]),
                  let m = w.metadata, m.activeFullscreenSpaceID == current.id, m.isOnscreen == true,
                  m.overviewIsPresented == true, m.overviewOrdinaryRole == true, m.minimized == false,
                  display.frame.geometry.intersection(m.globalFrame.geometry) == m.globalFrame.geometry else { return false }
            return true
        }.sorted { ($0.metadata?.frontToBack ?? .max) < ($1.metadata?.frontToBack ?? .max) }
    }

    func currentSplitView(on displayID: String, now: Date, uptime: Double) -> NativeSplitViewLayout? {
        guard let current = currentPreviewRecord(on: displayID), let uuid = current.fullscreenUUID, let display = displays.first(where: { $0.id == displayID }) else { return nil }
        let active = activeSpaceWindows(on: displayID, now: now, uptime: uptime)
        guard active.count == 2, active.allSatisfy({ $0.metadata?.activeFullscreenSpaceID == current.id &&
              $0.metadata?.hasCatalogGeometry == true }) else { return nil }
        let pair = active.sorted { $0.bounds.x < $1.bounds.x }
        guard let a = pair[0].metadata, let b = pair[1].metadata else { return nil }
        let managed = a.matchesNativeTile == true && b.matchesNativeTile == true
        // Some system inventories omit the tile manager. Two independently confirmed,
        // standard AX fullscreen windows in this same exclusive native Space can corroborate it.
        if !managed {
            guard a.matchesNativeTile == nil && b.matchesNativeTile == nil && a.fullScreen == true && b.fullScreen == true else { return nil }
            // With no explicit tile roster a third unresolved visible surface could be another
            // pane. Offscreen members, auxiliary roles and positively foreign desktops cannot be.
            let unresolved = windows.contains { w in
                guard w.displayID == displayID, w.id != pair[0].id, w.id != pair[1].id, let m = w.metadata,
                      m.isOnscreen == true, m.overviewOrdinaryRole != false, m.minimized != true else { return false }
                if case let .known(ids) = w.membership { return ids.contains(current.id) }
                return true
            }
            guard !unresolved else { return nil }
        }
        let left = pair[0].bounds.geometry, right = pair[1].bounds.geometry
        let gap = right.x - left.maxX
        guard left.isValid, right.isValid, gap >= 0, managed || gap <= 24 else { return nil }
        let full = Rect(0, 0, display.frame.width, display.frame.height)
        let extents = [full, display.usable?.geometry].compactMap { $0 }
        guard extents.contains(where: { area in
            abs(area.x - left.x) <= 2 && abs(area.maxX - right.maxX) <= 2 &&
            abs(left.y - area.y) <= 2 && abs(right.y - area.y) <= 2 &&
            abs(left.maxY - area.maxY) <= 2 && abs(right.maxY - area.maxY) <= 2
        }) else { return nil }
        return .init(displayID: displayID, spaceID: current.id, spaceUUID: uuid, displayFrame: display.frame,
                     leftFrame: pair[0].bounds, rightFrame: pair[1].bounds, left: pair[0], right: pair[1])
    }
}
