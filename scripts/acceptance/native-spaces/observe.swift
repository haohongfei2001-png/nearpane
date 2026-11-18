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
    var rosterScrollAreas = 0
    var permissionControls = Set<String>()
    var knownIssues = Set<String>()
    mutating func visit(_ element: AXUIElement, depth: Int = 0, workspace: Bool = false) {
        guard depth < 36, visited.count < 5000, visited.insert(element).inserted else { return }
        let identifier = value(element, kAXIdentifierAttribute) as? String
        let inWorkspace = workspace || identifier == "desktop-reserved-region"
        if let id = identifier {
            if id.hasPrefix("native-space-row:") || id.hasPrefix("native-space-window:") || id.hasPrefix("current-desktop-window:") {
                controls[id, default: []].append(element)
            }
            if id == "current-desktop-window" { legacyCards += 1 }
            if id == "desktop-reserved-region" { areas += 1 }
        }
        let role = value(element, kAXRoleAttribute) as? String ?? ""
        if inWorkspace && role == "AXScrollArea" { rosterScrollAreas += 1 }
        if let id = identifier, id.hasPrefix("window-access-") {
            permissionControls.insert(id)
            controls[id, default: []].append(element)
        }
        if inWorkspace, role == "AXStaticText", identifier == nil {
            let allowed = ["这扇窗口已变化，请重新选择。", "窗口已离开这个桌面。", "这扇窗口的系统身份已变化。",
                           "精确选择这扇窗口需要允许 Nearpane 使用辅助功能。", "macOS 未允许这个应用置前。",
                           "系统未确认这扇窗口已置前。", "尚未确认目标桌面。", "所选窗口已离开这个桌面。"]
            for key in [kAXTitleAttribute, kAXValueAttribute] {
                if let text = value(element, key) as? String, allowed.contains(text) { knownIssues.insert(text) }
            }
        }
        if identifier == "current-desktop-window" || identifier?.hasPrefix("current-desktop-window:") == true || identifier?.hasPrefix("native-space-window:") == true { return }
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
                "windowCounts": cardCounts, "currentWindowCount": controls.keys.filter { $0.hasPrefix("current-desktop-window:") }.count,
                "permissionControls": permissionControls.sorted(), "rosterScrollAreas": rosterScrollAreas,
                "knownIssueMessages": knownIssues.sorted(), "legacyCardCount": legacyCards, "overviewRegions": areas]
    }

    // Only count positions. Other applications' titles, thumbnails and window IDs stay out of the receipt.
    func fit(on screen: CGRect, panelFrames: [CGRect]) -> Object {
        let cards = controls.filter { $0.key.hasPrefix("current-desktop-window:") }
        let frames: [CGRect] = cards.compactMap { _, elements in
            guard elements.count == 1, let p = value(elements[0], kAXPositionAttribute),
                  let s = value(elements[0], kAXSizeAttribute),
                  CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var origin = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size),
                  size.width > 0, size.height > 0 else { return nil }
            return CGRect(origin: origin, size: size)
        }.sorted { $0.minY < $1.minY }
        let all = !cards.isEmpty && cards.count == frames.count
        let onePanel = panelFrames.contains { panel in frames.allSatisfy { panel.contains($0) } }
        let ordered = zip(frames, frames.dropFirst()).allSatisfy { $0.maxY <= $1.minY + 0.5 }
        return ["cardCount": cards.count, "measured": frames.count, "allOnscreen": all && frames.allSatisfy { screen.contains($0) },
                "insideOnePanel": all && onePanel, "ordered": all && ordered, "scrollAreas": rosterScrollAreas]
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

// Return a tiny region strictly inside this identified fixture's picture. The
// capture executable re-runs this observation before and after its filtered read.
func fixturePictureCrop(card: AXUIElement, bounds: CGRect, text: String, host: pid_t,
                        number: UInt32, birth: UInt64, scope: String, current: UInt64) -> Object? {
    let prefix = "窗口画面，预览 "
    guard text.hasPrefix(prefix), let end = text.range(of: " pt") else { return nil }
    let fields = text[text.index(text.startIndex, offsetBy: prefix.count)..<end.lowerBound].components(separatedBy: " × ")
    guard fields.count == 2, let w = Double(fields[0]), let h = Double(fields[1]),
          w >= 12, h >= 12, w <= bounds.width + 1, h <= bounds.height + 1 else { return nil }
    let crop = CGRect(x: floor(bounds.minX + w / 2 - 2), y: floor(bounds.minY + h / 2 - 2), width: 4, height: 4)
    guard bounds.contains(crop) else { return nil }
    var ancestor = card
    for _ in 0..<36 {
        if value(ancestor, kAXRoleAttribute) as? String == "AXWindow" { break }
        guard let parent = value(ancestor, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
        ancestor = parent as! AXUIElement
    }
    let panel = NPReadAXWindowNumber(ancestor)
    guard panel > 0, value(ancestor, kAXRoleAttribute) as? String == "AXWindow",
          let row = rows.first(where: { $0[kCGWindowNumber as String] as? UInt32 == panel &&
              $0[kCGWindowOwnerPID as String] as? pid_t == host && $0[kCGWindowIsOnscreen as String] as? Bool == true }),
          let bounds = row[kCGWindowBounds as String] as? NSDictionary,
          CGRect(dictionaryRepresentation: bounds)?.contains(crop) == true else { return nil }
    return ["ready": true, "pid": host, "number": panel, "display": scope, "space": current,
            "fixtureNumber": number, "fixtureBirth": birth, "crop": [crop.minX, crop.minY, crop.width, crop.height]]
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
          let memberships = NPReadWindowSpaces(number) as? [UInt64],
          args[1] == "roster-shared-card" ? memberships.contains(sid) : memberships == [sid] else {
        return ["issued": false, "reason": "changed source, application, window or signing identity"]
    }
    let owned = rows.filter { $0[kCGWindowNumber as String] as? UInt32 == number && $0[kCGWindowOwnerPID as String] as? pid_t == fixturePID }
    guard owned.count == 1 else { return ["issued": false, "reason": "no unique owner CG record"] }
    let target = "current-desktop-window:" + args[4] + ":" + args[5]
    if args[1] == "roster-card" || args[1] == "roster-shared-card" {
        let index = Sidebar(host, rows: rows)
        let cg = owned[0]
        let panelFrames: [CGRect] = rows.compactMap { row in
            guard row[kCGWindowOwnerPID as String] as? pid_t == givenHost,
                  row[kCGWindowIsOnscreen as String] as? Bool == true, let bounds = row[kCGWindowBounds as String] as? NSDictionary
            else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
        var out: Object = ["observed": false, "window": number, "fixturePID": fixturePID,
                           "fit": index.fit(on: CGDisplayBounds(CGMainDisplayID()), panelFrames: panelFrames),
                           "spaceRows": index.controls.keys.filter { $0.hasPrefix("native-space-row:") }.count,
                           "membershipCount": memberships.count, "currentSpaceMember": memberships.contains(sid),
                           "stageManager": stage as Any? ?? NSNull(),
                           "publicVisible": (NSWindow.windowNumbers(options: .allApplications) ?? []).contains(NSNumber(value: number)),
                           "cgOnscreen": cg[kCGWindowIsOnscreen as String] as? Bool ?? false,
                           "cgLayer": cg[kCGWindowLayer as String] as Any? ?? NSNull()]
        if let raw = cg[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: raw) {
            out["cgSize"] = [frame.width, frame.height]
        }
        let fixture = AXUIElementCreateApplication(fixturePID)
        _ = AXUIElementSetMessagingTimeout(fixture, 0.2)
        let matches = (value(fixture, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter { NPReadAXWindowNumber($0) == number }
        if matches.count == 1, let attribute = value(matches[0], kAXSizeAttribute), CFGetTypeID(attribute) == AXValueGetTypeID() {
            var axSize = CGSize.zero
            if AXValueGetValue(attribute as! AXValue, .cgSize, &axSize) { out["axSize"] = [axSize.width, axSize.height] }
        }
        guard let exact = index.controls[target], exact.count == 1, let pixels = value(exact[0], kAXValueAttribute) as? String,
              let origin = value(exact[0], kAXPositionAttribute), CFGetTypeID(origin) == AXValueGetTypeID(),
              let extent = value(exact[0], kAXSizeAttribute), CFGetTypeID(extent) == AXValueGetTypeID() else {
            out["reason"] = "no unique fixture card in installed sidebar"
            return out
        }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(origin as! AXValue, .cgPoint, &point), AXValueGetValue(extent as! AXValue, .cgSize, &size) else {
            out["reason"] = "no measured card bounds"
            return out
        }
        out["observed"] = true; out["value"] = pixels; out["cardY"] = point.y; out["cardHeight"] = size.height
        out["pixelCrop"] = fixturePictureCrop(card: exact[0], bounds: CGRect(origin: point, size: size),
            text: pixels, host: givenHost, number: number, birth: birth, scope: args[8], current: sid)
        return out
    }
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
// Exercise only the app's explanation and its dismissal. Never press a consent or System Settings button.
func guideResult() -> Object {
    guard let host, AXIsProcessTrusted(), let signature = runningCodeHash(host.processIdentifier) else {
        return ["status":"BLOCKED", "reason":"installed Host or observer unavailable"]
    }
    func index() -> Sidebar { Sidebar(host, rows: rows) }
    func press(_ id: String) -> Bool {
        guard id == "window-access-guide" || id == "window-access-done",
              !host.isTerminated, runningCodeHash(host.processIdentifier) == signature,
              let found = index().controls[id], found.count == 1,
              value(found[0], kAXEnabledAttribute) as? Bool == true else { return false }
        return AXUIElementPerformAction(found[0], kAXPressAction as CFString) == .success
    }
    guard !index().permissionControls.contains("window-access-done") else { return ["status":"BLOCKED","reason":"guide already open"] }
    guard press("window-access-guide") else { return ["status":"BLOCKED","reason":"no unique visible guide"] }
    var controls = Set<String>()
    for _ in 0..<16 {
        controls = index().permissionControls
        if controls.contains("window-access-done") { break }
        Thread.sleep(forTimeInterval: 0.06)
    }
    let dismissed = press("window-access-done")
    var closed = false
    if dismissed {
        for _ in 0..<16 {
            if !index().permissionControls.contains("window-access-done") { closed = true; break }
            Thread.sleep(forTimeInterval: 0.06)
        }
    }
    let pictures = !controls.isDisjoint(with: ["window-access-allow-pictures","window-access-pictures-granted"])
    let focus = !controls.isDisjoint(with: ["window-access-allow-focus","window-access-focus-granted"])
    return ["status":pictures && focus && closed ? "PASS" : "FAIL", "visibleControls":controls.sorted(),
            "dismissed":closed,"systemPermissionActions":0]
}
if CommandLine.arguments.count > 1 {
    if CommandLine.arguments[1] == "crop" {
        report = titleCrop(CommandLine.arguments)
    } else if CommandLine.arguments[1] == "absence" {
        let ids = CommandLine.arguments.dropFirst(2).compactMap(UInt32.init)
        report = ["allGone": !ids.isEmpty && ids.allSatisfy { NPReadWindowNumberPresence($0) == 0 }]
    } else if CommandLine.arguments[1] == "guide" {
        report = guideResult()
    } else if CommandLine.arguments[1] == "surface" {
        report = surfaceToggle(CommandLine.arguments)
    } else { report = fixtureResult(CommandLine.arguments) }
}
print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
