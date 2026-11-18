import AppKit
import ApplicationServices
import NearpaneCore
import OSLog

extension DesktopWindowTarget {
    /// Bringing a Stage Manager window forward can change its presented bounds before
    /// AX acknowledges focus. Keep the original AX binding and desktop membership for
    /// that selection; pixel reuse continues to require the stricter picture match.
    func remainsSelection(in snapshot: DesktopSnapshot?, now: Date = .now,
                          uptime: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let space = overviewSpace else { return present(in: snapshot, now: now, uptime: uptime) }
        guard let snapshot, snapshot.sessionID == session, snapshot.topologyFingerprint == topology,
              case .known(let originalSpaces) = membership else { return false }
        let matches = snapshot.currentDesktopWindows(on: display, now: now, uptime: uptime)
            .filter { $0.metadata?.number == key.number }
        guard matches.count == 1, let window = matches.first, let other = DesktopWindowTarget(window, in: snapshot),
              other.key == key, other.overviewSpace == space, other.current == current,
              case .known(let currentSpaces) = other.membership else { return false }
        return Set(originalSpaces) == Set(currentSpaces)
    }
}

/// A new click can arrive after AppKit gives a window the keyboard and before the
/// previous acknowledgement reaches the sidebar. Serialize intents and keep the last
/// explicit choice. A refusal discards pending work.
@MainActor final class WindowChoiceQueue {
    private struct Choice {
        let key: DesktopWindowKey
        let perform: @MainActor () async throws -> Void
        let failed: @MainActor (Error) -> Void
    }
    private var active: DesktopWindowKey?
    private var next: Choice?

    func isLatest(_ key: DesktopWindowKey) -> Bool { (next?.key ?? active) == key }

    func choose(_ key: DesktopWindowKey, perform: @escaping @MainActor () async throws -> Void,
                failed: @escaping @MainActor (Error) -> Void) {
        let choice = Choice(key: key, perform: perform, failed: failed)
        if let active {
            next = active == key ? nil : choice
            return
        }
        active = key
        Task {
            var current: Choice? = choice
            while let job = current {
                do { try await job.perform() }
                catch { next = nil; job.failed(error) }
                current = next; next = nil; active = current?.key
            }
        }
    }
}

@MainActor enum DesktopWindowSelection {
    private static let log = Logger(subsystem: "com.holdsnow.nearpane.alpha", category: "WindowSelection")

    /// macOS can activate an application without Accessibility. Use that path only when
    /// even the off-Space WindowServer inventory contains exactly one visible layer-zero
    /// window for this owner. The returned window number, not just the PID, must be in front.
    static func soleWindow(_ target: DesktopWindowTarget, requireVisible: Bool = true) -> Bool {
        guard let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return soleWindow(target.key, in: rows, requireVisible: requireVisible)
    }

    static func soleWindow(_ key: DesktopWindowKey, in allWindows: [[String: Any]], requireVisible: Bool = true) -> Bool {
        let sameOwner = allWindows.filter { $0[kCGWindowOwnerPID as String] as? Int32 == key.pid &&
            $0[kCGWindowLayer as String] as? Int == 0 }
        return sameOwner.count == 1 && sameOwner[0][kCGWindowNumber as String] as? UInt32 == key.number &&
            (!requireVisible || sameOwner[0][kCGWindowIsOnscreen as String] as? Bool == true)
    }

    static func bind(_ key: DesktopWindowKey) async throws -> OrdinaryWindowAX {
        guard let owner = NSRunningApplication(processIdentifier: key.pid), let bundle = owner.bundleIdentifier else {
            throw OrdinaryWindowFailure("所选窗口的应用已退出。")
        }
        let directory = try OrdinaryWindowDirectory(.init(pid: key.pid, launch: key.birth, bundle: bundle, name: ""))
        let choices = try await directory.choices(initial: true).filter { $0.number == key.number }
        guard choices.count == 1, let choice = choices.first, let handle = directory.handles[choice.id] else {
            throw OrdinaryWindowFailure("无法唯一确认这扇窗口的辅助功能身份。")
        }
        return handle
    }

    enum SelectionPath { case accessibility, soleWindowApplication }

    @discardableResult
    static func select(_ target: DesktopWindowTarget, deadline: Double,
                       verifySpace: (() async -> Bool)? = nil, stillCurrent: @escaping @MainActor @Sendable () -> Bool,
                       bound: OrdinaryWindowAX? = nil, permit: NativeSelectionPermit? = nil) async throws -> SelectionPath {
        func current() -> Bool {
            stillCurrent() && WindowContentPreview.sessionAvailable() && ProcessInfo.processInfo.systemUptime <= deadline
        }
        guard current(), let app = target.liveOwner() else {
            throw OrdinaryWindowFailure("这扇窗口已变化，请重新选择。")
        }
        if target.overviewSpace != nil {
            guard let verifySpace, await verifySpace(), current() else { throw OrdinaryWindowFailure("窗口已离开这个桌面。") }
        }
        let retained: OrdinaryWindowAX?
        if let bound {
            retained = bound
        } else {
            do { retained = try await bind(target.key) }
            catch AdmissionReadFailure.permission { retained = nil }
        }
        if let handle = retained {
            guard current(), handle.id.pid == target.key.pid, handle.id.launch == target.key.birth,
                  handle.id.number == target.key.number else { throw OrdinaryWindowFailure("这扇窗口的系统身份已变化。") }
            try await handle.focusCurrent(frame: target.frame, display: target.display, deadline: deadline,
                                          space: target.overviewSpace, permit: permit ?? NativeSelectionPermit(current: stillCurrent))
            return .accessibility
        }
        let scoped = target.overviewSpace != nil
        guard soleWindow(target, requireVisible: !scoped) else {
            log.notice("selection refused: owner has no unique ordinary surface")
            throw OrdinaryWindowFailure("窗口助手未取得辅助功能权限，无法唯一选择这扇窗口。")
        }
        guard scoped ? target.sharedSurface(visible: false, matchFrame: false, for: .windowSelection)
                     : target.isVisibleSurface(for: .windowSelection) else {
            log.notice("selection refused: surface identity changed")
            throw OrdinaryWindowFailure("系统没有确认原窗口仍然可选。")
        }
        guard current(), app.activate(options: []) else {
            log.notice("selection refused: application activation unavailable")
            throw OrdinaryWindowFailure("macOS 未允许这个应用置前。")
        }
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + 0.8)
        repeat {
            if target.liveOwner() != nil, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.key.pid,
               soleWindow(target), (scoped ? target.sharedSurface(visible: true, matchFrame: false, for: .windowSelection) : target.isVisibleSurface(for: .windowSelection)),
               let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
               let front = rows.first(where: { $0[kCGWindowLayer as String] as? Int == 0 && ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0 }),
               front[kCGWindowNumber as String] as? UInt32 == target.key.number,
               front[kCGWindowOwnerPID as String] as? Int32 == target.key.pid {
                if !scoped && current() { return .soleWindowApplication }
                if let verifySpace, await verifySpace(), current() { return .soleWindowApplication }
                break
            }
            try await Task.sleep(for: .milliseconds(35))
        } while ProcessInfo.processInfo.systemUptime < end
        log.notice("selection outcome unconfirmed: front-window readback")
        throw OrdinaryWindowFailure("系统未确认这扇窗口已置前。")
    }
}
