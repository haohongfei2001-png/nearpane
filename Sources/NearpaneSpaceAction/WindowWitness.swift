import AppKit
import CReadOnlySpaces
import NearpaneCore

struct WindowWitness {
    let identity: NativeSpaceWindow
    let element: AXUIElement
    let siblings: [UInt32: [String]]

    static func membership(_ number: UInt32) -> [String]? {
        guard let raw = NPReadWindowSpaces(number) as? [Any], !raw.isEmpty, raw.count <= 256 else { return nil }
        let values = raw.compactMap(ActionInventory.id)
        return values.count == raw.count && Set(values).count == values.count ? values.sorted() : nil
    }

    private static func value(_ window: AXUIElement, _ key: String) -> CFTypeRef? {
        var reply: CFTypeRef?
        return AXUIElementCopyAttributeValue(window, key as CFString, &reply) == .success ? reply : nil
    }

    private static func owner(_ identity: NativeSpaceWindow) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        return identity.pid > 1 && identity.pid != getpid() && identity.pid != getppid()
            && proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &info, size) == size
            && info.pbi_uid == getuid() && info.pbi_pid == UInt32(identity.pid)
            && info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec == identity.birth
    }

    private static func cgFrame(_ id: NativeSpaceWindow) -> CGRect? {
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
        var siblings: [UInt32: [String]] = [:]
        for sibling in windows where !CFEqual(sibling, w) {
            let number = NPReadAXWindowNumber(sibling)
            guard number > 0, number != id.number, siblings[number] == nil, let membership = membership(number)
            else { throw ActionFailure("同应用其他窗口的归属无法确认。") }
            siblings[number] = membership
        }
        return .init(identity: id, element: w, siblings: siblings)
    }

    func stillIdentical() -> Bool {
        Self.owner(identity) && Self.cgFrame(identity) != nil && NPReadAXWindowNumber(element) == identity.number &&
        siblings.allSatisfy { Self.membership($0.key) == $0.value }
    }
}
