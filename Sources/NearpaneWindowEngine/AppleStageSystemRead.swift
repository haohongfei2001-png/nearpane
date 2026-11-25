import AppKit
import ApplicationServices
import CNearpaneWindowEngine
import Foundation

/// Bounded, title-free WindowManager reader, adapted from upstream platform/apple/strip_ax.rs.
/// Exact-member AX readings corroborate CG's presentation. An unavailable strip is distinct from an empty strip.
package struct AppleStageSystemRead: @unchecked Sendable {
    struct Item { let frame: CGRect; let members: [UInt32] }
    struct Strip { let frame: CGRect?; let items: [Item] }
    let manager: pid_t
    let sampleTime: UInt64
    package var timestamp: UInt64 { sampleTime }
    let listed: [NPAppleListedWindow]
    let strips: [Strip]?
    let singleDisplay: Bool

    func strip(on screen: CGRect) -> [Item]? {
        guard let strips else { return nil }
        if singleDisplay, strips.count == 1, strips[0].frame == nil { return strips[0].items }
        let matching = strips.filter {
            guard let frame = $0.frame else { return false }
            return abs(frame.minX-screen.minX) <= 2 && abs(frame.minY-screen.minY) <= 2 &&
                abs(frame.width-screen.width) <= 2 && abs(frame.height-screen.height) <= 2
        }
        return matching.count == 1 ? matching[0].items : nil
    }

    package static func capture(singleDisplay: Bool) -> Self? {
        let started = DispatchTime.now().uptimeNanoseconds
        let owners = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager")
        guard owners.count == 1, let manager = owners.first, !manager.isTerminated,
              manager.bundleURL?.standardizedFileURL.path == "/System/Library/CoreServices/WindowManager.app",
              let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String:Any]],
              rows.count <= NP_APPLE_MAX_LISTED else { return nil }
        var listed = [NPAppleListedWindow]()
        listed.reserveCapacity(rows.count)
        for row in rows {
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let layer = row[kCGWindowLayer as String] as? Int32,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            let opaque = layer == 0 || (row[kCGWindowAlpha as String] as? Double ?? 0) > 0
            let visible = row[kCGWindowIsOnscreen as String] as? Bool == true && opaque
            listed.append(.init(window: id, pid: pid, layer: layer, onscreen: visible ? 1 : 0, frame: .init(frame)))
        }
        let strips = AXIsProcessTrusted() ? Reader().read(manager.processIdentifier) : nil
        guard !manager.isTerminated else { return nil }
        return Self(manager: manager.processIdentifier, sampleTime: started,
                    listed: listed, strips: strips, singleDisplay: singleDisplay)
    }

    private struct Reader {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.32
        func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            AXUIElementSetMessagingTimeout(node, 0.05)
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success ? value : nil
        }
        func children(_ node: AXUIElement, limit: Int) -> [AXUIElement]? {
            guard let list = attribute(node, kAXChildrenAttribute) as? [AXUIElement], list.count <= limit else { return nil }
            return list
        }
        func frame(_ node: AXUIElement) -> CGRect? {
            guard let raw = attribute(node, "AXFrame"), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            var value = CGRect.zero
            guard AXValueGetValue(raw as! AXValue, .cgRect, &value), !value.isNull, !value.isInfinite,
                  value.width > 0, value.height > 0 else { return nil }
            return value
        }
        func read(_ pid: pid_t) -> [Strip]? {
            guard let spaces = children(AXUIElementCreateApplication(pid), limit: 64) else { return nil }
            var strips = [Strip]()
            for space in spaces {
                guard attribute(space, kAXIdentifierAttribute) as? String == "sm.space" else { continue }
                guard let nodes = children(space, limit: 64) else { return nil }
                let lists = nodes.filter { attribute($0, kAXIdentifierAttribute) as? String == "sm.strip" }
                guard lists.count == 1, let list = lists.first, let buttons = children(list, limit: 128) else { return nil }
                var items = [Item]()
                for button in buttons {
                    guard let bounds = frame(button), let ids = attribute(button, "AXWindowsIDs") as? [NSNumber],
                          !ids.isEmpty, ids.count <= 256 else { return nil }
                    let members = ids.compactMap { UInt32($0.stringValue) }
                    guard members.count == ids.count, !members.contains(0) else { return nil }
                    items.append(Item(frame: bounds, members: members))
                }
                strips.append(Strip(frame: frame(space), items: items))
            }
            return ProcessInfo.processInfo.systemUptime < deadline ? strips : nil
        }
    }
}
