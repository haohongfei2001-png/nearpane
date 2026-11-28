import AppKit
import Foundation
import Testing
@testable import NearpaneUI
@testable import NearpaneCore

@MainActor struct QuickNotesPresentationTests {
    @Test func theExistingNativePanelRefitsGrowingAndCompletedTasksWithoutAnotherPlacement() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-live-panel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = HostConfiguration()
        configuration.modules = BuiltinCatalog.manifests.map {
            ModulePreference(id: $0.id, enabled: $0.id == BuiltinCatalog.memo, pinned: false)
        }
        let modules = EmbeddedModules(support: root, testSession: root)
        let host = modules.makeHost(store: MemoryConfigurationStore(configuration))
        await host.start()
        defer { host.stop() }
        let notebook = modules.notebook
        let note = try #require(notebook.beginNote())
        #expect(notebook.updateRecord(note, body: "灵感不需要先整理。\n先留下一句，再继续手上的工作。"))
        let rect = SurfaceRect(width: 1440, height: 900)
        let screen = ScreenGeometry(id: "notes-live-panel", frame: rect, visibleFrame: rect)
        var settings = DisplaySettings()
        settings.measures[.panelWidth] = .init(280)
        host.setDisplaySettings(settings, id: screen.id)
        let controller = EdgeWindowController(host: host, modules: modules)
        defer { controller.close() }
        // This is the only placement call. Subsequent model changes must reflow
        // the mounted native window through the production observation bridge.
        controller.place(on: screen, primary: screen.id, content: .toolsOnly)
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        let initialWindow = window.windowNumber
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.accessibilityIdentifier() == "quick-notes-editor" { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        func expectedHeight() throws -> Double {
            try #require(PanelSizeLayout(settings: host.panelPresentationSettings(on: screen.id), screen: screen,
                edge: .right, content: .toolsOnly, voice: false, tray: false, floating: false,
                toolOrder: [BuiltinCatalog.memo], notesHeight: notebook.sidebarHeight(width: 280))).frame.height
        }
        func waitFor(_ ready: () -> Bool) async throws -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            repeat {
                content.layoutSubtreeIfNeeded()
                content.displayIfNeeded()
                if ready() { return true }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < deadline
            return ready()
        }
        try #require(try await waitFor { editor(in: content) != nil })
        let originalEditor = try #require(editor(in: content))
        originalEditor.setSelectedRange(NSRange(location: 3, length: 0))
        let writingHeight = window.frame.height
        let first = try #require(notebook.createTask(body: "把今天想到的交互细节画下来"))
        let second = try #require(notebook.createTask(body: "给家里打个电话"))
        let combinedHeight = try expectedHeight()
        #expect(combinedHeight >= writingHeight + 60)
        #expect(try await waitFor { abs(window.frame.height - combinedHeight) <= 1 })
        #expect(editor(in: content) === originalEditor)
        #expect(originalEditor.selectedRange() == NSRange(location: 3, length: 0))
        #expect(notebook.activeRecordID == note && notebook.unfinishedTasks.count == 2)
        #expect(notebook.setCompleted(first, completed: true))
        #expect(notebook.setCompleted(second, completed: true))
        #expect(try await waitFor { abs(window.frame.height - writingHeight) <= 1 })
        #expect(notebook.endNote())
        let idleHeight = try expectedHeight()
        #expect(try await waitFor { abs(window.frame.height - idleHeight) <= 1 })
        #expect(idleHeight < writingHeight && window.windowNumber == initialWindow && !window.isVisible)
        host.stop()
        await modules.finishStopping()
    }

    @Test func theNativePanelFitsTheLiveDraftInsteadOfReservingTheOldEmptyCard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let notebook = SidebarNotebook(directory: root)
        let rect = SurfaceRect(width: 1440, height: 900)
        let screen = ScreenGeometry(id: "quick-notes", frame: rect, visibleFrame: rect)
        func layout() throws -> PanelSizeLayout {
            try #require(PanelSizeLayout(settings: .init(), screen: screen, edge: .right,
                content: .toolsOnly, voice: false, tray: false, floating: false,
                toolOrder: [BuiltinCatalog.memo], notesHeight: notebook.sidebarHeight(width: 240)))
        }
        let idle = try layout()
        #expect(idle.form == .full && idle.frame.height < 80)
        _ = notebook.beginNote()
        #expect(notebook.updateActiveBody("把今天的新想法记下来。\n下次接着写。"))
        let writing = try layout()
        #expect(writing.form == .full && writing.frame.height > idle.frame.height)
        for index in 0..<20 { _ = notebook.createTask(body: "事项 \(index)") }
        let crowded = try layout()
        #expect(crowded.form == .full && crowded.frame.height <= 304)
        #expect(notebook.unfinishedTasks.count == 20)
    }
}
