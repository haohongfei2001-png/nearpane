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

        func check(_ name: String, _ success: Bool, detail: String) throws {
            checks.append(["check": name, "passed": success, "detail": detail])
            guard success else { throw Failure(name + ": " + detail) }
        }
        func writeReceipt(_ status: String, error: String? = nil) {
            var receipt: [String: Any] = [
                "schema": 1, "status": status,
                "sourceCommit": Bundle.main.object(forInfoDictionaryKey: "NearpaneUnifiedWorkbenchCommit") as? String ?? "unknown",
                "platform": ProcessInfo.processInfo.operatingSystemVersionString,
                "evidenceScope": "Packaged Nearpane native UI; isolated generated content; in-process accessibility actions",
                "playbackScope": "Synthetic snapshots only; does not certify a real music player's controls or metadata",
                "spacesScope": "No real window dispatch was performed; PR 16 remains separately qualified",
                "nativeMenuDispatchAttempted": menu != nil,
                "checks": checks, "screenshots": pictures
            ]
            if let error { receipt["error"] = error }
            if let data = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("native-workbench-receipt.json"), options: .atomic)
            }
        }
        func singleMainWindow() -> Bool {
            let windows = NSApp.windows.filter { $0.identifier?.rawValue == "nearpane-main-window" }
            let management = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
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

        do {
            try check("native-window-visible", window.isVisible && window.contentView != nil,
                      detail: "The actual retained Nearpane management NSWindow is ordered on the cloud desktop.")
            try check("single-main-window-initial", singleMainWindow(), detail: "Exactly one standard management window.")

            navigation.showModules()
            try await press("main-nav-modules", in: window)
            try check("modules-navigation", navigation.selectedPageIdentifier == "modules", detail: "Native accessibility press selected Modules.")
            try await picture("01-modules-light")
            try await picture("02-modules-dark", appearance: .darkAqua)
            try await picture("03-modules-compact", size: NSSize(width: 740, height: 520))

            try await press("module-open-" + BuiltinCatalog.screenshots, in: window)
            try check("module-detail-route", navigation.selectedPageIdentifier == "tray", detail: "Screenshot detail is inside the same window.")
            try await picture("04-screenshot-module")
            try await press("main-back-to-modules", in: window)
            try check("module-detail-return", navigation.selectedPageIdentifier == "modules", detail: "The detail back action returns to Modules.")

            try await press("main-nav-library", in: window)
            try check("library-navigation", navigation.selectedSectionIdentifier == "library", detail: "Native accessibility press entered the content library.")
            navigation.showVoiceArchive()
            try await picture("05-voice-library")
            navigation.showScreenshotArchive()
            try await picture("06-screenshot-library")
            try await picture("07-screenshot-library-dark", appearance: .darkAqua)

            try await press("main-nav-settings", in: window)
            try check("settings-navigation", navigation.selectedSectionIdentifier == "settings", detail: "Native accessibility press entered global settings.")
            navigation.showGeneral()
            try await picture("08-settings-general")
            navigation.showAppearance()
            try await picture("09-settings-appearance")
            try await picture("10-settings-compact-dark", appearance: .darkAqua, size: NSSize(width: 740, height: 520))

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
                                             ("showGeneralSettings", "general"), ("showWindowManagement", "windowManagement")] {
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
                (BuiltinCatalog.lyrics, "source", "lyrics")
            ] {
                moduleRoute(moduleID, page)
                try await Task.sleep(for: .milliseconds(160))
                try check("module-entry-" + moduleID + "-" + page,
                          navigation.selectedPageIdentifier == expected && singleMainWindow() && window.windowNumber == originalNumber,
                          detail: "The production module-to-Host callback reused the same main window.")
            }

            navigation.showModules()
            window.setContentSize(NSSize(width: 920, height: 660))
            let memoBefore = enabled(BuiltinCatalog.memo)
            try await press("module-enabled-" + BuiltinCatalog.memo, in: window)
            try check("module-toggle-native-action", enabled(BuiltinCatalog.memo) != memoBefore,
                      detail: "The real module switch changed the Host registry.")
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
            for preference in originalPreferences.filter({ BuiltinCatalog.sidebarTools.contains($0.id) }).reversed() {
                _ = host.moveModule(preference.id, before: next)
                next = preference.id
            }
            try check("configuration-restored", host.registry.preferences == originalPreferences,
                      detail: "The fixture returns to the original module preferences after verification.")
            try check("single-main-window-final", singleMainWindow(), detail: "No route or module action created a second management window.")
            sidebar?.hide()
            writeReceipt("PASS")
        } catch {
            sidebar?.hide()
            writeReceipt("FAIL", error: error.localizedDescription)
            throw error
        }
    }

    private static func press(_ identifier: String, in window: NSWindow) async throws {
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            var queue: [AnyObject] = [window]
            var visited = Set<ObjectIdentifier>()
            while let object = queue.popLast(), visited.count < 2_400 {
                guard visited.insert(ObjectIdentifier(object)).inserted,
                      let node = object as? any NSAccessibilityProtocol else { continue }
                if node.accessibilityIdentifier() == identifier, node.isAccessibilityEnabled(),
                   node.accessibilityRole() != .staticText, node.accessibilityPerformPress() {
                    try await Task.sleep(for: .milliseconds(180))
                    return
                }
                queue.append(contentsOf: (node.accessibilityChildren() ?? []).map { $0 as AnyObject })
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure("Native accessibility action was unavailable: " + identifier)
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
