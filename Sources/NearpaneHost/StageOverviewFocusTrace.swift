import AppKit
import ApplicationServices
import CNearpaneWindowEngine
import NearpaneCore
import NearpaneOrdinaryWindowRuntime

/// Metadata from the two apps under investigation and the retained original window.
/// The ordinary sidebar never constructs this diagnostic.
final class StageOverviewFocusTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [[String: Any]]()
    private var dropped = 0
    private var tokens = [NSObjectProtocol]()
    private let center = NSWorkspace.shared.notificationCenter
    private static let participants = ["com.microsoft.edgemac", "com.github.GitHubClient"]

    static func clock() -> [String: Any] {
        var scale = mach_timebase_info_data_t()
        mach_timebase_info(&scale)
        return ["uptime": ProcessInfo.processInfo.systemUptime, "unix": Date().timeIntervalSince1970,
                "machAbsolute": mach_absolute_time(), "machContinuous": mach_continuous_time(),
                "numer": scale.numer, "denom": scale.denom]
    }

    init() {
        let names: [(Notification.Name, String)] = [
            (NSWorkspace.didActivateApplicationNotification, "didActivate"),
            (NSWorkspace.didLaunchApplicationNotification, "didLaunch"),
            (NSWorkspace.didTerminateApplicationNotification, "didTerminate"),
            (NSWorkspace.didHideApplicationNotification, "didHide"),
            (NSWorkspace.didUnhideApplicationNotification, "didUnhide"),
            (NSWorkspace.activeSpaceDidChangeNotification, "activeSpaceDidChange"),
            (NSWorkspace.sessionDidResignActiveNotification, "sessionDidResignActive"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "sessionDidBecomeActive")
        ]
        for (name, kind) in names {
            tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                let time = ProcessInfo.processInfo.systemUptime
                var event: [String: Any] = ["kind": kind, "uptime": time]
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    event["pid"] = app.processIdentifier
                    event["birth"] = (try? OrdinaryProcessImage.read(app.processIdentifier))?.launch as Any? ?? NSNull()
                }
                self?.append(event)
            })
        }
    }
    deinit { for token in tokens { center.removeObserver(token) } }

    func mark(_ kind: String) { append(["kind": kind, "uptime": ProcessInfo.processInfo.systemUptime]) }
    private func append(_ row: [String: Any]) {
        lock.withLock {
            if events.count < 160 { events.append(row) } else { dropped += 1 }
        }
    }
    var activations: [[String: Any]] { lock.withLock { events.filter { $0["kind"] as? String == "didActivate" } } }
    func receipt() -> [String: Any] {
        lock.withLock { ["events": events.sorted { ($0["uptime"] as? Double ?? 0) < ($1["uptime"] as? Double ?? 0) },
                         "dropped": dropped, "notificationTime": "callbackDelivery", "clock": "ProcessInfo.systemUptime"] }
    }
    private static func value(_ object: AXUIElement, _ key: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(object, key as CFString, &value)
        return (error, value)
    }
    private static func element(_ object: CFTypeRef?) -> AXUIElement? {
        guard let object, CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        return (object as! AXUIElement)
    }
    private static func windowID(_ raw: CFTypeRef?, pid: pid_t) -> CGWindowID? {
        var owner: pid_t = 0
        guard let window = element(raw), AXUIElementGetPid(window, &owner) == .success, owner == pid else { return nil }
        return NearpaneOrdinaryWindowRuntime.number(window)
    }

    private static func activeSpace(_ connection: inout Int32) -> (number: UInt64?, display: String?, catalogError: Int32, directError: Int32?) {
        var error: Int32 = 0
        let catalog = np_host_scope_copy_managed(&connection, &error) as? [[String: Any]]
        guard error == 0, catalog?.count == 1, let entry = catalog?.first, let display = entry["Display Identifier"] as? String,
              let current = entry["Current Space"] as? [String: Any], let id = StageEngineHostScope.Space(current).number else {
            return (nil, nil, error, nil)
        }
        let direct = np_host_scope_direct(connection, display as CFString, &error)
        return (direct == id && error == 0 ? id : nil, display, 0, error)
    }

    @MainActor func sample(_ phase: String, originalPID: pid_t? = nil, window: AXUIElement? = nil) {
        let start = ProcessInfo.processInfo.systemUptime
        let workspace = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        let (focusError, rawFocus) = Self.value(system, kAXFocusedApplicationAttribute)
        var owner: pid_t = 0
        let ownerError = Self.element(rawFocus).map { AXUIElementGetPid($0, &owner) }
        let login = CGSessionCopyCurrentDictionary() as? [String: Any]
        var evidence: [String: Any] = ["kind": "windowSnapshot", "phase": phase, "uptime": start,
            "workspaceFrontPID": workspace as Any? ?? NSNull(), "axFocusedApplicationError": focusError.rawValue,
            "axFocusedApplicationPID": ownerError == .success ? owner as Any : NSNull(),
            "sessionOnConsole": login?[kCGSessionOnConsoleKey as String] ?? NSNull(),
            "screenLocked": login.map { $0["CGSSessionScreenIsLocked"] as? Bool == true } as Any? ?? NSNull()]
        guard login?[kCGSessionOnConsoleKey as String] as? Bool == true,
              login?[kCGSessionUserIDKey as String] as? uid_t == getuid(),
              login?["CGSSessionScreenIsLocked"] as? Bool != true else { append(evidence); return }
        var conn: Int32 = 0
        let scope = Self.activeSpace(&conn), active = scope.number
        evidence["activeSpace"] = active as Any? ?? NSNull()
        evidence["inventoryError"] = scope.catalogError
        evidence["directError"] = scope.directError as Any? ?? NSNull()
        var subjects = [pid_t: String]()
        for id in Self.participants {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) { subjects[app.processIdentifier] = id }
        }
        if let originalPID, subjects[originalPID] == nil { subjects[originalPID] = "original" }
        let retainedID = originalPID.flatMap { pid in window.flatMap { Self.windowID($0, pid: pid) } }
        if originalPID != nil { evidence["retainedAXWindowID"] = retainedID as Any? ?? NSNull() }
        // Project permitted fields only. Never request AX titles, document attributes or window pixels.
        let cg = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        let visible = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                  kCGNullWindowID) as? [[String: Any]])?.reduce(into: [pid_t: Set<CGWindowID>]()) { ids, row in
            if let pid = row[kCGWindowOwnerPID as String] as? pid_t, subjects[pid] != nil,
               let id = row[kCGWindowNumber as String] as? CGWindowID { ids[pid, default: []].insert(id) }
        }
        evidence["allWindowsRead"] = cg != nil
        evidence["onScreenListRead"] = visible != nil
        var samples = [[String: Any]]()
        for (pid, label) in subjects.sorted(by: { $0.key < $1.key }) {
            guard let app = NSRunningApplication(processIdentifier: pid), let image = try? OrdinaryProcessImage.read(pid) else {
                samples.append(["pid": pid, "subject": label, "status": "generationUnavailable"]); continue
            }
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.15)
            let (frontError, front) = Self.value(ax, kAXFrontmostAttribute)
            let (focusedError, focused) = Self.value(ax, kAXFocusedWindowAttribute)
            var n = 0, list: CFArray?
            let key = kAXWindowsAttribute as CFString
            let countError: AXError? = label == "original" ? nil : AXUIElementGetAttributeValueCount(ax, key, &n)
            let listError: AXError? = countError == .success && (0...32).contains(n) && n > 0
                ? AXUIElementCopyAttributeValues(ax, key, 0, n, &list) : nil
            let axIDs = (list as? [AXUIElement])?.compactMap { Self.windowID($0, pid: pid) }
            let rows = cg?.filter { r in
                r[kCGWindowOwnerPID as String] as? pid_t == pid && r[kCGWindowLayer as String] as? Int == 0 &&
                    (label != "original" || (retainedID != nil && r[kCGWindowNumber as String] as? CGWindowID == retainedID))
            }
            var windows = [[String: Any]]()
            for r in (rows ?? []).prefix(32) {
                guard let id = r[kCGWindowNumber as String] as? CGWindowID else { continue }
                var w: [String: Any] = ["id": id, "layer": 0, "onScreen": r[kCGWindowIsOnscreen as String] ?? NSNull(),
                    "alpha": r[kCGWindowAlpha as String] ?? NSNull(), "frame": r[kCGWindowBounds as String] ?? NSNull()]
                w["inOnScreenList"] = visible.map { $0[pid]?.contains(id) == true } as Any? ?? NSNull()
                if let active {
                    var err: Int32 = 0
                    let reverse = np_host_scope_reverse(conn, id, &err) as? [NSNumber]
                    w["reverseError"] = err
                    w["spaces"] = err == 0 ? reverse as Any? ?? NSNull() : NSNull()
                    let hits = np_host_scope_forward_hits(conn, active, id, &err)
                    w["forwardError"] = err
                    w["activeSpaceHits"] = err == 0 ? hits as Any : NSNull()
                }
                windows.append(w)
            }
            samples.append(["pid": pid, "subject": label, "birth": image.launch,
                "sameGenerationAtEnd": (try? OrdinaryProcessImage.read(pid)) == image,
                "hidden": app.isHidden, "terminated": app.isTerminated,
                "axFrontmostError": frontError.rawValue, "axFrontmost": front as? Bool as Any? ?? NSNull(),
                "axFocusedWindowError": focusedError.rawValue, "axFocusedWindowID": Self.windowID(focused,pid:pid) as Any? ?? NSNull(),
                "axCountError": countError?.rawValue as Any? ?? NSNull(), "axWindowCount": countError == .success ? n as Any : NSNull(),
                "axListError": listError?.rawValue as Any? ?? NSNull(),
                "axWindowIDs": (n == 0 && countError == .success ? [] : axIDs) as Any? ?? NSNull(),
                "scope": label == "original" ? "retainedWindowOnly" : "application",
                "cgLayerZeroCount": rows?.count as Any? ?? NSNull(), "windows": windows])
        }
        evidence["subjects"] = samples
        let endScope = Self.activeSpace(&conn)
        evidence["activeSpaceAtEnd"] = endScope.number as Any? ?? NSNull()
        evidence["sameActiveSpace"] = active != nil && active == endScope.number && scope.display == endScope.display
        evidence["workspaceFrontPIDAtEnd"] = NSWorkspace.shared.frontmostApplication?.processIdentifier as Any? ?? NSNull()
        evidence["endUptime"] = ProcessInfo.processInfo.systemUptime
        append(evidence)
    }
}
