import AppKit
import Carbon
import ApplicationServices
import CNearpaneWindowEngine
import NearpaneCore
import NearpaneOrdinaryWindowRuntime
import Security

/// This single-use installed-Host diagnostic opens only Apple's overview in the current, verified console session.
/// No AX action, desktop selection, global key or pointer event is issued.
@MainActor enum StageCanaryOverview {
    private struct Refusal: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
    struct Dock {
        let image: OrdinaryProcessImage
        let app: AXUIElement
    }
    private struct Focus: Equatable {
        let image: OrdinaryProcessImage
        let window: AXUIElement
        let number: CGWindowID
    }
    private static let launcher = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
    private static func requirement(_ identifier: String) throws -> SecRequirement {
        var rule: SecRequirement?
        guard SecRequirementCreateWithString(("anchor apple and identifier \"" + identifier + "\"") as CFString,
                                              [], &rule) == errSecSuccess, let rule else { throw Refusal("appleRequirementUnavailable") }
        return rule
    }
    static func signedDock() throws -> Dock {
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
    static func root(_ dock: Dock) throws -> AXUIElement? {
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
        var evidence = [String:Any]()
        return try focus(&evidence)
    }

    private static func focus(_ evidence: inout [String:Any]) throws -> Focus {
        guard let current = NSWorkspace.shared.frontmostApplication, current.activationPolicy == .regular,
              !current.isHidden, !current.isTerminated else { throw Refusal("regularForegroundApplicationRequired") }
        let pid = current.processIdentifier
        guard pid > 1, pid != getpid() else { throw Refusal("externalFocusUnavailable") }
        let image = try OrdinaryProcessImage.read(pid)
        evidence["workspacePID"] = pid
        evidence["birth"] = image.launch
        let system = AXUIElementCreateSystemWide(), app = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(system,0.25) == .success,
              AXUIElementSetMessagingTimeout(app,0.25) == .success else { throw Refusal("focusTimeoutUnavailable") }
        var systemApp: CFTypeRef?, front: CFTypeRef?, focused: CFTypeRef?
        let systemError = AXUIElementCopyAttributeValue(system,kAXFocusedApplicationAttribute as CFString,&systemApp)
        let frontError = AXUIElementCopyAttributeValue(app,kAXFrontmostAttribute as CFString,&front)
        let windowError = AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&focused)
        evidence["systemFocusedApplicationError"] = systemError.rawValue
        evidence["axFrontmostError"] = frontError.rawValue
        evidence["axFrontmost"] = (front as? Bool) as Any? ?? NSNull()
        evidence["axFocusedWindowError"] = windowError.rawValue
        var owner = pid_t()
        if systemError == .success {
            guard let systemApp, CFGetTypeID(systemApp) == AXUIElementGetTypeID(),
                  AXUIElementGetPid(systemApp as! AXUIElement,&owner) == .success, owner == pid
            else { throw Refusal("systemAndWorkspaceFocusDisagree") }
            evidence["appSource"] = "systemFocusedApplication"
        } else {
            // A missing system-wide attribute can be corroborated on the exact frontmost application itself.
            guard [.noValue,.attributeUnsupported,.cannotComplete].contains(systemError),
                  frontError == .success, front as? Bool == true else { throw Refusal("externalAXFocusUnavailable") }
            evidence["appSource"] = "workspaceAndAXFrontmost"
        }
        guard windowError == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { throw Refusal("externalFocusedWindowUnavailable") }
        let window = focused as! AXUIElement
        guard AXUIElementGetPid(window,&owner) == .success, owner == pid,
              let number = NearpaneOrdinaryWindowRuntime.number(window),
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow,number) as? [[String:Any]],
              matchesForeground(rows,pid:pid,number:number) else { throw Refusal("visibleOrdinaryFocusedWindowUnconfirmed") }
        evidence["cgWindowID"] = number
        guard try OrdinaryProcessImage.read(pid) == image, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        else { throw Refusal("focusChangedDuringRead") }
        return Focus(image:image,window:window,number:number)
    }

    static func admission() -> [String:Any] {
        beginFocusObservation().first
    }

    /// Retain the original AX object across unrelated read-only samples; a recycled CG number is insufficient.
    static func beginFocusObservation() -> (first: [String:Any], finish: () -> [String:Any]) {
        var evidence: [String:Any] = ["uptime":ProcessInfo.processInfo.systemUptime]
        do {
            guard AXIsProcessTrusted() else { throw Refusal("observerAccessibilityUnavailable") }
            guard try root(signedDock()) == nil else { throw Refusal("overviewAlreadyPresented") }
            let original = try focus(&evidence)
            return (evidence, {
                var row: [String:Any] = ["uptime":ProcessInfo.processInfo.systemUptime]
                do {
                    let current = try focus(&row)
                    guard try root(signedDock()) == nil, current == original else { throw Refusal("originalWindowChanged") }
                    row["sameOriginalAX"] = true
                } catch { row["reason"] = (error as? Refusal)?.reason ?? "systemIdentityUnavailable" }
                return row
            })
        } catch { evidence["reason"] = (error as? Refusal)?.reason ?? "systemIdentityUnavailable" }
        return (evidence, { admissionFailure() })
    }
    private static func admissionFailure() -> [String:Any] {
        ["uptime":ProcessInfo.processInfo.systemUptime, "reason":"originalFocusUnavailable"]
    }
    static func matchesForeground(_ rows: [[String:Any]], pid: pid_t, number: CGWindowID) -> Bool {
        guard pid > 1, number != 0, rows.count == 1, let row = rows.first else { return false }
        return row[kCGWindowOwnerPID as String] as? pid_t == pid && row[kCGWindowNumber as String] as? CGWindowID == number
            && row[kCGWindowLayer as String] as? Int == 0 && row[kCGWindowIsOnscreen as String] as? Bool == true
            && (row[kCGWindowAlpha as String] as? Double ?? 0) > 0
    }
    static func hid() -> [UInt32] {
        [.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.mouseMoved,
         .leftMouseDragged,.rightMouseDragged,.otherMouseDragged,.keyDown,.keyUp,.flagsChanged,.scrollWheel].map {
            CGEventSource.counterForEventType(.hidSystemState,eventType:$0)
        }
    }
    static func inputAvailable() -> Bool {
        guard !IsSecureEventInputEnabled() else { return false }
        for index in UInt32(0)..<32 {
            guard let button = CGMouseButton(rawValue: index),
                  !CGEventSource.buttonState(.hidSystemState, button: button),
                  !CGEventSource.buttonState(.combinedSessionState, button: button) else { return false }
        }
        return !IsSecureEventInputEnabled()
    }
    static func inventory() throws -> [NSDictionary] {
        var connection: Int32 = 0, error: Int32 = 0
        guard let rows = np_host_scope_copy_managed(&connection,&error) as? [NSDictionary], error == 0,
              rows.count == 1, let display = rows[0]["Display Identifier"] as? String,
              let current = rows[0]["Current Space"] as? [String:Any],
              let id = StageEngineHostScope.Space(current).number,
              np_host_scope_direct(connection,display as CFString,&error) == id, error == 0 else { throw Refusal("nativeScopeUnavailable") }
        return rows
    }
    static func inventoryIdentity(_ rows: [NSDictionary]) throws -> NSDictionary {
        guard rows.count == 1, let first = rows.first, let token = first["Display Identifier"] as? String,
              let values = first["Spaces"] as? [[String:Any]], !values.isEmpty,
              let active = first["Current Space"] as? [String:Any] else { throw Refusal("managedRosterUnavailable") }
        func identity(_ row: [String:Any]) throws -> NSDictionary {
            let space = StageEngineHostScope.Space(row)
            guard !space.malformed, let id = space.number, let type = space.kind, let uuid = space.uuid
            else { throw Refusal("managedIdentityUnavailable") }
            return ["id":id,"type":type,"uuid":uuid.uuidString]
        }
        let roster = try values.map(identity), current = try identity(active)
        guard roster.filter({ $0 == current }).count == 1 else { throw Refusal("activeRosterMismatch") }
        return ["display":token,"current":current,"roster":roster]
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
    @discardableResult static func toggle() throws -> [String: Any] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(launcher as CFURL,[],&code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code,[],try requirement("com.apple.exposelauncher")) == errSecSuccess else { throw Refusal("unverifiedSystemLauncher") }
        // The system open command returns at delivery; the Dock AX tree proves presentation and dismissal.
        let p = Process()
        p.executableURL = URL(fileURLWithPath:"/usr/bin/open")
        p.arguments = ["-g","-a",launcher.path]
        let start = ProcessInfo.processInfo.systemUptime
        try p.run()
        let pid = p.processIdentifier
        let birth = (try? OrdinaryProcessImage.read(pid))?.launch
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Refusal("systemLauncherReturnedError") }
        return ["launcherPID": pid, "launcherBirth": birth as Any? ?? NSNull(), "startUptime": start,
                "endUptime": ProcessInfo.processInfo.systemUptime, "exit": p.terminationStatus]
    }

    static func read(after cycle: [String:Any], initial: [String:Any], final: [String:Any],
                     channel: StageScopeReply) async -> [String:Any] {
        guard cycle["status"] as? String == "PASS", cycle["safeToRollback"] as? Bool == true,
              Bundle.main.bundleURL.path == "/Applications/Nearpane.app" else {
            return ["status":"BLOCKED","reason":"cleanOwnCanaryAndInstalledAuthorizedHostRequired",
                    "presentations":0,"dismissals":0,"restored":true,"inputEventsPosted":0,"tileCounts":[],"stage":"afterCanary"]
        }
        return await measure(initial: initial, final: final, stage: "afterCanary",
                             cancelled: { try channel.exists(.abort) }, notify: { _ in })
    }

    /// A fullscreen observation can describe the public AX surface, but cannot qualify the ordinary-desktop gate.
    static func fullscreenReadOnlyIdentity(_ report: [String:Any]) -> NSDictionary? {
        guard (report["scope"] as? [String:Any])?["reason"] as? String == "fullscreenType4",
              let samples = report["samples"] as? [[String:Any]], samples.count == 2,
              (report["workspace"] as? NSDictionary)?["notificationsObserved"] as? Int == 0 else { return nil }
        var identity: NSDictionary?
        for sample in samples {
            guard let current = sample["current"] as? NSDictionary,
                  current["type"] as? Int == 4, current["malformed"] as? Bool == false,
                  let n = current["managedID"] as? UInt64, n > 0, n == current["id64"] as? UInt64,
                  (sample as NSDictionary)["directCurrent"] as? UInt64 == n, (sample as NSDictionary)["directCurrentAfter"] as? UInt64 == n,
                  let matches = sample["matchingRosterEntries"] as? [NSDictionary], matches == [current],
                  let space = current["uuid"] as? String, UUID(uuidString:space) != nil,
                  let display = sample["display"] as? NSDictionary, display["topologyConfirmed"] as? Bool == true,
                  display["activeCGCount"] as? Int == 1, let uuid = display["primaryUUID"] as? String,
                  let session = sample["session"] as? NSDictionary, session["qualified"] as? Bool == true
            else { return nil }
            let row: NSDictionary = ["nativeID":n,"spaceUUID":space,"displayUUID":uuid,"session":session]
            if let identity, identity != row { return nil }
            identity = row
        }
        return identity
    }

    /// The acceptance observer can sample the running Host while this routine uses only read APIs and the system overview launcher.
    static func measure(initial: [String:Any], final: [String:Any], stage: String,
                        trace: StageOverviewFocusTrace? = nil, cancelled: @escaping () throws -> Bool, notify: (String) async -> Void) async -> [String:Any] {
        var result: [String:Any] = ["status":"BLOCKED","presentations":0,"dismissals":0,"restored":true,
                                    "inputEventsPosted":0,"tileCounts":[],"stage":stage,"windowWrites":0,"spaceWrites":0]
        guard getuid() == geteuid(), getuid() > 0, AXIsProcessTrusted() else {
            result["reason"] = "authorizedConsoleObserverRequired"
            return result
        }
        let history = trace ?? StageOverviewFocusTrace()
        var finish: (() -> Void)?
        var restoreOwnedOverview: (() async -> Void)?
        do {
            let diagnostic = stage == "fullscreenPositionDiagnostic"
            let prior = diagnostic ? fullscreenReadOnlyIdentity(initial) : initial["scope"] as? NSDictionary
            let finalScope = diagnostic ? fullscreenReadOnlyIdentity(final) : final["scope"] as? NSDictionary
            guard let prior, let finalScope, prior == finalScope, diagnostic || prior["status"] as? String == "PASS"
            else { throw Refusal("activePhysicalScopeChangedOrUnavailable") }
            guard let expected = (final["samples"] as? [[String:Any]])?.last?["rosterCount"] as? Int,
                  expected > 0, expected <= 256, NSScreen.screens.count == 1,
                  let alias = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue(),
                  prior["displayUUID"] as? String == CFUUIDCreateString(nil,alias) as String
            else { throw Refusal("rosterOrPhysicalDisplayUnavailable") }
            let dock = try signedDock(), original = try focus(), start = hid(), rows = try inventory()
            let baseInventory = try inventoryIdentity(rows)
            result["nativeBefore"] = baseInventory
            guard let native = rows.first?["Spaces"] as? [NSDictionary], native.count == expected,
                  let active = rows.first?["Current Space"] as? [String: Any],
                  StageEngineHostScope.Space(active).kind == (diagnostic ? 4 : 0),
                  let currentID = StageEngineHostScope.Space(active).number, currentID == prior["nativeID"] as? UInt64
            else { throw Refusal("managedRosterChangedBeforeOverview") }
            result["originalFocus"] = ["pid":Int(original.image.pid), "birth":original.image.launch, "window":UInt64(original.number)] as [String:Any]
            func focusData(_ value: Focus) -> [String:Any] {
                ["uptime":ProcessInfo.processInfo.systemUptime, "pid":value.image.pid, "birth":value.image.launch,
                 "cgWindowID":value.number, "sameOriginalAX":CFEqual(value.window,original.window)]
            }
            func inputUnchanged() -> Bool {
                !Task.isCancelled && (try? cancelled()) == false && hid() == start && inputAvailable()
            }
            let bounds = CGDisplayBounds(CGMainDisplayID())
            result["managedIDsBefore"] = native.compactMap { $0["ManagedSpaceID"] as? UInt64 }
            result["expectedCount"] = expected
            result["scopeType"] = diagnostic ? 4 : 0
            result["currentSpaceID"] = currentID
            result["hidBefore"] = start
            finish = {
                if result["status"] as? String == "PASS" && inputUnchanged() {
                    var row: [String:Any] = ["uptime":ProcessInfo.processInfo.systemUptime]
                    do {
                        let closed = try root(dock) == nil
                        row["overviewClosed"] = closed
                        let current = try focus(&row)
                        row.merge(focusData(current)) { _, value in value }
                        guard closed, current == original else { throw Refusal("terminalOriginalFocusChanged") }
                    } catch {
                        result["status"] = "UNKNOWN"
                        result["reason"] = (error as? Refusal)?.reason ?? "terminalFocusReadUnavailable"
                    }
                    result["terminalFocus"] = row
                }
                if let end = try? inventory(), let desktops = end.first?["Spaces"] as? [NSDictionary] {
                    result["managedIDsAfter"] = desktops.compactMap { $0["ManagedSpaceID"] as? UInt64 }
                    result["rawManagedDictionaryEqual"] = end == rows
                    if let last = try? inventoryIdentity(end) {
                        result["nativeAfter"] = last
                        result["nativeInventoryRestored"] = last == baseInventory
                    }
                }
                result["hidAfter"] = hid()
                result["inputUninterrupted"] = inputUnchanged()
                result["terminalReadbackUptime"] = ProcessInfo.processInfo.systemUptime
            }
            func stable() throws {
                guard let session = CGSessionCopyCurrentDictionary() as? [String:Any],
                      session[kCGSessionOnConsoleKey as String] as? Bool == true,
                      session[kCGSessionUserIDKey as String] as? uid_t == getuid(),
                      session["CGSSessionScreenIsLocked"] as? Bool != true,
                      NSScreen.screens.count == 1, CGDisplayBounds(CGMainDisplayID()) == bounds
                else { throw Refusal("consoleOrDisplayChanged") }
                guard inputUnchanged() else { throw Refusal("hidOrHostInterrupted") }
                let current = try inventoryIdentity(inventory())
                if current != baseInventory { result["changedNativeIdentity"] = current; throw Refusal("managedRosterOrActiveSpaceChanged") }
            }
            var before = [[String:Any]]()
            for _ in 0..<2 {
                try stable()
                let current = try focus()
                before.append(focusData(current))
                result["focusBefore"] = before
                guard try root(dock) == nil, current == original else { throw Refusal("ordinaryFocusedDesktopUnconfirmed") }
                try await Task.sleep(for:.milliseconds(55))
            }
            trace?.sample("before", originalPID: original.image.pid, window: original.window)
            await notify("before")
            try stable()
            guard try root(dock) == nil, try focus() == original else { throw Refusal("overviewAlreadyOpen") }
            result["presentations"] = 1
            result["restored"] = false
            result["presentationRequest"] = try toggle()
            let until = ContinuousClock.now + .seconds(3)
            var enrolled: AXUIElement?
            repeat {
                try stable()
                enrolled = try? root(dock)
                if enrolled == nil { try await Task.sleep(for:.milliseconds(80)) }
            } while enrolled == nil && ContinuousClock.now < until
            guard let enrolled else { throw Refusal("newSystemOverviewUnconfirmed") }
            restoreOwnedOverview = {
                guard result["dismissals"] as? Int == 0, inputUnchanged(),
                      let login = CGSessionCopyCurrentDictionary() as? [String:Any],
                      login[kCGSessionOnConsoleKey as String] as? Bool == true,
                      login[kCGSessionUserIDKey as String] as? uid_t == getuid(), login["CGSSessionScreenIsLocked"] as? Bool != true,
                      let now = try? inventoryIdentity(inventory()), now["roster"] as? NSArray == baseInventory["roster"] as? NSArray,
                      now["display"] as? String == baseInventory["display"] as? String,
                      NSScreen.screens.count == 1, CGDisplayBounds(CGMainDisplayID()) == bounds,
                      let rootNow = try? root(dock), CFEqual(rootNow,enrolled), inputUnchanged()
                else { return }
                result["dismissals"] = 1
                do {
                    result["cleanupDismissalRequest"] = try toggle()
                    result["cleanupDismissalIssued"] = true
                    for _ in 0..<12 {
                        try await Task.sleep(for:.milliseconds(100))
                        guard inputUnchanged() else { break }
                        var row = [String:Any]()
                        let closed = try root(dock) == nil
                        let observed = try? focus(&row)
                        row["overviewClosed"] = closed
                        row["sameOriginalAX"] = observed.map{ CFEqual($0.window,original.window) } ?? false
                        var reads = result["cleanupReads"] as? [[String:Any]] ?? []
                        reads.append(row)
                        result["cleanupReads"] = reads
                        if closed && reads.count >= 2 && reads.suffix(2).allSatisfy({ $0["overviewClosed"] as? Bool == true && $0["sameOriginalAX"] as? Bool == true }) {
                            result["restored"] = true; break
                        }
                    }
                } catch { result["cleanupReason"] = "dismissalReadbackUnavailable" }
            }
            trace?.mark("signedDockFirstPresented")
            await notify("presented")
            try stable()
            trace?.sample("presented", originalPID: original.image.pid, window: original.window)
            var samples = [StageOverviewHitTest.Sample]()
            var treeAgrees = true
            for _ in 0..<2 {
                try await Task.sleep(for:.milliseconds(140))
                try stable()
                guard try root(dock) == enrolled else { throw Refusal("overviewReplaced") }
                let sample = StageOverviewHitTest.sample(dock:dock.app, dockPID:dock.image.pid, bounds:bounds,
                                                        inputUnchanged:inputUnchanged)
                samples.append(sample)
                result["hitTestSamples"] = samples.map(\.evidence)
                try stable()
                if let tree = try? tiles(enrolled,dock,bounds:bounds), tree != sample.tiles.map(\.element) {
                    treeAgrees = false
                }
            }
            let counts = samples.map { $0.tiles.count }
            result["observedTileHits"] = counts
            let layouts = samples.map { $0.tiles.map(\.frame) }
            let measured = treeAgrees && samples.allSatisfy(\.complete) && samples[0].tiles == samples[1].tiles &&
                !samples[0].visibleRow.isEmpty && samples[0].visibleRow == samples[1].visibleRow &&
                layouts.allSatisfy { StageOverviewHitTest.validLayout($0,in:bounds) }
            result["stableHitLayout"] = measured
            if measured { result["tileCounts"] = counts }
            try stable()
            guard try root(dock) == enrolled else { throw Refusal("overviewOwnershipLostBeforeDismissal") }
            result["dismissals"] = 1
            result["dismissalRequest"] = try toggle()
            var cleanReads = 0, reportedClosed = false, after = [[String:Any]]()
            result["originalFocusConfirmedReads"] = 0
            let end = ContinuousClock.now + .seconds(5)
            repeat {
                try await Task.sleep(for:.milliseconds(90))
                try stable()
                var row: [String:Any] = ["uptime":ProcessInfo.processInfo.systemUptime]
                do {
                    let closed = try root(dock) == nil
                    result["overviewClosed"] = closed
                    row["overviewClosed"] = closed
                    if closed && !reportedClosed {
                        reportedClosed = true
                        trace?.mark("signedDockFirstDismissed")
                        trace?.sample("dismissed", originalPID: original.image.pid, window: original.window)
                        await notify("dismissed")
                        try stable()
                    }
                    let current = try focus(&row)
                    row.merge(focusData(current)) { _, value in value }
                    cleanReads = closed && current == original ? cleanReads + 1 : 0
                } catch {
                    cleanReads = 0
                    row["reason"] = (error as? Refusal)?.reason ?? "focusReadUnavailable"
                }
                after.append(row)
                result["focusAfter"] = after
                result["originalFocusConfirmedReads"] = cleanReads
                try stable()
            } while cleanReads < 2 && ContinuousClock.now < end
            trace?.sample("terminal", originalPID: original.image.pid, window: original.window)
            guard cleanReads == 2 else {
                let verifiedAway = after.suffix(2)
                if verifiedAway.count == 2 && verifiedAway.allSatisfy({ row in
                    if let pid = row["workspacePID"] as? pid_t, let birth = row["birth"] as? UInt64 {
                        return row["overviewClosed"] as? Bool == true && row["axFrontmost"] as? Bool == true &&
                            birth > 0 && pid != original.image.pid
                    }
                    return false
                }) { result["foregroundContinuity"] = "FAIL" }
                throw Refusal("originalFocusOrOverviewDismissalUnconfirmed")
            }
            result["restored"] = true
            result["originalFocusConfirmedReads"] = cleanReads
            try stable()
            if !measured || counts != [expected,expected] {
                result["status"] = "BLOCKED"
                result["reason"] = "completeVisibleTileLayoutUnconfirmed"
            } else {
                result["status"] = "PASS"
                result["reason"] = "twoHitTestLayoutsAndExactOriginalFocus"
            }

        } catch {
            result["status"] = (result["presentations"] as? Int == 0) ? "BLOCKED" : "UNKNOWN"
            result["reason"] = (error as? Refusal)?.reason ?? "systemOrFocusReadUnavailable"
        }
        await restoreOwnedOverview?()
        // The last Host reply is part of this observation. Keep the original input baseline
        // and ownership checks live while the metrics request is in flight.
        await notify("terminal")
        finish?()
        result["workspaceDidActivate"] = history.activations
        if result["status"] as? String == "PASS" &&
            (result["inputUninterrupted"] as? Bool != true || result["nativeInventoryRestored"] as? Bool != true) {
            result["status"] = "UNKNOWN"
            result["reason"] = "inputOrInventoryChangedBeforeReceipt"
        }
        if result["status"] as? String == "PASS" && result["terminalFocus"] == nil {
            result["status"] = "UNKNOWN"
            result["reason"] = "terminalFocusReadUnavailable"
        }
        return result
    }
}
