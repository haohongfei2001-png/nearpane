#if DEBUG
import AppKit
import NearpaneCore

/// A sealed fixture drives the actual SwiftUI buttons exposed by the local R4
/// window. It has no entry point for performing a native focus operation.
@MainActor final class AppleStageFocusCycleFixture {
    typealias Group = AppleNativeStages.Group
    let windows: [DesktopWindowKey]
    private let path: [DesktopWindowKey]
    private var step = 0
    private(set) var pressed = false
    private(set) var accepted = false
    private var scheduled = false
    private var reads = [[String: Any]]()
    private(set) var timeline = [[String: Any]]()
    private(set) var failed = false
    var complete: Bool { step == 3 && !failed }
    var source: DesktopWindowKey? { step < 3 ? path[step] : nil }
    var target: DesktopWindowKey? { step < 3 ? path[step + 1] : nil }

    init?(_ windows: [DesktopWindowKey]) {
        guard windows.count == 3, Set(windows.map(\.pid)).count == 3,
              Set(windows.map(\.number)).count == 3 else { return nil }
        self.windows = windows
        self.path = windows + [windows[0]]
    }
    func permits(_ front: Set<DesktopWindowKey>, _ destination: Set<DesktopWindowKey>) -> Bool {
        guard !failed, let target else { return false }
        return destination == [target] && (front == [path[step]] || (accepted && front == [target]))
    }
    func take(_ members: [DesktopWindowKey]) -> Bool {
        guard !failed, pressed, !accepted, let target, members == [target] else { return false }
        accepted = true
        return true
    }
    private func ordinaryThree(_ groups: [Group]) -> Bool {
        groups.count == 3 && groups.allSatisfy { $0.members.count == 1 } &&
            Set(groups.flatMap(\.members)) == Set(windows) && groups.filter(\.current).count == 1
    }
    func observe(_ groups: [Group], live: @escaping @MainActor () -> Bool) {
        guard !failed, !scheduled, !pressed, let target, live(), ordinaryThree(groups),
              groups.first(where: \.current)?.members == [path[step]],
              let card = groups.first(where: { $0.members == [target] }) else { return }
        scheduled = true
        Task { @MainActor in
            defer { scheduled = false }
            // Yield until SwiftUI exposes its button for the settled catalog.
            await Task.yield()
            guard live(), !failed, !pressed, self.target == target,
                  let button = Self.button(for: card.id, target: target) else { return }
            pressed = true
            if !button.accessibilityPerformPress() { abort() }
        }
    }
    private static func button(for id: String, target: DesktopWindowKey) -> (any NSAccessibilityProtocol)? {
        let panels = NSApp.windows.compactMap { $0 as? EdgePanel }.filter { $0.isVisible }
        guard panels.count == 1, let panel = panels.first else { return nil }
        let ids: Set<String> = ["apple-stage:" + id, "current-desktop-window:\(target.pid):\(target.number)"]
        var queue: [AnyObject] = [panel], visited = Set<ObjectIdentifier>()
        var matches = [any NSAccessibilityProtocol]()
        while let object = queue.popLast() {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            guard visited.count <= 512 else { return nil }
            guard let node = object as? any NSAccessibilityProtocol else { continue }
            if node.accessibilityRole() == .button, node.isAccessibilityEnabled(),
               ids.contains(node.accessibilityIdentifier() ?? ""), node.accessibilityWindow() as? NSWindow === panel,
               panel.frame.intersects(node.accessibilityFrame()) { matches.append(node) }
            let children = node.accessibilityChildren() ?? []
            guard children.count <= 128, queue.count + children.count <= 512 else { return nil }
            queue.append(contentsOf: children.map { $0 as AnyObject })
        }
        return matches.count == 1 ? matches[0] : nil
    }
    /// The production focus transaction provides each independent system sample.
    /// Missing or contradictory samples break the pair.
    func note(_ groups: [Group], strip: [[UInt32]]?, time: UInt64, exact: Bool) {
        guard !failed, accepted, let target else { return }
        guard exact, ordinaryThree(groups), groups.first(where: \.current)?.members == [target],
              let strip, strip.count == 2, strip.allSatisfy({ $0.count == 1 }),
              Set(strip.flatMap { $0 }) == Set(windows.filter { $0 != target }.map(\.number)) else { reads = []; return }
        guard time > (reads.last?["timeNS"] as? UInt64 ?? 0) else { return }
        reads.append(["timeNS":time, "window":target.number, "pid":target.pid, "birth":target.birth,
                      "otherStages":strip.flatMap { $0 }.sorted()])
        if reads.count > 2 { reads.removeFirst() }
    }
    func finish(_ key: DesktopWindowKey) {
        guard accepted, !failed, key == target, reads.count == 2 else { abort(); return }
        timeline.append(["from":path[step].number, "to":key.number, "entry":"R4AccessibilityButton",
                         "confirmedReads":reads])
        step += 1; pressed = false; accepted = false; reads = []
        if complete { NSApp.terminate(nil) }
    }
    func abort() { failed = true; NSApp.terminate(nil) }
}
#endif
