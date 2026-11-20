import CoreGraphics
import Foundation

/// Many cards can draw in a single frame. A denial prevents every one from
/// reading pixels, so they can share it briefly. A grant is always checked live.
@MainActor final class WindowPermissionProbe {
    static let screen = WindowPermissionProbe(read: CGPreflightScreenCaptureAccess)

    private let read: () -> Bool
    private let uptime: () -> TimeInterval
    private var deniedUntil: TimeInterval = -.infinity

    init(read: @escaping () -> Bool, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.read = read
        self.uptime = uptime
    }

    func allowed() -> Bool {
        let now = uptime()
        guard now >= deniedUntil else { return false }
        if read() { return true }
        deniedUntil = now + 2
        return false
    }

    func invalidate() { deniedUntil = -.infinity }
}
