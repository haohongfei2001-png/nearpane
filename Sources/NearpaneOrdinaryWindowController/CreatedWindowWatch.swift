import ApplicationServices
import CReadOnlySpaces
import Foundation
import NearpaneCore

/// One registration on one selected process. A difference between two window lists
/// is never evidence that the application actually created a window after consent.
final class CreatedWindowWatch {
    let grant: UUID
    let anchor: ManagedWindowID
    private var observer: AXObserver?
    private var baseline = Set<UInt32>()
    private var seen = Set<UInt32>()
    private var pending: [(AXUIElement, UInt32, TimeInterval)] = []
    private var overflow = false

    init(anchor: ManagedWindowID, grant: UUID) throws {
        self.anchor = anchor
        self.grant = grant
        let application = AXUIElementCreateApplication(anchor.pid)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, context in
            guard let context, notification as String == kAXWindowCreatedNotification else { return }
            Unmanaged<CreatedWindowWatch>.fromOpaque(context).takeUnretainedValue().receive(element)
        }
        try require(AXObserverCreate(anchor.pid, callback, &created) == .success, "应用不支持新窗口观察。")
        guard let created else { throw Refusal("系统未能建立新窗口观察。") }
        let registration = AXObserverAddNotification(created, application, kAXWindowCreatedNotification as CFString,
                                                     Unmanaged.passUnretained(self).toOpaque())
        try require(registration == .success, "此应用无法提供新窗口创建事件，可继续逐窗授权。")
        observer = created
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
        let original = try windows(anchor.pid)
        let ids = original.compactMap(number)
        try require(ids.count == original.count && Set(ids).count == ids.count && ids.contains(anchor.number),
                    "现有窗口不能全部确认，未开启新窗口范围。")
        var anonymous = [UInt32](repeating: 0, count: 4096)
        let count = Int(NPReadExistingWindowNumbers(&anonymous, Int32(anonymous.count)))
        try require(count > 0 && anonymous.prefix(count).contains(anchor.number),
                    "无法建立完整的在先窗口编号清单。")
        baseline = Set(ids).union(anonymous.prefix(count))
        pending.removeAll()
    }

    deinit {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode) }
    }

    private func receive(_ element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == anchor.pid,
              let n = number(element), n != 0, !baseline.contains(n), !seen.contains(n) else { return }
        guard !overflow, seen.count < 512, pending.count < 32 else { overflow = true; return }
        seen.insert(n)
        pending.append((element, n, ProcessInfo.processInfo.systemUptime))
    }

    func take() throws -> (AXUIElement, UInt32)? {
        try require(!overflow, "新窗口事件过多，本次授权已过期。")
        let now = ProcessInfo.processInfo.systemUptime
        pending.removeAll { now - $0.2 > 5 }
        guard !pending.isEmpty else { return nil }
        let (element, n, _) = pending.removeFirst()
        let matches = try windows(anchor.pid).filter { number($0) == n }
        guard matches.count == 1, CFEqual(matches[0], element) else { return nil }
        return (element, n)
    }
}
