import Foundation

/// Evidence about the currently visible work windows on one physical display.
/// The AX element in a native result belongs to this reader sample, not a cross-process action lease.
public enum DesktopFullscreenObservation: Equatable, Sendable {
    case ordinary(workspace: WorkspaceID?)
    case native(window: ManagedWindowID)
    case unknown
}

extension DesktopSnapshot {
    public func fullscreenObservation(for displayID: String, now: Date, uptime: Double) -> DesktopFullscreenObservation {
        guard isStructurallyValid, nativeIsFresh(now: now, uptime: uptime), let native,
              native.accessibility == .available, !native.windowLimitReached,
              let display = displays.first(where: { $0.id == displayID }) else { return .unknown }

        let visible = windows.filter { $0.metadata?.globalFrame.geometry.intersection(display.frame.geometry) != nil }
        let fullscreen = visible.filter { $0.metadata?.fullScreen == true }
        if let candidate = fullscreen.first {
            // A background, split-view, cross-display or changing presentation cannot name a single
            // current fullscreen owner. Screen dimensions alone never establish fullscreen.
            guard let usable = display.usable else { return .unknown }
            let workArea = SurfaceRect(x: display.frame.x + usable.x, y: display.frame.y + usable.y,
                                       width: usable.width, height: usable.height).geometry
            guard fullscreen.count == 1, candidate.displayID == displayID,
                  let m = candidate.metadata, let window = fullscreenSampleIdentity(candidate),
                  display.frame.geometry.intersection(m.globalFrame.geometry) == m.globalFrame.geometry,
                  let coverage = m.globalFrame.geometry.intersection(workArea),
                  coverage.componentError(from: workArea) <= 2,
                  visible.allSatisfy({ ($0.metadata?.frontToBack ?? -1) >= m.frontToBack })
            else { return .unknown }
            return .native(window: window)
        }

        let workspace = native.rows.first(where: { $0.displayID == displayID })
            .flatMap { workspaceID(display: displayID, record: $0.recordID) }
        guard !visible.isEmpty || workspace != nil, visible.allSatisfy({
            $0.metadata?.fullScreen == false && fullscreenSampleIdentity($0) != nil
        }) else { return .unknown }
        return .ordinary(workspace: workspace)
    }

    private func fullscreenSampleIdentity(_ window: WindowObservation) -> ManagedWindowID? {
        guard window.confidence == .corroboratedMetadata || window.confidence == .geometryOnly,
              let m = window.metadata, m.presentation == .confirmed, m.minimized == false,
              m.axStandardWindowNumber == m.number, let launch = m.launchMicroseconds, launch > 0,
              let element = m.element else { return nil }
        return .init(pid: m.pid, launch: launch, number: m.number, element: element)
    }
}
