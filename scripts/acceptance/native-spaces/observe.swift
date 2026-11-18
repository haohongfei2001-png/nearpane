import AppKit
import ApplicationServices
import Foundation
import Security

// System-side witness. Reads system metadata and Nearpane accessibility identifiers only.
typealias Object = [String: Any]
let installed = URL(fileURLWithPath: "/Applications/Nearpane.app", isDirectory: true)
let bundleID = "com.holdsnow.nearpane.alpha"

func value(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(node, key as CFString, &result) == .success ? result : nil
}

func runningCodeHash(_ pid: pid_t) -> String? {
    var code: SecCode?
    var info: CFDictionary?
    var staticCode: SecStaticCode?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary,
                                         [], &code) == errSecSuccess,
          let code, SecCodeCheckValidity(code, [], nil) == errSecSuccess,
          SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let bytes = (info as? Object)?[kSecCodeInfoUnique as String] as? Data else { return nil }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

func inventory() -> [Object]? {
    guard NPReadOnlySpacesOpen() == 1, let scopes = NPReadInventory() as? [Object] else { return nil }
    return scopes.compactMap { scope in
        guard let name = scope["Display Identifier"] as? String,
              let current = (scope["Current Space"] as? Object)?["id64"] as? UInt64,
              let records = scope["Spaces"] as? [Object] else { return nil }
        return ["scope": name, "current": current, "records": records.compactMap { rec -> Object? in
            guard let id = rec["id64"] as? UInt64, let type = rec["type"] as? Int else { return nil }
            let uuid = (rec["uuid"] as? String).flatMap(UUID.init(uuidString:))
            return ["id": id, "type": type, "uuid": uuid?.uuidString as Any? ?? NSNull()]
        }]
    }
}

func displays() -> [Object] {
    NSScreen.screens.compactMap { screen in
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
              let uuid = CGDisplayCreateUUIDFromDisplayID(n)?.takeRetainedValue() else { return nil }
        let r = CGDisplayBounds(n)
        return ["uuid": CFUUIDCreateString(nil, uuid) as String, "bounds": [r.minX, r.minY, r.width, r.height],
                "scale": screen.backingScaleFactor, "rotation": CGDisplayRotation(n), "main": n == CGMainDisplayID()]
    }
}

func occupancy(_ rows: [Object], excluding host: pid_t?) -> Object {
    var counts: [String: Int] = [:]
    var unknown = 0
    for row in rows {
        guard let pid = row[kCGWindowOwnerPID as String] as? pid_t, pid != host,
              row[kCGWindowLayer as String] as? Int == 0,
              let id = row[kCGWindowNumber as String] as? UInt32 else { continue }
        guard let memberships = NPReadWindowSpaces(id) as? [UInt64], !memberships.isEmpty else {
            unknown += 1; continue
        }
        for space in Set(memberships) { counts[String(space), default: 0] += 1 }
    }
    return ["counts": counts, "unresolved": unknown]
}

struct Sidebar {
    var visited = Set<AXUIElement>()
    var controls = [String: [AXUIElement]]()
    var legacyCards = 0
    var areas = 0
    var knownIssues = Set<String>()
    mutating func visit(_ element: AXUIElement, depth: Int = 0, workspace: Bool = false) {
        guard depth < 36, visited.count < 5000, visited.insert(element).inserted else { return }
        let identifier = value(element, kAXIdentifierAttribute) as? String
        let inWorkspace = workspace || identifier == "desktop-reserved-region"
        if let id = identifier {
            if id.hasPrefix("native-space-row:") || id.hasPrefix("native-space-window:") {
                controls[id, default: []].append(element)
            }
            if id == "current-desktop-window" { legacyCards += 1 }
            if id == "desktop-reserved-region" { areas += 1 }
        }
        let role = value(element, kAXRoleAttribute) as? String ?? ""
        if inWorkspace, role == "AXStaticText", identifier == nil {
            let allowed = ["这扇窗口已变化，请重新选择。", "窗口已离开这个桌面。", "这扇窗口的系统身份已变化。",
                           "精确选择这扇窗口需要允许 Nearpane 使用辅助功能。", "macOS 未允许这个应用置前。",
                           "系统未确认这扇窗口已置前。", "尚未确认目标桌面。", "所选窗口已离开这个桌面。"]
            for key in [kAXTitleAttribute, kAXValueAttribute] {
                if let text = value(element, key) as? String, allowed.contains(text) { knownIssues.insert(text) }
            }
        }
        if identifier == "current-desktop-window" || identifier?.hasPrefix("native-space-window:") == true { return }
        guard !["AXTextArea", "AXTextField", "AXStaticText", "AXWebArea", "AXImage"].contains(role) else { return }
        for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth: depth + 1, workspace: inWorkspace) }
    }

    init(_ app: NSRunningApplication, rows: [Object]) {
        guard AXIsProcessTrusted() else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(root, 0.35)
        for w in value(root, kAXWindowsAttribute) as? [AXUIElement] ?? [] { visit(w) }
        visit(root)
        for r in rows where r[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier &&
            r[kCGWindowIsOnscreen as String] as? Bool == true {
            guard let bounds = r[kCGWindowBounds as String] as? NSDictionary,
                  let f = CGRect(dictionaryRepresentation: bounds), f.width > 30, f.height > 100 else { continue }
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(root, Float(f.midX), Float(f.minY + 0.68 * f.height), &hit) == .success,
                  var el = hit else { continue }
            for _ in 0..<24 {
                var pid: pid_t = 0
                guard AXUIElementGetPid(el, &pid) == .success, pid == app.processIdentifier else { break }
                if value(el, kAXRoleAttribute) as? String == "AXWindow" { visit(el); break }
                guard let p = value(el, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
                el = p as! AXUIElement
            }
        }
    }

    var report: Object {
        var rowReports: [Object] = []
        var cardCounts: [String: Int] = [:]
        for (id, nodes) in controls {
            let parts = id.split(separator: ":")
            if parts.first == "native-space-row", parts.count == 3 {
                let node = nodes[0]
                var names: CFArray?
                _ = AXUIElementCopyActionNames(node, &names)
                let text = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { value(node, $0) as? String }
                let currentLabel = text.contains { $0.range(of: #"^(桌面 [1-9][0-9]*|全屏)，当前桌面$"#, options: .regularExpression) != nil }
                rowReports.append(["identifier": id, "currentLabel": currentLabel, "matches": nodes.count,
                                   "enabled": value(node, kAXEnabledAttribute) as? Bool ?? false,
                                   "press": (names as? [String])?.contains(kAXPressAction) == true,
                                   "selected": (value(node, kAXSelectedAttribute) as? Bool) as Any? ?? NSNull()])
            } else if parts.first == "native-space-window", parts.count == 5 {
                let key = parts[1...2].joined(separator: ":")
                cardCounts[key, default: 0] += 1
            }
        }
        return ["rows": rowReports.sorted { ($0["identifier"] as? String ?? "") < ($1["identifier"] as? String ?? "") },
                "windowCounts": cardCounts, "knownIssueMessages": knownIssues.sorted(), "legacyCardCount": legacyCards, "overviewRegions": areas]
    }
}

let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { !$0.isTerminated && $0.bundleURL?.standardizedFileURL == installed.standardizedFileURL }
let host = apps.count == 1 ? apps.first : nil
let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [Object]
let spaces = inventory()
let rows = list ?? []
let front = NSWorkspace.shared.frontmostApplication
func focusedNumber(_ pid: pid_t?) -> UInt32? {
    guard AXIsProcessTrusted(), let pid else { return nil }
    let root = AXUIElementCreateApplication(pid)
    _ = AXUIElementSetMessagingTimeout(root, 0.18)
    guard let win = value(root, kAXFocusedWindowAttribute), CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
    let number = NPReadAXWindowNumber(win)
    return number == 0 ? nil : number
}
let stage = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString) as? Bool
var report: Object = ["timestamp": Date().timeIntervalSince1970, "uptime": ProcessInfo.processInfo.systemUptime,
                      "observerAX": AXIsProcessTrusted(), "observerScreenRead": CGPreflightScreenCaptureAccess(),
                      "separateSpaces": NSScreen.screensHaveSeparateSpaces, "displays": displays(),
                      "stageManager": stage as Any? ?? NSNull(),
                      "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "scopes": spaces as Any? ?? NSNull(), "windowListAvailable": list != nil,
                      "frontmostPID": front?.processIdentifier as Any? ?? NSNull(),
                      "focusedNumber": focusedNumber(front?.processIdentifier) as Any? ?? NSNull(),
                      "installedHostCount": apps.count, "privateTitlesRead": false, "pixelsRequested": 0]
if let spaces, !spaces.isEmpty, list != nil { report["otherLayerZeroMemberships"] = occupancy(rows, excluding: host?.processIdentifier) }
if let host {
    report["host"] = ["pid": host.processIdentifier, "launch": host.launchDate?.timeIntervalSince1970 as Any? ?? NSNull(),
                      "codeHash": runningCodeHash(host.processIdentifier) as Any? ?? NSNull()]
    report["sidebar"] = Sidebar(host, rows: rows).report
}
// Pre-capture geometry for a title-only, explicitly included product window. Never
// capture an entire sidebar into memory to crop out the voice or screenshot modules.
func titleCrop(_ args: [String]) -> Object {
    guard args.count == 3, let host, runningCodeHash(host.processIdentifier) == args[2],
          AXIsProcessTrusted(), let scope = spaces?.first, spaces?.count == 1,
          let d = scope["scope"] as? String, let current = scope["current"] as? UInt64 else { return ["ready":false,"reason":"host/source identity"] }
    let id = "native-space-row:" + d + ":" + String(current)
    guard let matches = Sidebar(host, rows: rows).controls[id], matches.count == 1 else { return ["ready":false,"reason":"exact current row"] }
    let currentNode = matches[0]
    guard let p = value(currentNode, kAXPositionAttribute), let z = value(currentNode, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(z) == AXValueGetTypeID() else { return ["ready":false,"reason":"AX frame"] }
    var origin = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(z as! AXValue, .cgSize, &size),
          size.width >= 66, size.height >= 28 else { return ["ready":false,"reason":"row label size"] }
    var parent = currentNode
    for _ in 0..<32 {
        if value(parent,kAXRoleAttribute) as? String == "AXWindow" { break }
        guard let next = value(parent,kAXParentAttribute), CFGetTypeID(next) == AXUIElementGetTypeID() else { return ["ready":false,"reason":"AX window ancestor"] }
        parent = next as! AXUIElement
    }
    let n = NPReadAXWindowNumber(parent)
    // The native cards start 22 pt below the row's top. Leave a margin entirely
    // inside the header, and filter out every WindowServer layer except this one.
    let crop = CGRect(x: ceil(origin.x+3), y: ceil(origin.y+2), width: 60, height: 17)
    guard n > 0, let cg = rows.first(where: { $0[kCGWindowOwnerPID as String] as? Int32 == host.processIdentifier &&
            $0[kCGWindowNumber as String] as? UInt32 == n && $0[kCGWindowIsOnscreen as String] as? Bool == true }),
          let raw = cg[kCGWindowBounds as String] as? NSDictionary, let actual = CGRect(dictionaryRepresentation: raw),
          actual.contains(crop) else { return ["ready":false,"reason":"owned visible window contains ROI"] }
    return ["ready":true,"pid":host.processIdentifier, "number":n, "display":d, "row":id,
            "crop":[crop.minX,crop.minY,crop.width,crop.height], "signature":args[2]]
}
// Mutating commands are restricted to an installed Host and this invocation's signed,
// exact fixture generation. An event is never sent to the system-wide focused app.
func birthMicroseconds(_ pid: pid_t) -> UInt64? {
    var p = proc_bsdinfo()
    let s = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &p, s) == s, p.pbi_start_tvsec > 0 else { return nil }
    return p.pbi_start_tvsec * 1_000_000 + p.pbi_start_tvusec
}

func fixtureResult(_ args: [String]) -> Object {
    guard args.count == 11, let host, let givenHost = Int32(args[2]), host.processIdentifier == givenHost,
          runningCodeHash(host.processIdentifier) == args[3], let fixturePID = Int32(args[4]),
          let birth = UInt64(args[10]), birth == birthMicroseconds(fixturePID),
          let number = UInt32(args[5]), let fx = NSRunningApplication(processIdentifier: fixturePID),
          fx.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == URL(fileURLWithPath: args[6]).resolvingSymlinksInPath().standardizedFileURL.path,
          fx.bundleIdentifier == "net.example.spaces-document", runningCodeHash(fixturePID) == args[7],
          let scope = spaces?.first(where: { $0["scope"] as? String == args[8] }),
          let sid = scope["current"] as? UInt64, String(sid) == args[9],
          (scope["records"] as? [Object])?.contains(where: { $0["id"] as? UInt64 == sid && $0["type"] as? Int == 0 }) == true,
          (NPReadWindowSpaces(number) as? [UInt64]) == [sid],
          rows.filter({ $0[kCGWindowNumber as String] as? UInt32 == number &&
                         $0[kCGWindowOwnerPID as String] as? pid_t == fixturePID }).count == 1 else {
        return ["issued": false, "reason": "changed source, application, window or signing identity"]
    }
    let target = "native-space-window:" + args[8] + ":" + args[9] + ":" + args[4] + ":" + args[5]
    if args[1] == "fixture-inventory" {
        let ax = AXUIElementCreateApplication(fixturePID)
        _ = AXUIElementSetMessagingTimeout(ax, 0.25)
        let axRows = (value(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []).map { child -> Object in
            ["number":NPReadAXWindowNumber(child), "role":value(child,kAXRoleAttribute) as? String ?? "",
             "subrole":value(child,kAXSubroleAttribute) as? String ?? ""]
        }
        let owned = rows.compactMap { r -> Object? in
            guard r[kCGWindowOwnerPID as String] as? pid_t == fixturePID, r[kCGWindowLayer as String] as? Int == 0,
                  let n = r[kCGWindowNumber as String] as? UInt32 else { return nil }
            return ["number":n, "onScreen":r[kCGWindowIsOnscreen as String] as? Bool ?? false,
                    "alpha":r[kCGWindowAlpha as String] as? Double as Any? ?? NSNull(),
                    "bounds":r[kCGWindowBounds as String] as? Object ?? [:],
                    "sharing":r[kCGWindowSharingState as String] as? UInt32 as Any? ?? NSNull(),
                    "members":NPReadWindowSpaces(n) as? [UInt64] as Any? ?? NSNull()]
        }
        return ["issued":false, "fixturePID":fixturePID, "birth":birth, "appKitNumber":number, "axWindows":axRows,
                "cgLayerZero":owned, "observerAX":AXIsProcessTrusted()]
    }
    if args[1] == "press" {
        let index = Sidebar(host, rows: rows)
        guard let exact = index.controls[target], exact.count == 1,
              value(exact[0], kAXEnabledAttribute) as? Bool == true else {
            return ["issued": false, "reason": "installed sidebar has no unique enabled target control"]
        }
        let result = AXUIElementPerformAction(exact[0], kAXPressAction as CFString)
        return ["issued": true, "control": target, "axError": result.rawValue]
    }
    guard args[1] == "marker", let marker = ProcessInfo.processInfo.environment["NP_TRIAL_MARKER"],
          marker.utf8.count == 12, marker.hasPrefix("NP"), marker.dropFirst(2).allSatisfy({ $0.isHexDigit }),
          NSWorkspace.shared.frontmostApplication?.processIdentifier == fixturePID else {
        return ["issued": false, "reason": "fixture not frontmost or invalid synthetic marker"]
    }
    let ax = AXUIElementCreateApplication(fixturePID)
    guard let win = value(ax, kAXFocusedWindowAttribute), CFGetTypeID(win) == AXUIElementGetTypeID(),
          NPReadAXWindowNumber(win) == number, let editor = value(ax, kAXFocusedUIElementAttribute),
          CFGetTypeID(editor) == AXUIElementGetTypeID(),
          value(editor as! AXUIElement, kAXRoleAttribute) as? String == "AXTextArea",
          let editorWindow = value(editor as! AXUIElement, kAXWindowAttribute), CFEqual(win, editorWindow),
          CGPreflightPostEventAccess(), let source = CGEventSource(stateID: .privateState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
        return ["issued": false, "reason": "exact AX window/editor or event permission missing"]
    }
    let utf16 = Array(marker.utf16)
    down.flags = []; up.flags = []
    down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
    up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
    down.postToPid(fixturePID); up.postToPid(fixturePID)
    return ["issued": true, "targetedOnly": true, "axFocusedWindow": number]
}
func surfaceToggle(_ args: [String]) -> Object {
    guard args.count == 5, let host, args[2] == String(host.processIdentifier), args[3] == runningCodeHash(host.processIdentifier),
          AXIsProcessTrusted(), ["hide","show"].contains(args[4]) else { return ["issued":false, "reason":"host identity"] }
    let root = AXUIElementCreateApplication(host.processIdentifier)
    guard let bar = value(root, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID(),
          let entries = value(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement],
          entries.count == 1 else { return ["issued":false, "reason":"no unique product status item"] }
    let item = entries[0]
    let wanted = args[4] == "hide" ? "隐藏侧栏" : "显示侧栏"
    // Setting is changed only by a labeled item in the live product's own status menu.
    func menus() -> [AXUIElement] {
        (value(item, kAXChildrenAttribute) as? [AXUIElement] ?? []).filter { value($0, kAXRoleAttribute) as? String == "AXMenu" }
    }
    var names: CFArray?
    _ = AXUIElementCopyActionNames(item, &names)
    let actions = names as? [String] ?? []
    // NSStatusItem can synchronously track its menu. AXPress may time out while the
    // menu is actually open. A bounded AX timeout followed by readback avoids replay.
    _ = AXUIElementSetMessagingTimeout(item, 0.4)
    let existingMenus = menus()
    let presented = existingMenus.isEmpty
    var menuResult: Int32?
    if presented {
        guard let action = [kAXPressAction, kAXShowMenuAction].first(where: actions.contains) else {
            return ["issued":false,"reason":"status menu has no opening action","actions":actions]
        }
        menuResult = AXUIElementPerformAction(item, action as CFString).rawValue
    }
    defer {
        if presented {
            for menu in menus() { _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
        }
    }
    for _ in 0..<18 {
        let shown = menus()
        if shown.count == 1, let children = value(shown[0], kAXChildrenAttribute) as? [AXUIElement] {
            let matches = children.filter { value($0, kAXRoleAttribute) as? String == "AXMenuItem" &&
                value($0, kAXTitleAttribute) as? String == wanted && value($0, kAXEnabledAttribute) as? Bool == true }
            guard matches.count == 1 else { return ["issued":false,"reason":"toggle absent or state changed"] }
            return ["issued":true, "axError": AXUIElementPerformAction(matches[0],kAXPressAction as CFString).rawValue]
        }
        Thread.sleep(forTimeInterval: 0.04)
    }
    return ["issued":false,"reason":"menu did not expose toggle","openResult":menuResult as Any? ?? NSNull(),"actions":actions]
}
if CommandLine.arguments.count > 1 {
    if CommandLine.arguments[1] == "crop" {
        report = titleCrop(CommandLine.arguments)
    } else if CommandLine.arguments[1] == "absence" {
        let ids = CommandLine.arguments.dropFirst(2).compactMap(UInt32.init)
        report = ["allGone": !ids.isEmpty && ids.allSatisfy { NPReadWindowNumberPresence($0) == 0 }]
    } else if CommandLine.arguments[1] == "surface" {
        report = surfaceToggle(CommandLine.arguments)
    } else { report = fixtureResult(CommandLine.arguments) }
}
print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
