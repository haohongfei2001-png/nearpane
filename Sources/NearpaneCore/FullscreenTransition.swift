import Foundation

public struct FullscreenOrigin: Equatable, Sendable {
    public let session: UUID, workspace: WorkspaceID, display: String, window: ManagedWindowID, revision: UInt64
    public let layout: ManagedWindowTiler
}
public enum FullscreenPhase: Equatable, Sendable { case ordinary, native, returning, recovery }
public struct FullscreenTransitionCoordinator {
    public private(set) var phase: FullscreenPhase = .ordinary
    public private(set) var origin: FullscreenOrigin?
    public private(set) var toolsOpen = false
    public init() {}
    public mutating func enter(
        _ from: FullscreenOrigin, verifiedNative: Bool, separate: Bool,
        capabilities: WorkspaceCapabilities, source: WorkspaceSnapshot, uptime: Double, isolated: Bool = false
    ) throws {
        guard source.stable, source.session == from.session, source.revision == from.revision,
            source.build == capabilities.build,
            source.mode == from.workspace.mode, uptime.isFinite, uptime <= source.validUntil,
            source.rows[from.workspace]?.display == from.display, source.rows[from.workspace]?.layout == from.layout
        else { throw WorkspaceFailure.stale }
        guard phase == .ordinary, verifiedNative, from.workspace == from.layout.workspace,
            from.layout.members.contains(where: { $0.id == from.window }), from.display == capabilities.displayID,
            from.workspace.mode == capabilities.mode
        else { throw WorkspaceFailure.identity }
        if separate && !capabilities.permits(.separateFullscreen, isolated: isolated) { throw WorkspaceFailure.unavailable }
        origin = from
        phase = .native
        toolsOpen = false
    }
    public mutating func clickStatusStrip() { if phase == .native { toolsOpen = true } }
    public mutating func hideTools() { toolsOpen = false }
    public mutating func exit(observedWindow: ManagedWindowID) throws -> FullscreenOrigin {
        guard phase == .native, let origin, origin.window == observedWindow else { throw WorkspaceFailure.identity }
        phase = .returning
        toolsOpen = false
        return origin
    }
    /// Use the current persistent boundary if display geometry/configuration changed in fullscreen.
    public mutating func confirmReturn(
        session: UUID, revision: UInt64, workspace: WorkspaceID, area: DesktopWorkArea,
        window: ManagedWindowID, actual: [ManagedWindowID: SurfaceRect]
    ) throws {
        guard phase == .returning, let origin else { throw WorkspaceFailure.stale }
        guard origin.session == session, revision > origin.revision, origin.workspace == workspace,
            area.display == origin.display, origin.window == window,
            let plan = try? origin.layout.frames(in: area.ordinary), plan == actual
        else {
            phase = .recovery
            throw WorkspaceFailure.recoveryRequired
        }
        self.origin = nil
        phase = .ordinary
    }
}

/// User-selected anchor is persistent. Placement never accepts pointer/focus/transcript events.
public struct FloatingToolSurface: Codable, Equatable, Sendable {
    public private(set) var anchor: SurfaceRect
    public init(anchor: SurfaceRect) { self.anchor = anchor }
    public mutating func userMoved(to rect: SurfaceRect) { if rect.geometry.isValid { anchor = rect } }
    public func placement(safe: SurfaceRect, confirmedControls: [SurfaceRect]) -> SurfaceRect? {
        let a = anchor
        guard a.geometry.isValid, safe.geometry.isValid, a.width <= safe.width, a.height <= safe.height else { return nil }
        let obstacles = confirmedControls.compactMap { $0.geometry.intersection(safe.geometry) }
        func clamp(_ x: Double, _ low: Double, _ high: Double) -> Double { min(high, max(low, x)) }
        let xs = [a.x, safe.x, safe.geometry.maxX - a.width] + obstacles.flatMap { [$0.x - a.width, $0.maxX] }
        let ys = [a.y, safe.y, safe.geometry.maxY - a.height] + obstacles.flatMap { [$0.y - a.height, $0.maxY] }
        var result: SurfaceRect?
        var distance = Double.infinity
        for x in xs {
            for y in ys {
                let r = SurfaceRect(
                    x: clamp(x, safe.x, safe.geometry.maxX - a.width), y: clamp(y, safe.y, safe.geometry.maxY - a.height),
                    width: a.width, height: a.height)
                let delta = hypot(r.x - a.x, r.y - a.y)
                if delta < distance && obstacles.allSatisfy({ $0.intersection(r.geometry) == nil }) {
                    result = r
                    distance = delta
                }
            }
        }
        return result
    }
}
