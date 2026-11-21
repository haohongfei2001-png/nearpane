import AppKit
import ApplicationServices
import CNearpaneWindowEngine
import NearpaneCore
import Security

/// This single-use installed-Host diagnostic opens only Apple's overview on a disposable console.
/// No AX action, desktop selection, global key or pointer event is issued.
@MainActor enum StageCanaryOverview {
    private struct Refusal: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
    private struct Dock {
        let image: OrdinaryProcessImage
        let app: AXUIElement
    }
    private struct Focus: Equatable {
        let image: OrdinaryProcessImage
        let window: AXUIElement?
    }
    private static let launcher = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
    private static func requirement(_ identifier: String) throws -> SecRequirement {
        var rule: SecRequirement?
        guard SecRequirementCreateWithString(("anchor apple and identifier \"" + identifier + "\"") as CFString,
                                              [], &rule) == errSecSuccess, let rule else { throw Refusal("appleRequirementUnavailable") }
        return rule
    }
    private static func signedDock() throws -> Dock {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        guard apps.count == 1, let pid = apps.first?.processIdentifier else { throw Refusal("ambiguousSystemDock") }
        let image = try OrdinaryProcessImage.read(pid)
        var code: SecCode?
        guard image.executable.path == "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String:pid] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, [], try requirement("com.apple.dock")) == errSecSuccess else { throw Refusal("unverifiedDock") }
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(app, 0.18) == .success else { throw Refusal("dockAXUnavailable") }
        return Dock(image: image, app: app)
    }
    private static func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    private static func children(_ element: AXUIElement, _ dock: Dock) throws -> [AXUIElement] {
        var count = 0, array: CFArray?
        let key = kAXChildrenAttribute as CFString
        guard AXUIElementGetAttributeValueCount(element, key, &count) == .success, (1...256).contains(count),
              AXUIElementCopyAttributeValues(element, key, 0, count, &array) == .success,
              let result = array as? [AXUIElement], result.count == count, Set(result).count == count,
              result.allSatisfy({ child in
                  var pid = pid_t()
                  return AXUIElementGetPid(child, &pid) == .success && pid == dock.image.pid
              }) else { throw Refusal("systemAXTreeUnavailable") }
        return result
    }
    private static func root(_ dock: Dock) throws -> AXUIElement? {
        guard try OrdinaryProcessImage.read(dock.image.pid) == dock.image else { throw Refusal("dockGenerationChanged") }
        let items = try children(dock.app, dock)
        var roots = [AXUIElement]()
        for item in items {
            var id: CFTypeRef?
            let rc = AXUIElementCopyAttributeValue(item, kAXIdentifierAttribute as CFString, &id)
            if rc == .success {
                guard let text = id as? String else { throw Refusal("invalidSystemIdentifier") }
                if text == "mc" { roots.append(item) }
            } else if rc != .attributeUnsupported && rc != .noValue { throw Refusal("systemIdentifierUnavailable") }
        }
        if roots.count == 1 { return roots[0] }
        guard roots.isEmpty, items.contains(where: { attr($0,kAXRoleAttribute) as? String == kAXListRole })
        else { throw Refusal("ambiguousOverviewState") }
        return nil
    }
    private static func focus() throws -> Focus {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid > 1, pid != getpid() else { throw Refusal("externalFocusUnavailable") }
        let image = try OrdinaryProcessImage.read(pid)
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementSetMessagingTimeout(system, 0.18) == .success,
              let focused = attr(system,kAXFocusedApplicationAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { throw Refusal("externalAXFocusUnavailable") }
        let app = focused as! AXUIElement
        var owner = pid_t()
        guard AXUIElementGetPid(app,&owner) == .success, owner == pid, AXUIElementSetMessagingTimeout(app,0.18) == .success else { throw Refusal("externalFocusedWindowUnavailable") }
        var value: CFTypeRef?
        let rc = AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&value)
        var window: AXUIElement?
        if rc == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            let found = value as! AXUIElement
            guard AXUIElementGetPid(found,&owner) == .success, owner == pid else { throw Refusal("focusedWindowOwnerChanged") }
            window = found
        } else if rc != .noValue || value != nil { throw Refusal("externalFocusedWindowUnavailable") }
        guard try OrdinaryProcessImage.read(pid) == image,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw Refusal("focusChangedDuringRead") }
        return Focus(image:image, window:window)
    }
    private static func fixtureDesktop() -> Bool {
        // The signed runner explicitly requested this test. Inspect numeric owner fields only.
        // A regular window of any other application keeps the system overview closed.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] else { return false }
        var validated = Set<pid_t>()
        for w in windows {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, let level = w[kCGWindowLayer as String] as? Int,
                  let alpha = w[kCGWindowAlpha as String] as? Double else { return false }
            if level != 0 || alpha == 0 || pid == getpid() || validated.contains(pid) { continue }
            guard let app = NSRunningApplication(processIdentifier:pid), let id = app.bundleIdentifier,
                  ["com.holdsnow.nearpane.engine-fixture.a","com.holdsnow.nearpane.engine-fixture.b"].contains(id) else { return false }
            var code: SecCode?, rule: SecRequirement?
            let text = "anchor apple generic and identifier \"" + id + "\" and certificate leaf[subject.OU] = \"ZB9D4T66QB\""
            guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributePid as String:pid] as CFDictionary,[],&code) == errSecSuccess, let code,
                  SecRequirementCreateWithString(text as CFString,[],&rule) == errSecSuccess, let rule,
                  SecCodeCheckValidity(code,[],rule) == errSecSuccess else { return false }
            validated.insert(pid)
        }
        return true
    }
    private static func hid() -> [UInt32] {
        [.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.mouseMoved,
         .leftMouseDragged,.rightMouseDragged,.otherMouseDragged,.keyDown,.keyUp,.flagsChanged,.scrollWheel].map {
            CGEventSource.counterForEventType(.hidSystemState,eventType:$0)
        }
    }
    private static func inventory() throws -> [NSDictionary] {
        var connection: Int32 = 0, error: Int32 = 0
        guard let rows = np_host_scope_copy_managed(&connection,&error) as? [NSDictionary], error == 0,
              rows.count == 1, let display = rows[0]["Display Identifier"] as? String,
              let current = rows[0]["Current Space"] as? [String:Any],
              let id = StageEngineHostScope.Space(current).number,
              np_host_scope_direct(connection,display as CFString,&error) == id, error == 0 else { throw Refusal("nativeScopeUnavailable") }
        return rows
    }
    private static func frame(_ element: AXUIElement) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let a = attr(element,kAXPositionAttribute), CFGetTypeID(a) == AXValueGetTypeID(),
              let b = attr(element,kAXSizeAttribute), CFGetTypeID(b) == AXValueGetTypeID(),
              AXValueGetValue(a as! AXValue,.cgPoint,&p), AXValueGetValue(b as! AXValue,.cgSize,&s), s.width > 0, s.height > 0 else { return nil }
        return CGRect(origin:p,size:s)
    }
    private static func tiles(_ root: AXUIElement, _ dock: Dock, bounds: CGRect) throws -> [AXUIElement] {
        var node = root
        for id in ["mc.display","mc.spaces","mc.spaces.list"] {
            let found = try children(node,dock).filter { attr($0,kAXIdentifierAttribute) as? String == id }
            guard found.count == 1, let only = found.first else { throw Refusal("uniqueSpacesStripUnavailable") }
            if id == "mc.display", frame(only) != bounds { throw Refusal("stripOnDifferentDisplay") }
            node = only
        }
        guard let strip = frame(node), bounds.contains(strip) else { throw Refusal("stripFrameUnavailable") }
        let items = try children(node,dock)
        let rects = items.compactMap(frame)
        guard items.allSatisfy({ attr($0,kAXRoleAttribute) as? String == kAXButtonRole }),
              rects.count == items.count, rects.allSatisfy({ strip.contains($0) }),
              zip(rects,rects.dropFirst()).allSatisfy({ $0.midX < $1.midX }) else { throw Refusal("visibleTileOrderUnavailable") }
        return items
    }
    private static func toggle() throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(launcher as CFURL,[],&code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code,[],try requirement("com.apple.exposelauncher")) == errSecSuccess else { throw Refusal("unverifiedSystemLauncher") }
        // The system open command returns at delivery; the Dock AX tree proves presentation and dismissal.
        let p = Process()
        p.executableURL = URL(fileURLWithPath:"/usr/bin/open")
        p.arguments = ["-g","-a",launcher.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Refusal("systemLauncherReturnedError") }
    }

    static func read(after cycle: [String:Any], initial: [String:Any], final: [String:Any],
                     channel: StageScopeReply) async -> [String:Any] {
        var result: [String:Any] = ["status":"BLOCKED","presentations":0,"dismissals":0,"restored":true,
                                    "inputEventsPosted":0,"tileCounts":[],"stage":"afterCanary"]
        guard cycle["status"] as? String == "PASS", cycle["safeToRollback"] as? Bool == true,
              getuid() == geteuid(), getuid() > 0, fixtureDesktop(),
              AXIsProcessTrusted(), Bundle.main.bundleURL.path == "/Applications/Nearpane.app"
        else { result["reason"] = "cleanOwnCanaryAndDisposablePhysicalLoginRequired"; return result }
        do {
            guard let prior = initial["scope"] as? NSDictionary, let after = final["scope"] as? NSDictionary,
                  prior.isEqual(after), prior["status"] as? String == "PASS",
                  let expected = (final["samples"] as? [[String:Any]])?.last?["rosterCount"] as? Int,
                  expected > 0, expected <= 256, NSScreen.screens.count == 1,
                  let alias = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue(),
                  prior["displayUUID"] as? String == CFUUIDCreateString(nil,alias) as String else { throw Refusal("physicalScopeChangedAfterCanary") }
            let dock = try signedDock(), original = try focus(), start = hid(), rows = try inventory()
            guard let native = rows.first?["Spaces"] as? [NSDictionary], native.count == expected else { throw Refusal("managedRosterChangedBeforeOverview") }
            let bounds = CGDisplayBounds(CGMainDisplayID())
            func stable() throws {
                guard !Task.isCancelled, try !channel.exists(.abort), hid() == start, NSEvent.pressedMouseButtons == 0,
                      try inventory() == rows, NSScreen.screens.count == 1, CGDisplayBounds(CGMainDisplayID()) == bounds
                else { throw Refusal("inputDesktopOrTopologyChanged") }
            }
            for _ in 0..<2 {
                try stable()
                guard fixtureDesktop(), try root(dock) == nil, try focus() == original else { throw Refusal("ordinaryFocusedDesktopUnconfirmed") }
                try await Task.sleep(for:.milliseconds(55))
            }
            try stable()
            guard fixtureDesktop(), try root(dock) == nil, try focus() == original else { throw Refusal("overviewAlreadyOpen") }
            result["presentations"] = 1
            result["restored"] = false
            try toggle()
            let until = ContinuousClock.now + .seconds(3)
            var enrolled: AXUIElement?
            repeat {
                try stable()
                enrolled = try? root(dock)
                if enrolled == nil { try await Task.sleep(for:.milliseconds(80)) }
            } while enrolled == nil && ContinuousClock.now < until
            guard let enrolled else { throw Refusal("newSystemOverviewUnconfirmed") }
            var samples = [[AXUIElement]](), sampleError: String?
            do {
                for _ in 0..<2 {
                    try await Task.sleep(for:.milliseconds(160))
                    try stable()
                    guard try root(dock) == enrolled else { throw Refusal("overviewReplaced") }
                    samples.append(try tiles(enrolled,dock,bounds:bounds))
                }
            } catch { sampleError = (error as? Refusal)?.reason ?? "stripReadUnavailable" }
            result["tileCounts"] = samples.map(\.count)
            result["expectedCount"] = expected
            try stable()
            guard try root(dock) == enrolled else { throw Refusal("overviewOwnershipLostBeforeDismissal") }
            result["dismissals"] = 1
            try toggle()
            var cleanReads = 0
            let end = ContinuousClock.now + .seconds(3)
            repeat {
                try await Task.sleep(for:.milliseconds(90))
                try stable()
                do { cleanReads = try root(dock) == nil && focus() == original ? cleanReads + 1 : 0 }
                catch { cleanReads = 0 }
            } while cleanReads < 2 && ContinuousClock.now < end
            guard cleanReads == 2 else { throw Refusal("originalFocusOrOverviewDismissalUnconfirmed") }
            result["restored"] = true
            guard sampleError == nil, samples.count == 2, samples[0] == samples[1] else { throw Refusal(sampleError ?? "systemTilesChangedBetweenReads") }
            result["status"] = samples[0].count == expected ? "PASS" : "FAIL"
            result["reason"] = samples[0].count == expected ? "visibleDesktopStripAndOriginalFocusConfirmed" : "visibleSystemTileCountDiffers"
        } catch {
            result["status"] = (result["presentations"] as? Int == 0) ? "BLOCKED" : "UNKNOWN"
            result["reason"] = (error as? Refusal)?.reason ?? "systemOrFocusReadUnavailable"
        }
        return result
    }
}
