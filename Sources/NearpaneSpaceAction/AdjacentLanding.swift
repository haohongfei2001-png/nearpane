import AppKit
import CReadOnlySpaces
import NearpaneCore

/// Notifications are diagnostic signals. The private read-only inventory independently proves landing.
final class SpaceNotificationTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [TimeInterval] = []
    private var token: NSObjectProtocol?
    init() {
        token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock {
                if self.times.count < 16 { self.times.append(ProcessInfo.processInfo.systemUptime) }
            }
        }
    }
    var values: [TimeInterval] { lock.withLock { times } }
    deinit { if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) } }
}

@MainActor enum EmptyLandingGuard {
    /// The caller has just observed the exact ordinary target on the pointer display.
    /// Never activate on a missing inventory or when a selected window is the intended focus owner.
    static func protect(space: String) throws -> String {
        guard let id = UInt64(space), let members = NPReadCatalogSpaceWindowNumbers(id) as? [NSNumber],
              let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { throw ActionFailure("空桌面的窗口归属尚未确认。") }
        let memberIDs = Set(members.map(\.uint32Value))
        let ordinary = windows.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        if ordinary.contains(where: { ($0[kCGWindowNumber as String] as? UInt32).map(memberIDs.contains) == true }) {
            return "window-present"
        }
        let app = NSApplication.shared
        guard app.windows.isEmpty, app.setActivationPolicy(.accessory) else {
            throw ActionFailure("无法确认无窗口的桌面守护进程。")
        }
        if NSRunningApplication.current.isActive { return "windowless-owner-already-active" }
        guard NSRunningApplication.current.activate(options: []) else {
            throw ActionFailure("系统没有接受空桌面的前台保护。")
        }
        return "windowless-activation-requested"
    }
}
