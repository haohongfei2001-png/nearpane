import AppKit
import CReadOnlySpaces
import NearpaneCore

struct WindowWitness {
    let identity: NativeSpaceWindow
    let element: AXUIElement
    let frame: CGRect
    struct Sibling: Equatable {
        let element: AXUIElement
        let spaces: [String]

        static func == (lhs: Self, rhs: Self) -> Bool {
            CFEqual(lhs.element, rhs.element) && lhs.spaces == rhs.spaces
        }
    }

    let siblings: [UInt32: Sibling]
    // Some layer-zero surfaces have no AX window, e.g. a hidden, unassigned AppKit surface.
    // Keep them in both inventories. An empty system response is distinct from a failed read.
    let otherCGSurfaces: [UInt32: [String]]

    static func membership(_ number: UInt32, allowEmpty: Bool = false) -> [String]? {
        guard let raw = NPReadWindowSpaces(number) as? [Any], allowEmpty || !raw.isEmpty,
              raw.count <= 256 else { return nil }
        let values = raw.compactMap(ActionInventory.id)
        return values.count == raw.count && Set(values).count == values.count ? values.sorted() : nil
    }

    private static func value(_ window: AXUIElement, _ key: String) -> CFTypeRef? {
        var reply: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, key as CFString, &reply) == .success ? reply : nil
    }

    static func owner(_ identity: NativeSpaceWindow) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        return identity.pid > 1 && identity.pid != getpid() && identity.pid != getppid()
            && proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &info, size) == size
            && info.pbi_uid == getuid() && info.pbi_pid == UInt32(identity.pid)
            && info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec == identity.birth
    }

    static func cgFrame(_ id: NativeSpaceWindow) -> CGRect? {
        guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id.number) as? [[String: Any]],
              rows.count == 1, let row = rows.first,
              row[kCGWindowNumber as String] as? UInt32 == id.number,
              row[kCGWindowOwnerPID as String] as? Int32 == id.pid, row[kCGWindowLayer as String] as? Int == 0,
              let bounds = row[kCGWindowBounds as String] as? [String: Any]
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    static func read(_ id: NativeSpaceWindow, display: ActionInventory.Display) throws -> Self {
        guard AXIsProcessTrusted(), owner(id), let cg = cgFrame(id),
              cg.width > 0, cg.height > 0, display.bounds.contains(CGPoint(x: cg.midX, y: cg.midY))
        else { throw ActionFailure("窗口进程、身份或显示器无法确认。") }
        let app = AXUIElementCreateApplication(id.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var list: CFArray?
        guard AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 65, &list) == .success,
              let windows = list as? [AXUIElement], windows.count <= 64 else { throw ActionFailure("无法读取同应用窗口。") }
        let matches = windows.filter { NPReadAXWindowNumber($0) == id.number }
        guard matches.count == 1, let w = matches.first else { throw ActionFailure("目标窗口已关闭或重建。") }
        AXUIElementSetMessagingTimeout(w, 0.25)
        var pid: pid_t = 0
        guard AXUIElementGetPid(w, &pid) == .success, pid == id.pid,
              value(w, kAXRoleAttribute) as? String == kAXWindowRole,
              value(w, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              value(w, kAXMinimizedAttribute) as? Bool == false,
              value(w, kAXModalAttribute) as? Bool == false, value(w, "AXFullScreen") as? Bool == false,
              let p = value(w, kAXPositionAttribute), let s = value(w, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
        else { throw ActionFailure("只可移动身份已确认的普通窗口。") }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
              abs(point.x - cg.minX) <= 2, abs(point.y - cg.minY) <= 2,
              abs(size.width - cg.width) <= 2, abs(size.height - cg.height) <= 2
        else { throw ActionFailure("系统窗口几何仍在过渡。") }
        var siblings: [UInt32: Sibling] = [:]
        for sibling in windows where !CFEqual(sibling, w) {
            let number = NPReadAXWindowNumber(sibling)
            var siblingPID: pid_t = 0
            guard AXUIElementGetPid(sibling, &siblingPID) == .success, siblingPID == id.pid,
                  number > 0, number != id.number, siblings[number] == nil, let spaces = membership(number)
            else { throw ActionFailure("同应用其他窗口的归属无法确认。") }
            siblings[number] = Sibling(element: sibling, spaces: spaces)
        }
        guard let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { throw ActionFailure("无法核对同应用窗口清单。") }
        var numbers = Set<UInt32>()
        var otherCGSurfaces = [UInt32: [String]]()
        for row in all where row[kCGWindowOwnerPID as String] as? Int32 == id.pid &&
            row[kCGWindowLayer as String] as? Int == 0 {
            guard let n = row[kCGWindowNumber as String] as? UInt32, n > 0, numbers.insert(n).inserted, numbers.count <= 256
            else { throw ActionFailure("同应用窗口清单不完整。") }
            if n != id.number && siblings[n] == nil {
                guard let spaces = membership(n, allowEmpty: true) else { throw ActionFailure("同应用窗口的归属无法核对。") }
                otherCGSurfaces[n] = spaces
            }
        }
        guard numbers.contains(id.number), owner(id), NPReadAXWindowNumber(w) == id.number else {
            throw ActionFailure("窗口进程或目标身份已变化。")
        }
        return .init(identity: id, element: w, frame: cg, siblings: siblings, otherCGSurfaces: otherCGSurfaces)
    }

    func agreesBeforeDispatch(with other: Self) -> Bool {
        sameWindowAndSiblings(as: other) &&
        abs(frame.minX - other.frame.minX) <= 2 && abs(frame.minY - other.frame.minY) <= 2 &&
        abs(frame.width - other.frame.width) <= 2 && abs(frame.height - other.frame.height) <= 2
    }

    func sameWindowAndSiblings(as other: Self) -> Bool {
        identity == other.identity && CFEqual(element, other.element) && siblings == other.siblings &&
        otherCGSurfaces == other.otherCGSurfaces
    }

    func stillIdentical() -> Bool {
        Self.owner(identity) && Self.cgFrame(identity) != nil && NPReadAXWindowNumber(element) == identity.number &&
        siblings.allSatisfy { Self.membership($0.key) == $0.value.spaces }
    }
}
