import Foundation
import NearpaneCore

/// A newer card click may wait for an exact focus transition already dispatched by this sidebar.
/// Nothing from a stale display, an external transition or a partial scan can authorize a write.
@MainActor struct AppleStageSelectionHandoff {
    typealias Group = AppleNativeStages.Group
    let id = UUID()
    let roster: [Group]
    let target: Group
    var originalMembershipConfirmed = false
    let focusMatches: @MainActor () -> Bool
    let ownsForeground: @MainActor () -> Bool
    let release: @MainActor () -> Void
    let deadline: ContinuousClock.Instant
    var memberCycle: AppleStageMemberCycle?
    /// WindowManager may remove the strip item before the desktop catalog's
    /// AXMinimized bit follows. Keep only the already dispatched witness for readback.
    var restoringNativeMinimizedWindow: DesktopWindowKey?

    func includes(_ group: Group, now: ContinuousClock.Instant = .now) -> Bool {
        now < deadline && roster.contains { $0.id == group.id && Set($0.members) == Set(group.members) }
    }

    func permits(_ groups: [Group]) -> Bool {
        guard groups.count == roster.count, groups.allSatisfy({ includes($0) }),
              groups.filter(\.current).count == 1, let active = groups.first(where: \.current) else { return false }
        return active.id == target.id || roster.contains { $0.id == active.id && $0.current }
    }

    func focused(_ groups: [Group]) -> Bool {
        permits(groups) && groups.contains { $0.current && $0.id == target.id && $0.evidence == .currentWindowList } && focusMatches()
    }

    enum Outcome { case unchanged, focusedGroup, preservedRoster }

    struct OutcomeConfirmations {
        private var focus: Confirmations
        private var membership: Confirmations
        init(after timestamp: UInt64) {
            focus = Confirmations(after: timestamp)
            membership = Confirmations(after: timestamp)
        }
        mutating func record(_ timestamp: UInt64, focused: Bool, preserved: Bool) -> Outcome? {
            let exactTarget = focus.record(timestamp, exact: focused)
            let exactDirectory = membership.record(timestamp, exact: focused && preserved)
            if exactDirectory { return .preservedRoster }
            return exactTarget ? .focusedGroup : nil
        }
    }

    struct Confirmations {
        private var previous: UInt64
        private var count = 0
        init(after timestamp: UInt64) { previous = timestamp }
        mutating func record(_ timestamp: UInt64, exact: Bool) -> Bool {
            guard exact else {
                previous = max(previous, timestamp)
                count = 0
                return false
            }
            guard timestamp > previous else { return false }
            previous = timestamp
            count += 1
            return count >= 2
        }
    }
}
