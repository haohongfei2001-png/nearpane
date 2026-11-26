import AppKit
import Foundation

/// Local notifications request a transition. The flock owned by LyricAppModel remains authoritative.
@MainActor
public enum LyricHandoff {
    public static let request = Notification.Name("com.holdsnow.lyrictile.handoff.request.v1")
    public static let reply = Notification.Name("com.holdsnow.lyrictile.handoff.reply.v1")
    public static let released = Notification.Name("com.holdsnow.lyrictile.handoff.released.v1")
    public enum Role: String, Sendable { case standalone, host }

    @discardableResult public static func requestRelease(of role: Role) -> String {
        let requestID = UUID().uuidString
        DistributedNotificationCenter.default().postNotificationName(request, object: nil,
            userInfo: ["requestID": requestID, "target": role.rawValue,
                       "requesterPID": String(ProcessInfo.processInfo.processIdentifier)], deliverImmediately: true)
        return requestID
    }
    public static func acknowledge(_ requestID: String, succeeded: Bool) {
        DistributedNotificationCenter.default().postNotificationName(reply, object: nil,
            userInfo: ["requestID": requestID, "released": succeeded ? "true" : "false"], deliverImmediately: true)
    }
    public static func announceRelease(from role: Role) {
        DistributedNotificationCenter.default().postNotificationName(released, object: nil,
            userInfo: ["role": role.rawValue], deliverImmediately: true)
    }
    public static func requestID(from notification: Notification, targeting role: Role) -> String? {
        guard notification.userInfo?["target"] as? String == role.rawValue,
              let value = notification.userInfo?["requestID"] as? String, UUID(uuidString: value) != nil else { return nil }
        return value
    }
    /// Uses only window IDs, without capture permission or image pixels.
    public static func waitUntilWindowsWithdrawn(_ ids: [Int], timeout: Duration = .seconds(2)) async -> Bool {
        guard !ids.isEmpty else { return true }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            await Task.yield()
            if let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                let visible = Set(windows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue })
                if visible.isDisjoint(with: ids) { return true }
            }
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return false }
        } while ContinuousClock.now < deadline
        return false
    }
}
