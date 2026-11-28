#if DEBUG
import Foundation
import NearpaneCore
import NearpaneUI

/// Geometry-only observations for the isolated Quick Notes native screenshot run.
/// These exercise the production Spaces cards and their outline fallback; they are
/// explicitly marked fixtures and provide no real capture or desktop-dispatch evidence.
@MainActor enum QuickNotesSpacesFixture {
    @discardableResult
    static func install(host: HostSession, screen: ScreenGeometry) -> Bool {
        guard NativeVerificationAccessibility.isEnabled,
              screen.frame.width > 0, screen.frame.height > 0 else { return false }

        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let frame = screen.frame
        let windows = (0..<2).map { index in
            let global = SurfaceRect(
                x: frame.x + (frame.width * (index == 0 ? 0.08 : 0.18)).rounded(),
                y: frame.y + (frame.height * (index == 0 ? 0.12 : 0.22)).rounded(),
                width: (frame.width * 0.70).rounded(),
                height: (frame.height * (index == 0 ? 0.42 : 0.34)).rounded())
            let local = SurfaceRect(x: global.x - frame.x, y: global.y - frame.y,
                                    width: global.width, height: global.height)
            return WindowObservation(
                id: "quick-notes-outline-fixture-\(index + 1)", displayID: screen.id,
                bounds: local, membership: .unknown, confidence: .unknown,
                metadata: .init(number: UInt32.max - UInt32(index), pid: Int32.max,
                    launchMicroseconds: 1, element: nil, globalFrame: global,
                    frontToBack: index, minimized: false, fullScreen: false,
                    isOnscreen: true, onActiveDesktop: true, hasCatalogGeometry: true))
        }
        let snapshot = DesktopSnapshot.observed(
            .init(session: UUID(), revision: 1, parentPID: Int32.max,
                  fixtureWindows: windows.compactMap { $0.metadata?.number },
                  anchors: [], experimentalSpaces: false),
            from: now, to: now, build: "quick-notes-outline-fixture",
            topology: "quick-notes-fixture-\(screen.id)", consistent: true,
            separateSpaces: true,
            displays: [.init(id: screen.id, frame: frame,
                rotationDegrees: Int(screen.rotationDegrees), backingScale: screen.backingScale,
                usable: .init(width: frame.width, height: frame.height))],
            scopes: [], windows: windows,
            evidence: .init(population: .markedFixture, accessibility: .denied,
                spaces: .unavailable, rows: [], windowLimitReached: false,
                beganUptime: uptime, endedUptime: uptime))
        host.bus.resetDesktopSession()
        return host.bus.acceptDesktop(snapshot, now: now)
            && snapshot.currentDesktopWindows(on: screen.id, now: now, uptime: uptime).count == 2
    }
}
#endif
