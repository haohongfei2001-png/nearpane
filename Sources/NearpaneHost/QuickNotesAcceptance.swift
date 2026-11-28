#if DEBUG && canImport(SaytileKit) && canImport(RiftletCore)
import AppKit
import Foundation
import NearpaneCore
import NearpaneUI

/// Exercises the production views and their one live notebook on an isolated,
/// executable-bound macOS profile. Generated contents are explicitly fixtures.
@MainActor enum QuickNotesAcceptance {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ value: String) { errorDescription = value }
    }

    static func run(mode: String, session: NativeAcceptanceSession, host: HostSession,
                    modules: EmbeddedModules, navigation: SettingsNavigation,
                    window: NSWindow, openMainWindow: () -> NSWindow?) async throws {
        guard NativeVerificationAccessibility.isEnabled,
              ["ui", "readback", "crash-write", "crash-readback", "migration"].contains(mode) else {
            throw Failure("Quick Notes acceptance requires the existing isolated native profile.")
        }
        let root = session.directory.appendingPathComponent("quick-notes", isDirectory: true)
        let output = root.appendingPathComponent(mode, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let notebookDirectory = session.support.appendingPathComponent("Nearpane", isDirectory: true)
        let stateFile = root.appendingPathComponent(mode.hasPrefix("crash") ? "crash-expected.json" : "expected.json")
        var checks: [[String: Any]] = []
        var pictures: [[String: Any]] = []
        let edge = EdgeWindowController(host: host, modules: modules)
        let tools = FullscreenToolPanelController(host: host, domains: modules)
        let originalPreferences = host.registry.preferences
        let originalWindowNumber = window.windowNumber
        var panel: NSWindow?

        func state() -> QuickNotesVerificationState { modules.quickNotesVerificationState }
        func record(_ id: UUID) -> QuickNotesVerificationRecord? { state().records.first { $0.id == id } }
        func check(_ name: String, _ passed: Bool, _ detail: String,
                   kind: String = "production-state-readback") throws {
            checks.append(["check": name, "passed": passed, "detail": detail, "evidenceKind": kind])
            guard passed else { throw Failure(name + ": " + detail) }
        }
        func receipt(_ status: String, error: String? = nil) {
            var value: [String: Any] = [
                "schema": 1, "status": status, "mode": mode,
                "sourceCommit": Bundle.main.object(forInfoDictionaryKey: "NearpaneQuickNotesCommit") as? String ?? "unknown",
                "platform": ProcessInfo.processInfo.operatingSystemVersionString,
                "applicationEventLoopRunning": NSApp.isRunning,
                "evidenceScope": "Real packaged AppKit/SwiftUI windows; isolated generated notebook, speech, tray and lyric content",
                "inputScope": "In-process native AX button presses and actual NSTextView input after AppKit mouse dispatch; no model fallback can pass input checks",
                "spacesScope": "Production Spaces surface only; no real foreign-window dispatch is claimed",
                "fullscreenScope": "Production temporary tool panel shown on cloud desktop; does not qualify a real native-fullscreen transition",
                "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                "checks": checks, "screenshots": pictures
            ]
            if let error { value["error"] = error }
            if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
                try? bytes.write(to: output.appendingPathComponent("native-quick-notes-receipt.json"), options: .atomic)
            }
        }
        func saved(_ name: String) throws {
            try check(name, state().readable && !state().hasUnsavedChanges &&
                      modules.quickNotesVerificationReload(directory: notebookDirectory) == state(),
                      "Fresh production notebook read matches every identity, body, type, timestamp, completion and active note.")
        }
        func press(_ id: String, in target: NSWindow, name: String) async throws {
            let result = try await UnifiedWorkbenchAcceptance.press(id, in: target, diagnostics: output)
            try check(name, result, "Native accessibility press: " + id, kind: "native-accessibility")
        }
        func type(_ text: String, id: String, in target: NSWindow, name: String) async throws {
            let result = try await UnifiedWorkbenchAcceptance.replaceText(text, identifier: id, in: target, diagnostics: output)
            try check(name, result, "Mouse-focused production NSTextView received insertText; its delegate and binding own persistence.",
                      kind: "appkit-text-input")
        }
        func capture(_ target: NSWindow, _ name: String, dark: Bool = false) async throws {
            target.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            pictures.append(try await UnifiedWorkbenchAcceptance.capture(target, name: name, to: output))
            receipt("RUNNING")
        }
        func enableOnly(_ ids: Set<String>) async {
            for row in host.registry.preferences where row.enabled != ids.contains(row.id) {
                host.handle(.setEnabled(row.id, ids.contains(row.id)))
            }
            await modules.voice.waitForTransition()
            await Task.yield()
        }
        func showSidebar(on screen: ScreenGeometry, width: Double = 280, full: Bool = false) async throws -> NSWindow {
            var settings = host.panelPresentationSettings(on: screen.id)
            settings.measures[.panelWidth] = .init(width)
            host.setDisplaySettings(settings, id: screen.id)
            edge.place(on: screen, primary: screen.id, content: full ? .full : .toolsOnly)
            edge.presentIfNeeded()
            guard let target = edge.window, target.isVisible else { throw Failure("Production sidebar did not become visible.") }
            panel = target
            try await Task.sleep(for: .milliseconds(180))
            _ = await UnifiedWorkbenchAcceptance.movePointer(to: NSPoint(x: target.frame.midX, y: target.frame.midY))
            return target
        }
        func saveExpected() throws {
            try JSONEncoder().encode(state()).write(to: stateFile, options: .atomic)
        }

        do {
            guard let screen = SystemScreens.geometry().first else { throw Failure("No macOS desktop display is available.") }
            await enableOnly([BuiltinCatalog.memo])
            let sidebar = try await showSidebar(on: screen)

            if mode == "readback" || mode == "crash-readback" {
                let expected = try JSONDecoder().decode(QuickNotesVerificationState.self, from: Data(contentsOf: stateFile))
                try check("separate-process-state-restored", state() == expected,
                          "The separately launched packaged Host restored exact record IDs, contents, properties and active note.")
                try saved("separate-process-disk-readback")
                try await capture(sidebar, mode == "readback" ? "09-normal-restart" : "10-killed-process-restart")
                navigation.showNotebookLibrary()
                _ = openMainWindow()
                try await capture(window, "restored-library")
                receipt("PASS")
                edge.hide()
                return
            }

            if mode == "crash-write" {
                try await press("quick-notes-new", in: sidebar, name: "crash-trial-new-note")
                let text = "异常中断前的最后一句，也应完整留下。\n这条记录由原生编辑器写入。"
                try await type(text, id: "quick-notes-editor", in: sidebar, name: "crash-trial-native-input")
                try check("crash-trial-body", state().activeRecordID.flatMap(record)?.body == text,
                          "The current production record contains the final text.")
                try saved("crash-trial-already-autosaved")
                try saveExpected()
                try await capture(sidebar, "before-process-kill")
                receipt("READY_FOR_SIGKILL")
                try Data("ready\n".utf8).write(to: root.appendingPathComponent("crash-ready"), options: .atomic)
                // The external runner kills this exact child without calling a
                // close handler, flush, module stop or application termination.
                while true { try await Task.sleep(for: .seconds(1)) }
            }

            if mode == "migration" {
                let migrated = state()
                try check("legacy-memo-and-tasks-migrated", migrated.records.count == 3 &&
                          migrated.records.contains { $0.body == "原来的便签\n第二行仍然在。" && $0.kind == "note" } &&
                          migrated.records.contains { $0.id.uuidString == "33333333-3333-4333-8333-333333333333" && $0.body == "尚未完成的旧事项" && !$0.isCompleted } &&
                          migrated.records.contains { $0.id.uuidString == "44444444-4444-4444-8444-444444444444" && $0.body == "已经完成的旧事项" && $0.isCompleted },
                          "Old memo and both legacy tasks survived startup migration with task identities and completion preserved.")
                try saved("migrated-disk-readback")
                try await capture(sidebar, "legacy-migration-sidebar")
                navigation.showNotebookLibrary()
                _ = openMainWindow()
                try await capture(window, "legacy-migration-library")
                receipt("PASS")
                edge.hide()
                return
            }

            try check("fresh-profile-empty", state().records.isEmpty && state().activeRecordID == nil,
                      "Fresh Nearpane profile has no note or task and requires no additional setup.")
            _ = await UnifiedWorkbenchAcceptance.movePointer(to: NSPoint(
                x: screen.frame.x + screen.frame.width / 2,
                y: screen.frame.y + screen.frame.height / 2))
            try await capture(sidebar, "01-idle")
            try await press("quick-notes-start", in: sidebar, name: "idle-entry-starts-editing")
            var firstBody = "把沿途想到的句子留在这里。\n明天继续整理 Nearpane 的交互。"
            try await type(firstBody, id: "quick-notes-editor", in: sidebar, name: "first-note-multiline-input")
            guard let first = state().activeRecordID else { throw Failure("First record has no identity.") }
            try saved("first-note-autosaved")
            try await capture(sidebar, "02-editing")

            let composition = try UnifiedWorkbenchAcceptance.beginMarkedText("留住灵感", identifier: "quick-notes-editor",
                                                                              in: sidebar, diagnostics: output)
            try check("native-composition-started", composition,
                      "The production NSTextView displays marked Chinese text; this does not claim a real system input-method session.",
                      kind: "native-text-input-client-composition")
            firstBody += "留住灵感"

            try await press("quick-notes-new", in: sidebar, name: "new-note-keeps-previous")
            guard let converted = state().activeRecordID, converted != first else { throw Failure("New note reused the old identity.") }
            let taskBody = "把今天想到的交互细节画下来"
            try await type(taskBody, id: "quick-notes-editor", in: sidebar, name: "second-note-input")
            try check("prior-note-and-marked-text-retained", record(first)?.body == firstBody && record(converted)?.body == taskBody,
                      "New-note action retained the old editor's visible composed text on its original identity; the next note kept its own body.")
            try await press("quick-notes-convert-to-task", in: sidebar, name: "note-to-task-native-action")
            try check("conversion-retains-identity", record(converted)?.kind == "task" && record(converted)?.body == taskBody &&
                      state().records.filter { $0.id == converted }.count == 1,
                      "Type conversion changed one existing identity without losing or duplicating its body.")

            try await press("quick-notes-start", in: sidebar, name: "start-note-alongside-tasks")
            let currentBody = "灵感不需要先整理。\n先留下一句，再继续手上的工作。"
            try await type(currentBody, id: "quick-notes-editor", in: sidebar, name: "combined-note-input")
            guard let current = state().activeRecordID else { throw Failure("Combined state has no active note.") }
            let beforeTask = Set(state().records.map(\.id))
            try await press("quick-notes-add-task", in: sidebar, name: "direct-task-creation")
            guard let directTask = state().records.first(where: { !beforeTask.contains($0.id) && $0.kind == "task" })?.id else {
                throw Failure("Direct task entry did not create exactly one persisted task.")
            }
            try await type("给家里打个电话", id: "quick-notes-task-editor-" + directTask.uuidString,
                           in: sidebar, name: "direct-task-native-input")
            try saved("combined-content-autosaved")
            let combinedVisible = try await UnifiedWorkbenchAcceptance.fullyVisibleTextEditors([
                "quick-notes-editor", "quick-notes-task-editor-" + converted.uuidString,
                "quick-notes-task-editor-" + directTask.uuidString
            ], in: sidebar, diagnostics: output)
            if !combinedVisible { try await capture(sidebar, "03-note-and-tasks-failed") }
            try check("combined-native-text-visible", combinedVisible,
                      "The actual laid-out current note and both short task bodies fit their native visible rectangles after natural reflow; no resize or scrolling workaround.",
                      kind: "native-layout-geometry")
            try await capture(sidebar, "03-note-and-tasks")

            try await press("quick-notes-toggle-" + converted.uuidString, in: sidebar, name: "complete-task-native-action")
            try check("task-completion-stored", record(converted)?.isCompleted == true && record(converted)?.completedAt != nil,
                      "The original task is completed and records a completion date.")
            try await Task.sleep(for: .milliseconds(800))
            try await capture(sidebar, "task-completed-feedback-settled")
            try await press("quick-notes-open-library", in: sidebar, name: "sidebar-opens-selected-record")
            try check("same-main-window-and-exact-record", navigation.selectedSectionIdentifier == "library" &&
                      navigation.selectedNotebookRecordID == current && window.windowNumber == originalWindowNumber && window.isVisible,
                      "The sidebar reused the retained management window and selected its active note.")
            window.setContentSize(NSSize(width: 920, height: 660))
            let editedBody = currentBody + "\n仓库里的修改也立即回到侧栏。"
            try await type(editedBody, id: "notebook-editor", in: window, name: "library-native-edit")
            try check("shared-live-record", record(current)?.body == editedBody && state().activeRecordID == current,
                      "Library edits changed the same current record shown by the sidebar.")
            try await press("notebook-filter-completed", in: window, name: "completed-history-filter")
            try await press("notebook-row-" + converted.uuidString, in: window, name: "completed-history-select")
            try await press("notebook-toggle-completed", in: window, name: "undo-completion-native-action")
            try check("task-reopened", record(converted)?.isCompleted == false && record(converted)?.completedAt == nil,
                      "Reopening a completed task clears its completion date and preserves its identity.")
            try await press("notebook-filter-all", in: window, name: "all-records-filter")
            try await press("notebook-row-" + converted.uuidString, in: window, name: "reopened-task-select")
            try await press("notebook-convert", in: window, name: "task-to-note-native-action")
            try check("reverse-conversion-retains-content", record(converted)?.kind == "note" && record(converted)?.body == taskBody &&
                      state().records.filter { $0.id == converted }.count == 1,
                      "The task became a plain note using its existing identity and body.")
            try await press("notebook-copy", in: window, name: "copy-record-native-action")
            try check("clipboard-contains-record", NSPasteboard.general.string(forType: .string) == taskBody,
                      "The production copy action placed the selected body on this disposable runner's clipboard.")
            try await press("notebook-row-" + first.uuidString, in: window, name: "select-removal-fixture")
            try await press("notebook-delete", in: window, name: "delete-opens-confirmation")
            try check("delete-not-premature", record(first) != nil, "Opening deletion confirmation has not removed the record.")
            try await press("notebook-confirm-delete", in: window, name: "confirm-fixture-deletion")
            try check("only-selected-record-deleted", record(first) == nil && record(current)?.body == editedBody,
                      "The explicitly confirmed fixture was removed while the current record remained intact.")
            try saved("management-operations-autosaved")
            navigation.showNotebookLibrary(recordID: current)
            _ = openMainWindow()
            try await capture(window, "05-library")

            for body in ["整理一份简短的作品清单", "预约周末的图书馆座位", "检查旧记录的迁移结果", "下周试试更紧凑的侧栏", "回看旅行途中记下的想法", "把重要的事情逐一完成"] {
                try check("overflow-fixture-seeded", modules.seedQuickNotesVerificationTask(body) != nil,
                          "Generated overflow fixture created through production persistence; not a native input claim.", kind: "labelled-fixture-setup")
            }
            let narrow = try await showSidebar(on: screen, width: 220)
            try await capture(narrow, "04-many-tasks-narrow")
            let wide = try await showSidebar(on: screen, width: 340)
            try await capture(wide, "many-tasks-wide")
            try await capture(wide, "07-dark", dark: true)
            try await capture(window, "library-dark", dark: true)

            let beforeHide = state()
            edge.hide()
            _ = openMainWindow()
            try saved("hide-and-window-switch-autosave")
            try check("hide-keeps-active-record", state() == beforeHide,
                      "Hiding the sidebar and activating the management window did not drop the draft.")
            host.handle(.setEnabled(BuiltinCatalog.memo, false))
            navigation.showNotebookLibrary(recordID: current)
            _ = openMainWindow()
            try check("disabled-history-remains", state() == beforeHide &&
                      host.registry.preferences.contains { $0.id == BuiltinCatalog.memo && !$0.enabled },
                      "Disabling the module retained its history and the management window's selected record.")
            try await capture(window, "library-module-disabled")

            await enableOnly([BuiltinCatalog.voice, BuiltinCatalog.screenshots, BuiltinCatalog.lyrics,
                              BuiltinCatalog.memo, BuiltinCatalog.desktop])
            _ = modules.installLyricsVerificationState("playing")
            let full = try await showSidebar(on: screen, width: 280, full: true)
            try check("spaces-outline-fixture-light", QuickNotesSpacesFixture.install(host: host, screen: screen),
                      "Controlled geometry-only window observations feed the production Spaces cards; no real window capture or dispatch.",
                      kind: "labelled-fixture-setup")
            try await capture(full, "06-full-sidebar")
            try check("spaces-outline-fixture-dark", QuickNotesSpacesFixture.install(host: host, screen: screen),
                      "Fresh controlled geometry-only observations keep the same production cards visible in dark mode.",
                      kind: "labelled-fixture-setup")
            try await capture(full, "full-sidebar-dark", dark: true)
            host.bus.resetDesktopSession()
            try check("one-management-window", NSApp.windows.filter {
                $0.isVisible && $0.styleMask.contains(.titled)
            }.count == 1, "All module and record routes retained the single management window.")

            edge.hide()
            tools.show(on: screen, expanded: .workspace, open: { _ in }, close: {})
            guard let temporary = tools.window, temporary.isVisible else {
                throw Failure("Production temporary tools workspace was unavailable.")
            }
            try await capture(temporary, "08-temporary-tools-workspace")
            try check("temporary-tools-share-records", state().records.contains { $0.id == current && $0.body == editedBody },
                      "The production temporary workspace uses the existing domain instance; no real fullscreen transition claimed.")
            tools.hide()
            try saved("final-ui-disk-readback")
            try saveExpected()
            for row in originalPreferences { host.handle(.setEnabled(row.id, row.enabled)) }
            receipt("PASS")
        } catch {
            receipt("FAIL", error: error.localizedDescription)
            tools.hide()
            edge.hide()
            throw error
        }
        tools.hide()
        edge.hide()
        _ = panel
    }
}
#endif
