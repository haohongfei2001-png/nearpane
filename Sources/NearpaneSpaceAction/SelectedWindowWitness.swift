import AppKit
import CReadOnlySpaces
import NearpaneCore

/// A thumbnail click can traverse multiple desktops before transferring keyboard focus.
/// Pin the selected AX object, even when its owner presents other windows on the route.
struct SelectedWindowWitness {
    private let element: AXUIElement
    private let readCurrent: () throws -> AXUIElement

    init(_ window: NativeSpaceWindow, display: ActionInventory.Display, space: String) throws {
        try self.init { try Self.read(window, display: display, space: space) }
    }

    init(readCurrent: @escaping () throws -> AXUIElement) throws {
        self.element = try readCurrent()
        self.readCurrent = readCurrent
    }

    func verify() throws {
        let live = try readCurrent()
        guard CFEqual(live, element) else { throw ActionFailure("所选窗口已重建。") }
    }

    private static func read(_ window: NativeSpaceWindow, display: ActionInventory.Display, space: String) throws -> AXUIElement {
        guard AXIsProcessTrusted(), WindowWitness.owner(window), let frame = WindowWitness.cgFrame(window),
              !frame.isEmpty, display.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)),
              WindowWitness.membership(window.number)?.contains(space) == true else {
            throw ActionFailure("所选窗口的进程、显示器或空间归属已经变化。")
        }
        let app = AXUIElementCreateApplication(window.pid)
        var raw: CFArray?
        guard AXUIElementSetMessagingTimeout(app, 0.18) == .success,
              AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 65, &raw) == .success,
              let list = raw as? [AXUIElement], list.count <= 64 else { throw ActionFailure("无法核对所选窗口。") }
        let matches = list.filter { NPReadAXWindowNumber($0) == window.number }
        guard matches.count == 1, let selected = matches.first else { throw ActionFailure("所选窗口已关闭或身份不唯一。") }
        return selected
    }
}
