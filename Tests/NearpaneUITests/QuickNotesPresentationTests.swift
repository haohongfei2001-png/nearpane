import Foundation
import Testing
@testable import NearpaneUI
@testable import NearpaneCore

@MainActor struct QuickNotesPresentationTests {
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
