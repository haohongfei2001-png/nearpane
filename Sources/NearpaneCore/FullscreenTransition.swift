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
    public private(set) var displayedWindow: ManagedWindowID?
    public private(set) var returnEvidence: FullscreenReturnEvidence = .none
    public private(set) var selectionGeneration = UUID()
    private var readSession: UUID?
    private var lastRevision: UInt64?
    private var validUntil = 0.0
    private var lastOrdinary: WorkspaceID?
    private var ordinaryMembers = Set<ManagedWindowID>()
    private var ordinaryDeadline = 0.0
    private var lastNative: ManagedWindowID?
    private var enteredFrom: WorkspaceID?
    private func sameWindow(_ a: ManagedWindowID?, _ b: ManagedWindowID) -> Bool {
        a?.pid == b.pid && a?.launch == b.launch && a?.number == b.number
    }

    public init() {}

    public func permitsTool(at uptime: Double) -> Bool {
        phase == .native && displayedWindow != nil && uptime.isFinite && uptime < validUntil
    }

    private mutating func clearToolSelection() {
        if displayedWindow != nil || toolsOpen { selectionGeneration = UUID() }
        displayedWindow = nil
        validUntil = 0
        hideTools()
    }

    /// Lock, loss of permission, a change of displays or a gap in observation ends
    /// the chain of witnesses. Keep a known fullscreen display suppressed until
    /// a fresh ordinary sample. Never carry its recovery evidence across that gap.
    public mutating func invalidatePresentation() {
        clearToolSelection()
        enteredFrom = nil
        lastNative = nil
        lastOrdinary = nil
        ordinaryMembers.removeAll()
        ordinaryDeadline = 0
        returnEvidence = .none
    }

    /// True only for a newly accepted ordinary/native sample. A caller forwarding
    /// management notifications must never derive one from a superseded sample.
    @discardableResult
    public mutating func observe(_ sample: FullscreenDisplaySample?, uptime: Double) -> Bool {
        guard uptime.isFinite, uptime >= 0, let sample else { invalidatePresentation(); return false }
        if let readSession, readSession != sample.session { return false }
        if (displayedWindow != nil && uptime >= validUntil) || (lastOrdinary != nil && uptime >= ordinaryDeadline) {
            invalidatePresentation()
        }
        guard sample.revision > (lastRevision ?? 0) else { return false }
        readSession = sample.session
        lastRevision = sample.revision
        guard sample.validUntil.isFinite, uptime < sample.validUntil else { invalidatePresentation(); return false }

        switch sample.observation {
        case .unknown:
            invalidatePresentation()
            return false
        case let .native(window):
            // UI can remain in the same position on this display across fresh
            // reads. PID/birth/number continuity is never authority to restore.
            let continuingPresentation = sameWindow(displayedWindow, window)
            if phase != .native {
                enteredFrom = ordinaryDeadline > uptime && ordinaryMembers.contains(window) ? lastOrdinary : nil
                lastOrdinary = nil
                ordinaryMembers.removeAll()
                phase = .native
                returnEvidence = .none
            } else if lastNative != window {
                // Also covers a restarted AX reader whose tokens cannot be compared.
                enteredFrom = nil
            }
            if !continuingPresentation { selectionGeneration = UUID(); hideTools() }
            lastNative = window
            displayedWindow = window
            validUntil = sample.validUntil
        case let .ordinary(workspace):
            let previous = lastNative
            clearToolSelection()
            let witnessed: WorkspaceID?
            if case let .native(session, _, _) = workspace, session == sample.session {
                witnessed = workspace
            } else {
                witnessed = nil
            }
            if phase == .native {
                let sameMember = previous.map(sample.ordinaryMembers.contains) == true
                returnEvidence = sameMember && enteredFrom != nil && witnessed == enteredFrom ? .witnessedSource : .unconfirmedSource
                phase = .ordinary
            } else {
                // A return is a transition receipt, not repeated evidence on future ticks.
                returnEvidence = .none
            }
            enteredFrom = nil
            lastNative = nil
            lastOrdinary = witnessed
            ordinaryMembers = sample.ordinaryMembers
            ordinaryDeadline = sample.validUntil
        }
        return true
    }
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
    public mutating func clickStatusStrip() {
        if phase == .native && (displayedWindow != nil || origin != nil) { toolsOpen = true }
    }
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

/// A presentation witness never grants system window or Workspace write permission.
/// AX element tokens belong to a reader invocation. Continuity across samples is used
/// only to keep a tool visible; the window controller needs its own fresh action ticket.
public struct FullscreenDisplaySample: Sendable {
    public static let maximumLifetime: TimeInterval = 12
    public let beganUptime: Double?
    public let session: UUID
    public let revision: UInt64
    public let validUntil: Double
    public let observation: DesktopFullscreenObservation
    /// Members positively associated with the current ordinary Space in this sample.
    public let ordinaryMembers: Set<ManagedWindowID>
    public init(session: UUID, revision: UInt64, validUntil: Double, observation: DesktopFullscreenObservation,
                ordinaryMembers: Set<ManagedWindowID> = [], beganUptime: Double? = nil) {
        self.beganUptime = beganUptime
        self.ordinaryMembers = ordinaryMembers
        self.session = session; self.revision = revision; self.validUntil = validUntil; self.observation = observation
    }
}

public enum FullscreenReturnEvidence: Equatable, Sendable {
    case none, witnessedSource, unconfirmedSource
}
