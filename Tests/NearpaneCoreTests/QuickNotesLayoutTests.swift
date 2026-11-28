import Testing
@testable import NearpaneCore

struct QuickNotesLayoutTests {
    @Test func anIdleRecordEntryDoesNotReserveAnEmptyEditor() throws {
        let layout = LayoutComposer.compose(width: 240, height: 832, pinnedCount: 0, expanded: false,
            content: .toolsOnly, voiceEnabled: false, trayEnabled: false, notesHeight: 44,
            toolOrder: [BuiltinCatalog.memo])
        #expect(layout.additionalTools[BuiltinCatalog.memo]?.height == 44)
        #expect(layout.additionalTools[BuiltinCatalog.tasks] == nil)
        #expect(layout.contentHeight < 80)
        #expect(DisplaySettings().sizeForm(width: 240, height: 150, content: .toolsOnly,
            voice: false, tray: false, notesHeight: 44, toolOrder: [BuiltinCatalog.memo]) == .full)
    }

    @Test func aLongDraftIsBoundedAndKeepsTheWindowViewport() throws {
        let order = [BuiltinCatalog.voice, BuiltinCatalog.screenshots, BuiltinCatalog.lyrics,
                     BuiltinCatalog.memo, BuiltinCatalog.desktop]
        for width in [176.0, 240, 320] {
            for height in [220.0, 832, 1080] {
                let layout = LayoutComposer.compose(width: width, height: height, pinnedCount: 0, expanded: false,
                    lyricsHeight: 192, notesHeight: 10000, toolOrder: order)
                let note = try #require(layout.frame(for: BuiltinCatalog.memo))
                #expect(note.height >= 72 && note.height <= 280)
                #expect(layout.windowArea.height >= 95.99)
                let frames = order.compactMap { layout.frame(for: $0) }
                for (left, right) in zip(frames, frames.dropFirst()) {
                    #expect(left.y + left.height <= right.y)
                }
            }
        }
    }

    @Test func fullscreenReusesTheSameCompactEntryWithoutAGhostTaskModule() throws {
        let rect = SurfaceRect(width: 1440, height: 900)
        let screen = ScreenGeometry(id: "notes", frame: rect, visibleFrame: rect)
        let layout = try #require(FullscreenWorkspaceLayout(on: screen, settings: .init(),
            enabledModuleIDs: [BuiltinCatalog.memo], notesHeight: 44))
        #expect(layout.visibleModuleIDs == [BuiltinCatalog.memo])
        #expect(layout.content.frame(for: BuiltinCatalog.memo)?.height == 44)
        #expect(layout.content.windowArea.height == 0)
        #expect(layout.height < 120)
    }
}
