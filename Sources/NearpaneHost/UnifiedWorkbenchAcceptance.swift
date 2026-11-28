#if DEBUG && canImport(SaytileKit) && canImport(RiftletCore)
import AppKit
import CryptoKit
import Foundation
import NearpaneCore
import NearpaneUI

/// Runs the shipping SwiftUI/AppKit views inside the existing executable-bound,
/// disposable native acceptance profile. Playback fixtures are identified as such;
/// neither an engine model nor a rendered image qualifies real player/Spaces I/O.
@MainActor
enum UnifiedWorkbenchAcceptance {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func run(session: NativeAcceptanceSession, host: HostSession,
                    modules: EmbeddedModules, navigation: SettingsNavigation,
                    window: NSWindow, menu: NSMenu? = nil, openMainWindow: () -> NSWindow?) async throws {
        let output = session.directory.appendingPathComponent("workbench", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        var checks: [[String: Any]] = []
        var pictures: [[String: Any]] = []
        let originalPreferences = host.registry.preferences
        let originalCounts = try CandidateProfile.inspectStores(in: session.support, counts: true)
        let originalNumber = window.windowNumber
        var sidebar: EdgeWindowController?

        func check(_ name: String, _ success: Bool, detail: String, required: Bool = false) throws {
            checks.append(["check": name, "passed": success, "detail": detail])
            guard success || !required else { throw Failure(name + ": " + detail) }
        }
        func writeReceipt(_ status: String, error: String? = nil) {
            var receipt: [String: Any] = [
                "schema": 2, "status": status,
                "sourceCommit": Bundle.main.object(forInfoDictionaryKey: "NearpaneUnifiedWorkbenchCommit") as? String ?? "unknown",
                "platform": ProcessInfo.processInfo.operatingSystemVersionString,
                "applicationEventLoopRunning": NSApp.isRunning,
                "applicationActive": NSApp.isActive,
                "activationPolicy": NSApp.activationPolicy().rawValue,
                "assistiveAccessibilityEnvironmentEnabled": NativeVerificationAccessibility.isEnabled,
                "accessibilityScope": "Public SwiftUI accessibilityEnabled environment on DEBUG CI alpha fixture views; normal product defaults, system permissions and player lease unchanged",
                "accessibilityDispatch": "Public native AX press via NSAccessibilityProtocol or an exact BOOL selector bridge; semantic identifier, role, native enabled state, dispatch return and product-state result are required",
                "evidenceScope": "Packaged Nearpane native UI; isolated generated content; in-process accessibility actions",
                "playbackScope": "Synthetic snapshots only; does not certify a real music player's controls or metadata",
                "spacesScope": "No real window dispatch was performed; PR 16 remains separately qualified",
                "nativeMenuDispatchAttempted": menu != nil,
                "interactionPolicy": "Failed native input stays FAIL; labelled programmatic routing may continue independent visual inspection",
                "checks": checks, "screenshots": pictures
            ]
            if let error { receipt["error"] = error }
            if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("native-workbench-receipt.json"), options: .atomic)
            }
        }
        func singleMainWindow() -> Bool {
            let windows = NSApp.windows.filter { $0.identifier?.rawValue == "nearpane-main-window" }
            // Desktop edge panels are borderless. A titled NSPanel is still a
            // management window and must not escape the single-window invariant.
            let management = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }
            return windows.count == 1 && windows.first === window && management.count == 1 && management.first === window
        }
        func enabled(_ id: String) -> Bool { host.registry.preferences.contains { $0.id == id && $0.enabled } }
        func enableOnly(_ ids: Set<String>) async {
            for preference in host.registry.preferences where preference.enabled != ids.contains(preference.id) {
                host.handle(.setEnabled(preference.id, ids.contains(preference.id)))
            }
            await modules.voice.waitForTransition()
            await Task.yield()
        }
        func picture(_ name: String, appearance: NSAppearance.Name = .aqua,
                     size: NSSize = NSSize(width: 920, height: 660)) async throws {
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(size)
            window.center()
            pictures.append(try await capture(window, name: name, to: output))
        }
        func input(_ identifier: String, name: String, expected: () -> Bool,
                   fallback: () -> Void) async throws {
            let dispatched = try await press(identifier, in: window, diagnostics: output)
            let succeeded = dispatched && expected()
            checks.append(["check": name, "passed": succeeded, "evidenceKind": "native-accessibility",
                           "actionDispatched": dispatched, "identifier": identifier,
                           "diagnostic": "ax-" + identifier + ".json",
                           "detail": "Actual native accessibility press and resulting product state; a fallback cannot pass this check."])
            if !succeeded {
                fallback()
                try await Task.sleep(for: .milliseconds(180))
                checks.append(["check": name + "-visual-route-fallback", "passed": expected(),
                               "evidenceKind": "programmatic-route",
                               "detail": "Programmatic routing only, used to continue independent native screenshots after a failed input check."])
            }
        }

        do {
            try check("native-window-visible", window.isVisible && window.contentView != nil,
                      detail: "The actual retained Nearpane management NSWindow is ordered on the cloud desktop.", required: true)
            try check("single-main-window-initial", singleMainWindow(), detail: "Exactly one standard management window.", required: true)

            navigation.showModules()
            // Preserve the actual UI before probing any accessibility bridge.
            try await picture("01-modules-light")
            try await input("main-nav-modules", name: "modules-navigation",
                            expected: { navigation.selectedPageIdentifier == "modules" }, fallback: navigation.showModules)
            try await picture("02-modules-dark", appearance: .darkAqua)
            try await picture("03-modules-compact", size: NSSize(width: 740, height: 520))

            try await input("module-open-" + BuiltinCatalog.screenshots, name: "module-detail-route",
                            expected: { navigation.selectedPageIdentifier == "tray" },
                            fallback: { navigation.showModule(BuiltinCatalog.screenshots) })
            try await picture("04-screenshot-module")
            try await input("main-back-to-modules", name: "module-detail-return",
                            expected: { navigation.selectedPageIdentifier == "modules" }, fallback: navigation.showModules)

            try await input("main-nav-library", name: "library-navigation",
                            expected: { navigation.selectedSectionIdentifier == "library" }, fallback: navigation.showLibrary)
            navigation.showVoiceArchive()
            try await picture("05-voice-library")
            navigation.showScreenshotArchive()
            try await picture("06-screenshot-library")
            try await picture("07-screenshot-library-dark", appearance: .darkAqua)

            try await input("main-nav-settings", name: "settings-navigation",
                            expected: { navigation.selectedSectionIdentifier == "settings" }, fallback: navigation.showGeneral)
            navigation.showGeneral()
            try await picture("08-settings-general")
            navigation.showAppearance()
            try await picture("09-settings-appearance")
            try await picture("10-settings-compact-dark", appearance: .darkAqua, size: NSSize(width: 740, height: 520))
            navigation.showDisplays()
            try await picture("10-display-placement-settings")
            navigation.showModule(BuiltinCatalog.voice)
            try await picture("10-voice-module-settings")
            navigation.showModule(BuiltinCatalog.desktop)
            try await picture("10-spaces-module-settings")
            navigation.showApplicationServices()
            try await picture("10-about-and-updates")
            try check("about-update-single-window", singleMainWindow(),
                      detail: "About and the embedded updater share the retained Nearpane management window; no network update was requested.")

            for route in [navigation.showModules, navigation.showVoiceArchive,
                          navigation.showScreenshotArchive, navigation.showAppearance,
                          navigation.showWindowManagement, navigation.showGeneral] {
                route()
                let opened = openMainWindow()
                try check("repeated-open-" + navigation.selectedPageIdentifier,
                          opened === window && window.windowNumber == originalNumber && singleMainWindow(),
                          detail: "The production main-window opener reused its NSWindow and window number.")
            }
            if let menu {
                for (selector, expected) in [("showModules", "modules"), ("showLibrary", "screenshotArchive"),
                                             ("showGeneralSettings", "general"), ("showWindowManagement", "windowManagement"),
                                             ("checkForUpdates", "app")] {
                    guard let item = menu.items.first(where: { $0.action.map(NSStringFromSelector) == selector }),
                          let action = item.action else { throw Failure("Native menu route missing: " + selector) }
                    let sent = NSApp.sendAction(action, to: item.target, from: item)
                    try await Task.sleep(for: .milliseconds(160))
                    try check("native-menu-" + selector, sent && navigation.selectedPageIdentifier == expected && singleMainWindow(),
                              detail: "The actual menu item's target/action selected its route in the existing management window.")
                }
            }
            guard let moduleRoute = modules.openManagementPage else { throw Failure("Module management navigation was not connected.") }
            for (moduleID, page, expected) in [
                (BuiltinCatalog.voice, "library", "voiceArchive"),
                (BuiltinCatalog.screenshots, "library", "screenshotArchive"),
                (BuiltinCatalog.lyrics, "fullLyrics", "lyrics"),
                (BuiltinCatalog.lyrics, "source", "lyrics"),
                (BuiltinCatalog.desktop, "permissions", "permissions")
            ] {
                moduleRoute(moduleID, page)
                try await Task.sleep(for: .milliseconds(160))
                try check("module-entry-" + moduleID + "-" + page,
                          navigation.selectedPageIdentifier == expected && singleMainWindow() && window.windowNumber == originalNumber,
                          detail: "The production module-to-Host callback reused the same main window.")
                if page == "permissions" {
                    try await picture("10-permissions-explanation")
                    try check("permissions-explanation-single-window", singleMainWindow() && window.windowNumber == originalNumber,
                              detail: "The window-access explanation is an internal page of the retained main window; no system authorization button was invoked.")
                }
            }

            navigation.showModules()
            window.setContentSize(NSSize(width: 920, height: 660))
            let memoBefore = enabled(BuiltinCatalog.memo)
            try await input("module-enabled-" + BuiltinCatalog.memo, name: "module-toggle-native-action",
                            expected: { enabled(BuiltinCatalog.memo) != memoBefore },
                            fallback: { host.handle(.setEnabled(BuiltinCatalog.memo, !memoBefore)) })
            host.handle(.setEnabled(BuiltinCatalog.memo, memoBefore))

            let moved = host.moveModule(BuiltinCatalog.screenshots, before: BuiltinCatalog.voice)
            let reordered = host.registry.preferences.map(\.id)
            try check("module-reorder-command", moved && reordered.firstIndex(of: BuiltinCatalog.screenshots)! < reordered.firstIndex(of: BuiltinCatalog.voice)!,
                      detail: "The same move command used by drop handling changed the stored order; this is not a physical drag test.")
            let saved = try FileConfigurationStore(url: session.support.appendingPathComponent("Nearpane/host-configuration.json")).load()
            try check("module-order-persisted", saved.modules == host.registry.preferences,
                      detail: "A fresh configuration read matches the enabled flags and exact order.")

            if let screen = SystemScreens.geometry().first {
                let edge = EdgeWindowController(host: host, modules: modules)
                sidebar = edge
                for (name, combination) in [
                    ("11-sidebar-voice-screenshots", Set([BuiltinCatalog.voice, BuiltinCatalog.screenshots])),
                    ("12-sidebar-screenshots-notes", Set([BuiltinCatalog.screenshots, BuiltinCatalog.memo, BuiltinCatalog.tasks])),
                    ("13-sidebar-screenshots", Set([BuiltinCatalog.screenshots]))
                ] {
                    await enableOnly(combination)
                    edge.place(on: screen, primary: screen.id, content: .toolsOnly)
                    edge.presentIfNeeded()
                    guard let panel = edge.window else { throw Failure("The real sidebar panel was not constructed.") }
                    panel.appearance = NSAppearance(named: .aqua)
                    pictures.append(try await capture(panel, name: name, to: output))
                    try check(name + "-unique", NSApp.windows.filter { $0 === panel }.count == 1 && panel.isVisible,
                              detail: "One actual EdgeWindowController panel renders the selected module combination.")
                }
                if let panel = edge.window {
                    panel.appearance = NSAppearance(named: .darkAqua)
                    pictures.append(try await capture(panel, name: "13-sidebar-screenshots-dark", to: output))
                }
                await enableOnly(Set(host.registry.manifests.map(\.id)))
                _ = modules.installLyricsVerificationState("playing")
                let spacesMoved = host.moveModule(BuiltinCatalog.desktop, before: BuiltinCatalog.screenshots)
                let clockMoved = host.moveModule(BuiltinCatalog.clock, before: BuiltinCatalog.voice)
                let allModuleOrder = host.registry.preferences.map(\.id)
                try check("spaces-clock-reorder-command", spacesMoved && clockMoved &&
                          allModuleOrder.firstIndex(of: BuiltinCatalog.desktop)! < allModuleOrder.firstIndex(of: BuiltinCatalog.screenshots)! &&
                          allModuleOrder.firstIndex(of: BuiltinCatalog.clock)! < allModuleOrder.firstIndex(of: BuiltinCatalog.voice)!,
                          detail: "The same production move command places Spaces and clock at user-selected positions; the following native image records the result. Not a physical drag test.")
                edge.place(on: screen, primary: screen.id, content: .full)
                edge.presentIfNeeded()
                if let panel = edge.window {
                    panel.appearance = NSAppearance(named: .aqua)
                    pictures.append(try await capture(panel, name: "13-all-tools-clock-spaces-layout", to: output))
                    try check("all-modules-layout", panel.isVisible && singleMainWindow(),
                              detail: "The actual full sidebar lays out all registered modules, clock and Spaces. Synthetic content; no real window dispatch.")
                }
                await enableOnly([BuiltinCatalog.screenshots, BuiltinCatalog.lyrics])
                for state in ["playing", "paused", "noLyrics"] {
                    try check("lyrics-fixture-" + state, modules.installLyricsVerificationState(state),
                              detail: "A labelled synthetic snapshot was installed into the production lyric model.")
                    edge.place(on: screen, primary: screen.id, content: .toolsOnly)
                    edge.presentIfNeeded()
                    guard let panel = edge.window else { throw Failure("The lyric sidebar panel was unavailable.") }
                    pictures.append(try await capture(panel, name: "lyrics-" + state + "-sidebar", to: output))
                    let expected = state == "noLyrics" ? 104.0 : 192.0
                    try check("lyrics-height-" + state, modules.lyricsVerificationHeight == expected,
                              detail: "The production card retains its expected height for the supplied playback snapshot.")
                    if state == "paused" {
                        try await Task.sleep(for: .milliseconds(650))
                        try check("paused-card-survives-refresh", modules.lyricsVerificationHeight == expected,
                                  detail: "Native fixture view remained present across refreshes; long pauses are separately covered by clock-driven source tests.")
                        // Isolate the actual lyric card solely to locate its center
                        // from native geometry; no handcrafted view or hover flag.
                        await enableOnly([BuiltinCatalog.lyrics])
                        edge.place(on: screen, primary: screen.id, content: .toolsOnly)
                        edge.presentIfNeeded()
                        _ = await movePointer(to: NSPoint(x: panel.frame.minX - 40, y: panel.frame.midY))
                        let cleared = modules.clearLyricsVerificationControls()
                        let moved = await movePointer(to: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
                        try check("paused-native-hover-controls", cleared && moved && modules.lyricsVerificationControlsVisible,
                                  detail: "A native cursor move into the actual paused lyric card exercised SwiftUI hover after clearing only fixture controls.")
                        pictures.append(try await capture(panel, name: "lyrics-paused-native-hover", to: output))
                        let pausedNodes = accessibilityNodes(in: panel, includeHitTests: true)
                        let playButtons = pausedNodes.filter { $0.identifier == "lyric-playback-toggle" }
                        try writeAccessibilityDiagnostics("lyric-playback-toggle", rows: pausedNodes, actions: [],
                            dispatched: false, in: panel, to: output)
                        checks.append(["check": "paused-play-control-fixture-scope",
                                       "passed": !playButtons.isEmpty && playButtons.allSatisfy { $0.enabledKnown && !$0.enabled } &&
                                           !modules.lyricsVerificationOwnsSession,
                                       "evidenceKind": "native-accessibility-inspection",
                                       "matchingNodes": playButtons.count,
                                       "enabledNodes": playButtons.filter(\.enabled).count,
                                       "detail": "The paused control is inspected in the real native view. Fixture has no player lease, so disabled input is expected; actual resume belongs to the separate Music probe."])
                        _ = await movePointer(to: NSPoint(x: panel.frame.minX - 40, y: panel.frame.midY))
                        await enableOnly([BuiltinCatalog.screenshots, BuiltinCatalog.lyrics])
                        for detail in ["settings", "fullLyrics", "source", "adjustment"] {
                            navigation.showLyrics(detail)
                            let opened = openMainWindow()
                            try check("lyrics-internal-page-" + detail, opened === window && singleMainWindow(),
                                      detail: "The lyric auxiliary page uses the retained Nearpane main window.")
                            try await picture("lyrics-" + detail)
                        }
                    }
                }
                try check("lyrics-exit-fixture", modules.installLyricsVerificationState("exited"),
                          detail: "Synthetic player disappearance was delivered to the same visibility policy.")
                try check("lyrics-exit-releases-space", modules.lyricsVerificationHeight == 0,
                          detail: "The lyric module releases its sidebar height when its session ends.")
                edge.hide()
            } else {
                throw Failure("No native desktop display was available for sidebar verification.")
            }

            await enableOnly([])
            navigation.showVoiceArchive()
            try await picture("14-voice-library-module-disabled")
            navigation.showScreenshotArchive()
            try await picture("15-screenshot-library-module-disabled")
            let countsAfter = try CandidateProfile.inspectStores(in: session.support, counts: true)
            try check("history-survives-disable", originalCounts == countsAfter,
                      detail: "Voice recording and screenshot asset counts stayed unchanged after all module combinations and disable.")

            for preference in originalPreferences { host.handle(.setEnabled(preference.id, preference.enabled)) }
            var next: String?
            for preference in originalPreferences.reversed() {
                _ = host.moveModule(preference.id, before: next)
                next = preference.id
            }
            try check("configuration-restored", host.registry.preferences == originalPreferences,
                      detail: "The fixture returns to the original module preferences after verification.")
            window.performClose(nil)
            try await Task.sleep(for: .milliseconds(180))
            try check("main-window-close", !window.isVisible,
                      detail: "The production retained management window handles a native close action.")
            let reopened = openMainWindow()
            try await Task.sleep(for: .milliseconds(180))
            try check("main-window-reopen", reopened === window && window.isVisible && singleMainWindow(),
                      detail: "After close, the production opener shows the same retained NSWindow object; its WindowServer number may change.")
            try check("single-main-window-final", singleMainWindow(), detail: "No route or module action created a second management window.")
            sidebar?.hide()
            let failures = checks.filter { ($0["passed"] as? Bool) == false }.count
            guard failures == 0 else { throw Failure("\(failures) verification checks failed; native images and separate input diagnostics were preserved.") }
            writeReceipt("PASS")
        } catch {
            sidebar?.hide()
            writeReceipt("FAIL", error: error.localizedDescription)
            throw error
        }
    }

    private static func movePointer(to screenPoint: NSPoint) async -> Bool {
        guard let mainScreen = NSScreen.screens.first else { return false }
        let point = CGPoint(x: screenPoint.x, y: mainScreen.frame.maxY - screenPoint.y)
        guard CGWarpMouseCursorPosition(point) == .success,
              let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                  mouseCursorPosition: point, mouseButton: .left) else { return false }
        event.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(450))
        return true
    }

    private struct AccessibilityNode {
        let object: AnyObject
        var parent: Int?
        let role: String
        let identifier: String
        let label: String
        let enabled: Bool
        let enabledKnown: Bool
        let bridge: String
        let relation: String
    }

    /// SwiftUI may vend Objective-C accessibility objects without declaring the
    /// formal NSAccessibilityProtocol. Inspect public selectors as well as native
    /// view children. Public BOOL selectors need a BOOL-returning function bridge,
    /// not NSObject.perform's object-returning convention. A successful dispatch
    /// must still produce the expected product state before an input check passes.
    private static func accessibilityNodes(in window: NSWindow, includeHitTests: Bool = false) -> [AccessibilityNode] {
        var queue: [(AnyObject, Int?, String)] = [(window, nil, "window")]
        if let view = window.contentView {
            queue.append((view, nil, "contentView"))
            if includeHitTests {
                // Read-only native hit testing can expose SwiftUI scroll contents
                // omitted from a container's children array. EdgePanel's content
                // view is an AppKit wrapper: its inner AXGroup hosting view must
                // receive the query too. No coordinate click is dispatched.
                var views = [view]
                var hitTestRoots: [NSView] = []
                while let candidate = views.popLast() {
                    guard candidate.window === window else { continue }
                    if candidate === view || candidate.accessibilityRole() == .group {
                        hitTestRoots.append(candidate)
                    }
                    views.append(contentsOf: candidate.subviews)
                }
                let spacing: CGFloat = 24
                for root in hitTestRoots {
                    let bounds = root.visibleRect.intersection(root.bounds)
                    for y in stride(from: bounds.minY + spacing / 2, to: bounds.maxY, by: spacing) {
                        for x in stride(from: bounds.minX + spacing / 2, to: bounds.maxX, by: spacing) {
                            let point = window.convertPoint(toScreen: root.convert(NSPoint(x: x, y: y), to: nil))
                            if let hit = root.accessibilityHitTest(point) {
                                queue.append((hit as AnyObject, nil, "accessibilityHitTest"))
                            }
                        }
                    }
                }
            }
        }
        var visited = Set<ObjectIdentifier>()
        var result: [AccessibilityNode] = []
        while let (object, parent, relation) = queue.popLast(), visited.count < 2_400 {
            guard accessibilityObject(object, belongsTo: window) else { continue }
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            let node = object as? any NSAccessibilityProtocol
            let role = node?.accessibilityRole()?.rawValue
                ?? objectValue(object, "accessibilityRole") as? String
                ?? legacyValue(object, "AXRole") as? String ?? ""
            let identifier = node?.accessibilityIdentifier()
                ?? objectValue(object, "accessibilityIdentifier") as? String
                ?? legacyValue(object, "AXIdentifier") as? String ?? ""
            let label = node?.accessibilityLabel()
                ?? objectValue(object, "accessibilityLabel") as? String
                ?? legacyValue(object, "AXDescription") as? String
                ?? legacyValue(object, "AXTitle") as? String ?? ""
            let enabled = node?.isAccessibilityEnabled()
                ?? booleanValue(object, "isAccessibilityEnabled")
                ?? legacyValue(object, "AXEnabled") as? Bool
            let index = result.count
            result.append(.init(object: object, parent: parent, role: role, identifier: identifier,
                                label: String(label.prefix(120)), enabled: enabled ?? false, enabledKnown: enabled != nil,
                                bridge: node != nil ? "NSAccessibilityProtocol" : "public selectors with typed BOOL bridge",
                                relation: relation))
            if let view = object as? NSView {
                queue.append(contentsOf: view.subviews.map { ($0, index, "NSView.subviews") })
            }
            // These are complementary public AX relationships, not fallbacks:
            // a scroll area may have children=[] but nonempty contents.
            for (selector, legacy) in [
                ("accessibilityChildren", "AXChildren"),
                ("accessibilityContents", "AXContents"),
                ("accessibilityVisibleChildren", "AXVisibleChildren"),
                ("accessibilityChildrenInNavigationOrder", "AXChildrenInNavigationOrder")
            ] {
                let children = objectValue(object, selector) as? [Any]
                    ?? legacyValue(object, legacy) as? [Any] ?? []
                queue.append(contentsOf: children.map { ($0 as AnyObject, index, selector) })
            }
            if relation == "accessibilityHitTest" || relation == "accessibilityParent" {
                if let nativeParent = objectValue(object, "accessibilityParent") {
                    queue.append((nativeParent as AnyObject, nil, "accessibilityParent"))
                }
            }
        }
        // Prefer the platform's semantic parent when an element was reached by
        // hit testing or through more than one public child relationship.
        let indices = Dictionary(uniqueKeysWithValues: result.enumerated().map {
            (ObjectIdentifier($0.element.object), $0.offset)
        })
        for index in result.indices {
            if let nativeParent = objectValue(result[index].object, "accessibilityParent"),
               let parentIndex = indices[ObjectIdentifier(nativeParent as AnyObject)], parentIndex != index {
                result[index].parent = parentIndex
            }
        }
        return result
    }

    private static func accessibilityObject(_ object: AnyObject, belongsTo window: NSWindow) -> Bool {
        // Never climb from the target panel into NSApplication and then collect
        // an unrelated main window's controls or the application's menu bar.
        if object is NSApplication { return false }
        if let owner = object as? NSWindow { return owner === window }
        if let view = object as? NSView { return view.window === window }
        if let owner = objectValue(object, "accessibilityWindow") {
            return (owner as AnyObject) === window
        }
        // Some semantic nodes omit accessibilityWindow. They are accepted only
        // when reached from the already bounded target tree or its native hit test.
        return true
    }

    private static func booleanValue(_ value: AnyObject, _ name: String) -> Bool? {
        guard let object = value as? NSObject else { return nil }
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        typealias BooleanMethod = @convention(c) (AnyObject, Selector) -> Bool
        let implementation: IMP = object.method(for: selector)
        let method = unsafeBitCast(implementation, to: BooleanMethod.self)
        return method(object, selector)
    }

    private static func objectValue(_ value: AnyObject, _ name: String) -> Any? {
        guard let object = value as? NSObject else { return nil }
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private static func legacyValue(_ value: AnyObject, _ attribute: String) -> Any? {
        guard let object = value as? NSObject else { return nil }
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector, with: attribute)?.takeUnretainedValue()
    }

    private static func press(_ identifier: String, in window: NSWindow, diagnostics output: URL) async throws -> Bool {
        var rows: [AccessibilityNode] = []
        var actions: [[String: Any]] = []
        var dispatched = false
        var includeHitTests = false
        let interactive = Set(["AXButton", "AXCheckBox", "AXRadioButton", "AXSwitch", "AXMenuItem"])
        for attempt in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            if attempt > 0 && !rows.contains(where: { $0.identifier == identifier }) { includeHitTests = true }
            rows = accessibilityNodes(in: window, includeHitTests: includeHitTests)
            var attempted = Set<ObjectIdentifier>()
            for (index, match) in rows.enumerated() where match.identifier == identifier {
                // An identifier can be attached to a SwiftUI label. Only its real
                // interactive ancestor may receive the action; never press text.
                var candidate: Int? = index
                var depth = 0
                while let current = candidate, !interactive.contains(rows[current].role), depth < 8 {
                    candidate = rows[current].parent; depth += 1
                }
                guard let candidate, interactive.contains(rows[candidate].role) else {
                    if attempt == 0 {
                        actions.append(["matchedNode": index, "role": match.role, "identifier": match.identifier,
                                        "method": "no interactive ancestor", "returned": false])
                    }
                    continue
                }
                let target = rows[candidate]
                guard attempted.insert(ObjectIdentifier(target.object)).inserted else { continue }
                guard target.enabled else {
                    if attempt == 0 {
                        actions.append(["matchedNode": index, "pressedNode": candidate, "role": target.role,
                                        "identifier": target.identifier, "enabled": target.enabled, "enabledKnown": target.enabledKnown,
                                        "method": "native enabled state is false or unavailable", "returned": false])
                    }
                    continue
                }
                let result: Bool
                let method: String
                if let node = target.object as? any NSAccessibilityProtocol {
                    result = node.accessibilityPerformPress(); method = "NSAccessibilityProtocol.accessibilityPerformPress"
                } else if let pressed = booleanValue(target.object, "accessibilityPerformPress") {
                    result = pressed; method = "public accessibilityPerformPress selector via typed BOOL IMP"
                } else {
                    result = false; method = "typed accessibility press unavailable"
                }
                actions.append(["attempt": attempt, "matchedNode": index, "pressedNode": candidate,
                                "role": target.role, "identifier": target.identifier,
                                "label": target.label, "method": method, "returned": result])
                if result { dispatched = true; break }
            }
            if dispatched { try await Task.sleep(for: .milliseconds(180)); break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try writeAccessibilityDiagnostics(identifier, rows: rows, actions: actions, dispatched: dispatched, in: window, to: output)
        return dispatched
    }

    private static func writeAccessibilityDiagnostics(_ identifier: String, rows: [AccessibilityNode],
                                                     actions: [[String: Any]], dispatched: Bool,
                                                     in window: NSWindow, to output: URL) throws {
        let dump: [String: Any] = [
            "identifier": identifier, "actionDispatched": dispatched, "actions": actions,
            "windowNumber": window.windowNumber, "windowVisible": window.isVisible, "targetWindowScoped": true,
            "nodeCount": rows.count, "truncated": rows.count > 400,
            "matchingNodes": rows.enumerated().filter { $0.element.identifier == identifier }.map { $0.offset },
            "nodes": rows.prefix(400).enumerated().map { index, row -> [String: Any] in
                ["node": index, "parent": row.parent ?? -1,
                 "class": String(reflecting: Swift.type(of: row.object)), "bridge": row.bridge, "relation": row.relation,
                 "role": row.role, "identifier": row.identifier, "label": row.label,
                 "enabled": row.enabled, "enabledKnown": row.enabledKnown,
                 "availablePublicSelectors": ["isAccessibilityEnabled", "accessibilityPerformPress", "accessibilityChildren",
                    "accessibilityContents", "accessibilityVisibleChildren", "accessibilityChildrenInNavigationOrder", "accessibilityParent", "accessibilityWindow"]
                    .filter { (row.object as? NSObject)?.responds(to: NSSelectorFromString($0)) == true }]
            }
        ]
        let data = try JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("ax-" + identifier + ".json"), options: .atomic)
    }

    private static func capture(_ window: NSWindow, name: String, to output: URL) async throws -> [String: Any] {
        guard let view = window.contentView else { throw Failure("Missing native content view.") }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let visibleRows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
        let observed = visibleRows.contains { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber &&
            ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
        guard window.isVisible, observed else { throw Failure("The native window was not visible to WindowServer: " + name) }
        let target = output.appendingPathComponent(name + ".png")
        var method = "WindowServer screencapture"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), target.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 || !FileManager.default.fileExists(atPath: target.path) {
            method = "Native NSView cacheDisplay of visible NSWindow (screen capture unavailable)"
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw Failure("Unable to obtain a native bitmap: " + name)
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure("PNG encoding failed: " + name) }
            try png.write(to: target, options: .atomic)
        }
        let data = try Data(contentsOf: target)
        guard let image = NSBitmapImageRep(data: data), image.pixelsWide > 20, image.pixelsHigh > 20 else {
            throw Failure("The native capture was invalid: " + name)
        }
        return ["file": target.lastPathComponent, "method": method,
                "windowNumber": window.windowNumber, "windowServerVisible": observed,
                "contentWidth": view.bounds.width, "contentHeight": view.bounds.height,
                "pixelsWide": image.pixelsWide, "pixelsHigh": image.pixelsHigh,
                "appearance": window.effectiveAppearance.name.rawValue,
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
    }
}
#endif
