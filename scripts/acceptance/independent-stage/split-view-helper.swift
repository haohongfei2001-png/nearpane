// A scoped adapter around the existing native menu and signed picker readers.
// It issues at most one system action. The product harness proves handoff, actual
// Split View membership/geometry and restoration; an issued input is never PASS.
import AppKit
import ApplicationServices
import Foundation
import Security

typealias Object = [String: Any]

// Compatibility surface for the existing split-picker.swift. Only metadata for
// the requested fixture or signed system picker is inspected; no image is read.
enum PreviewCensus {
    static func windowRows(_ number: UInt32) -> [Object]? {
        guard let ids = CFArrayCreateMutable(nil, 1, nil),
              let raw = UnsafeRawPointer(bitPattern: UInt(number)) else { return nil }
        CFArrayAppendValue(ids, raw)
        return CGWindowListCreateDescriptionFromArray(ids) as? [Object]
    }
    static func apple(_ pid: pid_t) -> String? {
        switch OverviewProcess.name(of: pid) {
        case OverviewAgent.dock.rawValue: return "appleDock"
        case OverviewAgent.manager.rawValue: return "appleWindowManager"
        case OverviewAgent.launcher.rawValue: return "appleMissionControl"
        default: return nil
        }
    }
}

func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? { attr(element, name) }
func splitFrame(_ node: AXUIElement) -> CGRect? {
    guard let p = value(node, kAXPositionAttribute), let s = value(node, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    let rect = CGRect(origin: point, size: size)
    return SplitPickerGeometry.valid(rect) ? rect : nil
}
func numericRect(_ frame: CGRect) -> [Double] { [frame.minX, frame.minY, frame.width, frame.height] }
func keyPoint(_ element: AXUIElement) -> AXUIElement? {
    guard let parent = value(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
    return (parent as! AXUIElement)
}
func hasAncestor(_ child: AXUIElement, _ target: AXUIElement, owner: pid_t) -> Bool {
    var element: AXUIElement? = child
    for _ in 0..<24 {
        var pid: pid_t = 0
        guard let current = element, AXUIElementGetPid(current, &pid) == .success, pid == owner else { return false }
        if CFEqual(current, target) { return true }
        element = keyPoint(current)
    }
    return false
}
func supportedPress(_ element: AXUIElement) -> Bool {
    var actions: CFArray?
    return AXUIElementCopyActionNames(element, &actions) == .success &&
        (actions as? [String])?.contains(kAXPressAction) == true
}

private struct SplitRequest: Decodable {
    let operation: String
    let fixturePID: pid_t, fixtureBirth: UInt64, fixtureExecutable: String
    let nonce: UUID, numbers: [UInt32], home: UInt64
}

private func realPath(_ text: String) -> String? {
    guard let resolved = realpath(text, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
private func processPath(_ pid: pid_t) -> String? {
    var bytes = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
    return realPath(String(cString: bytes))
}
private func inputCounters() -> [UInt32] {
    [CGEventType.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged,
     .scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].map {
        CGEventSource.counterForEventType(.hidSystemState, eventType: $0)
    }
}
private func title(_ r: SplitRequest, index: Int) -> String {
    "Nearpane Fixture " + r.nonce.uuidString.lowercased() +
        " com.holdsnow.stage-engine-fixture-a " + String(index)
}
private func fixtureIsCurrent(_ r: SplitRequest) -> Bool {
    guard r.fixturePID > 1, r.fixturePID != getpid(),
          OverviewProcess.kernelBirth(r.fixturePID) == r.fixtureBirth,
          let helper = processPath(getpid()), let requested = realPath(r.fixtureExecutable),
          let adjacent = realPath(URL(fileURLWithPath: helper).deletingLastPathComponent()
            .appendingPathComponent("FixtureA.app/Contents/MacOS/FixtureA").path), requested == adjacent,
          processPath(r.fixturePID) == requested else { return false }
    var code: SecCode?, requirement: SecRequirement?
    let rule = "identifier \"com.holdsnow.stage-engine-fixture-a\""
    return SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess &&
        SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: r.fixturePID)] as CFDictionary, [], &code) == errSecSuccess &&
        code.map { SecCodeCheckValidity($0, [], requirement) == errSecSuccess } == true &&
        OverviewProcess.kernelBirth(r.fixturePID) == r.fixtureBirth
}
private func nativeStageEnabled() -> Bool? {
    // Match production StageManagerPreference.read: an effective CFBoolean wins;
    // factory-off requires an absent, unforced key in both host domains and an
    // immediately repeated absent effective value. This helper never sets it.
    let domain = "com.apple.WindowManager" as CFString, key = "GloballyEnabled" as CFString
    if let effective = CFPreferencesCopyAppValue(key, domain) {
        return CFGetTypeID(effective) == CFBooleanGetTypeID() ? effective as? Bool : nil
    }
    guard !CFPreferencesAppValueIsForced(key, domain) else { return nil }
    let requested = [key] as CFArray
    guard [kCFPreferencesCurrentHost, kCFPreferencesAnyHost].allSatisfy({ host in
        CFDictionaryGetCount(CFPreferencesCopyMultiple(requested, domain, kCFPreferencesCurrentUser, host)) == 0
    }), CFPreferencesCopyAppValue(key, domain) == nil else { return nil }
    return false
}
private func nativeContext() -> Bool {
    let session = CGSessionCopyCurrentDictionary() as? Object
    return AXIsProcessTrusted() && session?[kCGSessionOnConsoleKey as String] as? Bool == true &&
        session?[kCGSessionUserIDKey as String] as? NSNumber == NSNumber(value: getuid()) &&
        session?["CGSSessionScreenIsLocked"] as? Bool != true &&
        nativeStageEnabled() == false
}
private struct Catalog {
    let current: UInt64
    let kinds: [UInt64: Int]
    static func read() -> Self? {
        guard let displays = NPReadInventory() as? [Object], displays.count == 1,
              let current = displays[0]["Current Space"] as? Object,
              let currentID = current["id64"] as? UInt64,
              let spaces = displays[0]["Spaces"] as? [Object], !spaces.isEmpty else { return nil }
        var kinds = [UInt64: Int]()
        for space in spaces {
            guard let id = space["id64"] as? UInt64, id > 0,
                  let kind = space["type"] as? Int, kinds[id] == nil else { return nil }
            kinds[id] = kind
        }
        return kinds[currentID] != nil ? .init(current: currentID, kinds: kinds) : nil
    }
}
private func membership(_ number: UInt32, _ space: UInt64) -> Bool {
    (NPReadWindowSpaces(number) as? [UInt64]) == [space] &&
        (NPReadCatalogSpaceWindowNumbers(space) as? [UInt32])?.contains(number) == true
}
private func window(_ r: SplitRequest, index: Int, root: AXUIElement) -> AXUIElement? {
    guard let windows = value(root, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
    let matches = windows.filter { NPReadAXWindowNumber($0) == r.numbers[index] }
    var pid: pid_t = 0
    guard matches.count == 1, let found = matches.first, AXUIElementGetPid(found, &pid) == .success,
          pid == r.fixturePID, value(found, kAXRoleAttribute) as? String == kAXWindowRole,
          value(found, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
          value(found, kAXMinimizedAttribute) as? Bool == false,
          value(found, kAXTitleAttribute) as? String == title(r, index: index) else { return nil }
    return found
}
private func sourceFocused(_ r: SplitRequest, root: AXUIElement, source: AXUIElement) -> Bool {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == r.fixturePID,
          value(root, kAXFrontmostAttribute) as? Bool == true,
          let focus = value(root, kAXFocusedWindowAttribute), CFGetTypeID(focus) == AXUIElementGetTypeID(),
          CFEqual(focus, source), NPReadAXWindowNumber(focus) == r.numbers[0] else { return false }
    return NSWorkspace.shared.frontmostApplication?.processIdentifier == r.fixturePID && fixtureIsCurrent(r)
}
private func liveFrame(_ r: SplitRequest, index: Int) -> CGRect? {
    guard let rows = PreviewCensus.windowRows(r.numbers[index]), rows.count == 1, let row = rows.first,
          row[kCGWindowOwnerPID as String] as? pid_t == r.fixturePID,
          row[kCGWindowNumber as String] as? UInt32 == r.numbers[index],
          row[kCGWindowLayer as String] as? Int == 0, row[kCGWindowIsOnscreen as String] as? Bool == true,
          let alpha = row[kCGWindowAlpha as String] as? Double, alpha > 0,
          let bounds = row[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: bounds), SplitPickerGeometry.valid(rect) else { return nil }
    return rect
}

@MainActor private func perform(_ r: SplitRequest) -> Object {
    var result: Object = ["schema": 1, "status": "BLOCKED", "issued": false, "operation": r.operation,
                          "qualificationGranted": false, "physicalGestureClaimed": false]
    func blocked(_ reason: String) -> Object { result["reason"] = reason; return result }
    guard ["tile", "pair"].contains(r.operation), r.numbers.count == 2,
          r.numbers.allSatisfy({ $0 > 0 }), Set(r.numbers).count == 2, r.home > 0 else { return blocked("invalidRequest") }
    guard nativeContext(), NPReadOnlySpacesOpen() == 1, fixtureIsCurrent(r) else { return blocked("nativeContextOrFixtureIdentityUnavailable") }
    guard NSScreen.screens.count == 1, let screen = NSScreen.screens.first,
          let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
          let catalog = Catalog.read(), catalog.kinds[r.home] == 0 else { return blocked("singleDisplayOriginalHomeUnavailable") }
    let screenFrame = CGDisplayBounds(display), counters = inputCounters()
    let root = AXUIElementCreateApplication(r.fixturePID)
    _ = AXUIElementSetMessagingTimeout(root, 0.12)
    guard let source = window(r, index: 0, root: root) else { return blocked("originalSourceAXWindowUnavailable") }
    func beforeInput() -> Bool {
        nativeContext() && fixtureIsCurrent(r) && inputCounters() == counters && NSEvent.pressedMouseButtons == 0
    }
    if r.operation == "tile" {
        guard catalog.current == r.home, membership(r.numbers[0], r.home),
              sourceFocused(r, root: root, source: source), value(source, "AXFullScreen") as? Bool == false,
              let ax = splitFrame(source), let cg = liveFrame(r, index: 0),
              SplitPickerGeometry.near(ax, cg), screenFrame.contains(cg) else { return blocked("sourceIsNotFocusedOrdinaryWindow") }
        let (choices, _) = lifecycleLeftMenu(root)
        result["menuMatches"] = choices.count
        guard choices.count == 1, let choice = choices.first, supportedPress(choice.0) else { return blocked("uniqueSystemFullscreenLeftMenuUnavailable") }
        let (fresh, _) = lifecycleLeftMenu(root)
        var owner: pid_t = 0
        guard fresh.count == 1, let checked = fresh.first, CFEqual(choice.0, checked.0), choice.1 == checked.1,
              AXUIElementGetPid(checked.0, &owner) == .success, owner == r.fixturePID,
              beforeInput(), sourceFocused(r, root: root, source: source),
              Catalog.read()?.current == r.home, membership(r.numbers[0], r.home) else { return blocked("systemMenuChangedBeforeInput") }
        let error = AXUIElementPerformAction(checked.0, kAXPressAction as CFString)
        result["status"] = "ISSUED"; result["issued"] = true; result["axError"] = error.rawValue
        result["route"] = "systemFullscreenLeftMenuAXPress"
        return result
    }
    guard let target = window(r, index: 1, root: root),
          let sourceSpaces = NPReadWindowSpaces(r.numbers[0]) as? [UInt64], sourceSpaces.count == 1,
          let split = sourceSpaces.first, split != r.home, catalog.kinds[split] == 4,
          membership(r.numbers[0], split) else { return blocked("sourceNativeFullscreenSpaceUnavailable") }
    if membership(r.numbers[1], split) {
        result["status"] = "OBSERVED"; result["alreadyTogether"] = true
        result["reason"] = "bothFixtureMembersAlreadyInSameNativeFullscreenSpace"
        return result
    }
    guard [r.home, split].contains(catalog.current), membership(r.numbers[1], r.home) else { return blocked("targetOriginalHomeMembershipUnavailable") }
    let owners: [OverviewProcess]
    do { owners = try OverviewAgent.allCases.compactMap { try OverviewProcess.current($0) } }
    catch { return blocked("signedSystemPickerOwnerUnavailable") }
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    guard front == r.fixturePID || owners.contains(where: { $0.pid == front }) else { return blocked("pickerIsNotInForeground") }
    func readPicker(markerOnly: Bool = false) -> SplitPickerMatch {
        readSplitPicker(title: title(r, index: 1), session: r.nonce, screen: screenFrame,
                        fixture: r.fixturePID, numbers: r.numbers, source: source, target: target,
                        presentNativeHalf: Catalog.read()?.current == r.home,
                        owners: owners, markerOnly: markerOnly)
    }
    let match = readPicker()
    result["route"] = match.route; result["pickerEvidence"] = match.evidence
    result["labelMatches"] = match.labelled
    guard match.press != nil || match.click != nil else { return blocked(match.reason) }
    let verified = readPicker(markerOnly: match.byMarker)
    result["recheckEvidence"] = verified.evidence
    guard beforeInput(), NSWorkspace.shared.frontmostApplication?.processIdentifier == front,
          membership(r.numbers[0], split), membership(r.numbers[1], r.home),
          Catalog.read()?.kinds[split] == 4, verified.route == match.route,
          verified.authority == match.authority, verified.byMarker == match.byMarker,
          verified.authority.map({ (try? $0.verify()) != nil }) ?? true else { return blocked("pickerChangedBeforeInput") }
    if let first = match.press, let current = verified.press, CFEqual(first, current) {
        result["axError"] = AXUIElementPerformAction(current, kAXPressAction as CFString).rawValue
        result["input"] = "systemPickerAXPress"
    } else if let point = match.click, verified.press == nil, verified.click == point,
              CGPreflightPostEventAccess(),
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
        let pointer = CGEvent(source: nil)?.location
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        result["input"] = "syntheticClickOnVerifiedPicker"; result["mouseEvents"] = 2
        let after = inputCounters()
        if let pointer, CGEvent(source: nil)?.location == point,
           after.enumerated().allSatisfy({ $0.element == counters[$0.offset] || ($0.offset == 1 && $0.element == counters[1] &+ 1) }) {
            CGWarpMouseCursorPosition(pointer)
        }
    } else { return blocked("pickerInputUnavailableAfterRecheck") }
    result["status"] = "ISSUED"; result["issued"] = true
    return result
}

@main private struct SplitViewHelper {
    @MainActor static func main() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let request = try? JSONDecoder().decode(SplitRequest.self, from: data)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        // A true AppKit run loop makes NSWorkspace's foreground snapshot available;
        // this helper never shows a window or activates itself.
        DispatchQueue.main.async {
            let result: Object
            if let request { result = perform(request) }
            else { result = ["schema": 1, "status": "BLOCKED", "issued": false, "reason": "invalidJSONRequest"] }
            if let encoded = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(encoded); FileHandle.standardOutput.write(Data([10]))
            }
            exit(0)
        }
        app.run()
    }
}
