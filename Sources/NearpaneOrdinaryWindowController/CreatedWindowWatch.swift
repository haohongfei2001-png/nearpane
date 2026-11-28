import ApplicationServices
import CReadOnlySpaces
import Foundation
import NearpaneCore

/// An optional Stage subscription accepts only the original focused object or exactly one
/// unseen object. A departure to a known sibling or an unreadable receiver permanently ends it.
struct StageCreationFocus<Element> {
    let original: Element
    let same: (Element, Element) -> Bool
    private(set) var interrupted = false
    private var alternate: Element?
    private var sawFocusChange = false

    init(original: Element, same: @escaping (Element, Element) -> Bool) {
        self.original = original
        self.same = same
    }

    mutating func observe(_ receiver: Element?, changed: Bool = false, isNew: (Element) -> Bool) {
        guard !interrupted else { return }
        guard let receiver else { interrupted = true; return }
        if changed {
            guard !sawFocusChange, !same(receiver, original) else { interrupted = true; return }
            sawFocusChange = true
        }
        if same(receiver, original) {
            if alternate != nil { interrupted = true }
            return
        }
        guard isNew(receiver), alternate.map({ same(receiver, $0) }) != false else {
            interrupted = true; return
        }
        alternate = receiver
    }

    func accepts(_ created: Element) -> Bool {
        !interrupted && !same(created, original) && alternate.map({ same($0, created) }) != false
    }
}

/// One registration on one selected process. A difference between two window lists
/// is never evidence that the application actually created a window after consent.
package final class CreatedWindowWatch {
    package let grant: UUID
    package let anchor: ManagedWindowID
    let stageHome: OrdinaryDesktopIdentity?
    private var focusPath: StageCreationFocus<AXUIElement>?
    private var observer: AXObserver?
    private var baseline = Set<UInt32>()
    private var seen = Set<UInt32>()
    private var pending: [(AXUIElement, UInt32, TimeInterval)] = []
    private var overflow = false

    package init(anchor: ManagedWindowID, grant: UUID, focusedOriginal: AXUIElement? = nil, stageHome: OrdinaryDesktopIdentity? = nil) throws {
        self.anchor = anchor
        self.grant = grant
        self.focusPath = focusedOriginal.map { StageCreationFocus(original: $0, same: { CFEqual($0, $1) }) }
        self.stageHome = stageHome
        let application = AXUIElementCreateApplication(anchor.pid)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, context in
            guard let context else { return }
            let watch = Unmanaged<CreatedWindowWatch>.fromOpaque(context).takeUnretainedValue()
            if notification as String == kAXFocusedWindowChangedNotification { watch.checkFocus(changed: element) }
            if notification as String == kAXWindowCreatedNotification { watch.receive(element) }
        }
        try require(AXObserverCreate(anchor.pid, callback, &created) == .success, "应用不支持新窗口观察。")
        guard let created else { throw Refusal("系统未能建立新窗口观察。") }
        let registration = AXObserverAddNotification(created, application, kAXWindowCreatedNotification as CFString,
                                                     Unmanaged.passUnretained(self).toOpaque())
        try require(registration == .success, "此应用无法提供新窗口创建事件，可继续逐窗授权。")
        if focusedOriginal != nil {
            let change = AXObserverAddNotification(created, application, kAXFocusedWindowChangedNotification as CFString,
                                                   Unmanaged.passUnretained(self).toOpaque())
            try require(change == .success, "此应用无法确认新窗口的焦点来源。")
        }
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
        if let focusedOriginal {
            let focus = try FrontFocus()
            try require(focus.pid == anchor.pid && focus.element.map { CFEqual($0, focusedOriginal) } == true,
                        "新窗口观察开始时原窗已失去焦点。")
        }
    }

    deinit {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode) }
    }

    private func receive(_ element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == anchor.pid,
              let n = number(element), n != 0, !baseline.contains(n), !seen.contains(n) else { return }
        checkFocus()
        guard focusPath?.interrupted != true else { return }
        guard !overflow, seen.count < 512, pending.count < 32 else { overflow = true; return }
        seen.insert(n)
        pending.append((element, n, ProcessInfo.processInfo.systemUptime))
    }

    /// Only the already-focused original or one genuinely new window of its generation can
    /// receive focus. An existing sibling or unknown receiver invalidates this subscription.
    private func checkFocus(changed notified: AXUIElement? = nil) {
        guard focusPath != nil else { return }
        let focus = try? FrontFocus(), existing = baseline
        let receiver = focus?.pid == anchor.pid ? focus?.element : nil
        // A window-valued notification retained a specific receiver. An application-valued
        // notification only identifies one transition and must agree with the current focus path.
        let matches = notified.flatMap(number) == nil ||
            (notified.flatMap { event in receiver.map { CFEqual(event, $0) } } == true)
        focusPath?.observe(matches ? receiver : nil, changed: notified != nil) { element in
            number(element).map { !existing.contains($0) } == true
        }
    }

    package func take() throws -> (AXUIElement, UInt32)? {
        try require(!overflow, "新窗口事件过多，本次授权已过期。")
        let now = ProcessInfo.processInfo.systemUptime
        pending.removeAll { now - $0.2 > 5 }
        guard !pending.isEmpty else { return nil }
        let (element, n, _) = pending.removeFirst()
        checkFocus()
        try require(focusPath?.accepts(element) != false,
                    "新窗口与活动组原窗的焦点连续性不足。")
        let matches = try windows(anchor.pid).filter { number($0) == n }
        guard matches.count == 1, CFEqual(matches[0], element) else { return nil }
        return (element, n)
    }
}
