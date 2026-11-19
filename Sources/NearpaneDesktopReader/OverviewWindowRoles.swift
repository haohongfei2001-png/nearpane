import AppKit
import ApplicationServices

/// Roster evidence only. No title, document, child contents or action handle leaves this read.
struct OverviewWindowRole {
    let ordinary: Bool?
    let minimized: Bool?
    let fullscreen: Bool?

    struct Owner {
        var windows: [UInt32: OverviewWindowRole] = [:]
        var everyNumberKnown = true
    }

    static func read(pids: [Int32], deadline: Double) -> [Int32: Owner] {
        var result: [Int32: Owner] = [:]
        let keys = [kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute, "AXFullScreen", kAXModalAttribute] as CFArray
        let clock = ProcessInfo.processInfo
        for pid in pids {
            guard clock.systemUptime < deadline else { break }
            let app = AXUIElementCreateApplication(pid)
            var rows: CFArray?
            guard AXUIElementSetMessagingTimeout(app, 0.05) == .success,
                  AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 129, &rows) == .success,
                  let windows = rows as? [AXUIElement], windows.count <= 128 else { continue }
            var snapshot = Owner(), seen = Set<UInt32>()
            for window in windows {
                guard clock.systemUptime < deadline else { snapshot.everyNumberKnown = false; break }
                var owner: pid_t = 0
                guard AXUIElementGetPid(window, &owner) == .success, owner == pid,
                      AXUIElementSetMessagingTimeout(window, 0.05) == .success,
                      let number = AdmissionAXRead.windowNumber(window) else {
                    snapshot.everyNumberKnown = false
                    continue
                }
                // A duplicate or unreadable exact match is ineligible, including when
                // the rest of this application's AX list was only partially available.
                guard seen.insert(number).inserted else {
                    snapshot.windows[number] = Self(ordinary: false, minimized: nil, fullscreen: nil)
                    continue
                }
                snapshot.windows[number] = Self(ordinary: nil, minimized: nil, fullscreen: nil)
                var values: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(window, keys, [], &values) == .success,
                      let fields = values as? [Any], fields.count == 5 else { continue }
                let role = fields[0] as? String, subrole = fields[1] as? String
                let ordinary: Bool?
                if (fields[4] as? Bool) == true { ordinary = false }
                else if let role, let subrole { ordinary = role == kAXWindowRole && subrole == kAXStandardWindowSubrole }
                else { ordinary = nil }
                snapshot.windows[number] = Self(ordinary: ordinary,
                                                minimized: fields[2] as? Bool, fullscreen: fields[3] as? Bool)
            }
            result[pid] = snapshot
        }
        return result
    }
}
