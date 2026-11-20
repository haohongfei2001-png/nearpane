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
        var allRolesRead = true
    }

    struct Target: Equatable {
        let pid: Int32
        var numbers: Set<UInt32>
    }

    static func schedule(_ targets: [Target], deadline: Double, now: () -> Double,
                         readOwner: (Target, Double) -> Owner?) -> [Int32: Owner] {
        var result: [Int32: Owner] = [:]
        for (index, target) in targets.enumerated() {
            let start = now()
            guard start < deadline else { break }
            let slice = (deadline - start) / Double(targets.count - index)
            result[target.pid] = readOwner(target, start + slice)
        }
        return result
    }

    private static func rotated<T>(_ array: [T], revision: UInt64) -> [T] {
        guard array.count > 1 else { return array }
        let first = Int(revision % UInt64(array.count))
        return Array(array[first...]) + array[..<first]
    }

    static func read(targets: [Target], revision: UInt64, deadline: Double) -> [Int32: Owner] {
        let clock = ProcessInfo.processInfo
        return schedule(rotated(targets, revision: revision), deadline: deadline, now: { clock.systemUptime }) {
            readOwner($0, revision: revision, deadline: $1)
        }
    }

    private static func readOwner(_ target: Target, revision: UInt64, deadline: Double) -> Owner? {
        let clock = ProcessInfo.processInfo
        func setTimeout(_ element: AXUIElement, until limit: Double) -> Bool {
            let remaining = limit - clock.systemUptime
            guard remaining > 0 else { return false }
            return AXUIElementSetMessagingTimeout(element, Float(min(0.05, remaining))) == .success
        }

        let app = AXUIElementCreateApplication(target.pid)
        var rows: CFArray?
        guard setTimeout(app, until: deadline),
              AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 129, &rows) == .success,
              let windows = rows as? [AXUIElement], windows.count <= 128 else { return nil }
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute, "AXFullScreen", kAXModalAttribute] as CFArray
        return readRows(rotated(windows, revision: revision), wanted: target.numbers, deadline: deadline,
                        now: { clock.systemUptime }, number: { window, limit in
            var pid: pid_t = 0
            guard setTimeout(window, until: limit), AXUIElementGetPid(window, &pid) == .success, pid == target.pid,
                  setTimeout(window, until: limit) else { return nil }
            return AdmissionAXRead.windowNumber(window, beforeFallback: { setTimeout(window, until: limit) })
        }, role: { window, limit in
            var values: CFArray?
            guard setTimeout(window, until: limit),
                  AXUIElementCopyMultipleAttributeValues(window, attributes, [], &values) == .success,
                  let fields = values as? [Any], fields.count == 5 else { return nil }
            let role = fields[0] as? String, subrole = fields[1] as? String
            let ordinary: Bool?
            if (fields[4] as? Bool) == true { ordinary = false }
            else if let role, let subrole { ordinary = role == kAXWindowRole && subrole == kAXStandardWindowSubrole }
            else { ordinary = nil }
            return Self(ordinary: ordinary, minimized: fields[2] as? Bool, fullscreen: fields[3] as? Bool)
        })
    }

    static func readRows<Row>(_ rows: [Row], wanted: Set<UInt32>, deadline: Double, now: () -> Double,
                              number: (Row, Double) -> UInt32?, role: (Row, Double) -> Self?) -> Owner {
        var snapshot = Owner(), seen = Set<UInt32>()
        for (index, row) in rows.enumerated() {
            let start = now()
            guard start < deadline else { snapshot.everyNumberKnown = false; break }
            let limit = start + (deadline - start) / Double(rows.count - index)
            guard let n = number(row, limit) else { snapshot.everyNumberKnown = false; continue }
            guard wanted.contains(n) else { continue }
            guard seen.insert(n).inserted else {
                snapshot.windows[n] = Self(ordinary: false, minimized: nil, fullscreen: nil)
                continue
            }
            guard now() < limit, let result = role(row, limit), now() <= limit else {
                snapshot.allRolesRead = false
                snapshot.windows[n] = Self(ordinary: nil, minimized: nil, fullscreen: nil)
                continue
            }
            if result.ordinary == nil || (result.ordinary == true && result.minimized == nil) { snapshot.allRolesRead = false }
            snapshot.windows[n] = result
        }
        return snapshot
    }
}
