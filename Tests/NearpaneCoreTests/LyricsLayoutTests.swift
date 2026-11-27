import Testing
@testable import NearpaneCore

struct LyricsLayoutTests {
    private let order = [BuiltinCatalog.screenshots, BuiltinCatalog.lyrics, BuiltinCatalog.memo]
    @Test func idleDoesNotReserveSpace() {
        let layout = LayoutComposer.compose(width: 240, height: 900, pinnedCount: 0, expanded: false, voiceEnabled: false, toolOrder: order)
        let absent = LayoutComposer.compose(width: 240, height: 900, pinnedCount: 0, expanded: false, voiceEnabled: false, toolOrder: order.filter { $0 != BuiltinCatalog.lyrics })
        #expect(layout == absent)
    }
    @Test func playbackUsesActualOrderedSidebarSlot() {
        for height in [104.0, 192.0] {
            let layout = LayoutComposer.compose(width: 240, height: 900, pinnedCount: 0, expanded: false, voiceEnabled: false, lyricsHeight: height, toolOrder: order)
            let lyric = layout.additionalTools[BuiltinCatalog.lyrics]
            #expect(lyric?.height == height)
            #expect((lyric?.y ?? -1) >= layout.screenshots.y + layout.screenshots.height)
            #expect((layout.additionalTools[BuiltinCatalog.memo]?.y ?? -1) >= (lyric?.y ?? 0) + height)
            #expect(layout.desktop.y >= (lyric?.y ?? 0) + height)
        }
    }
    @Test func noTruncatedLyricsOnOtherSurfaces() {
        for content in [PanelContent.spacesOnly, .voiceOnly, .trayOnly, .hidden] {
            let layout = LayoutComposer.compose(width: 240, height: 900, pinnedCount: 0, expanded: false, content: content, lyricsHeight: 192, toolOrder: order)
            #expect(layout.additionalTools[BuiltinCatalog.lyrics] == nil)
        }
        let narrow = LayoutComposer.compose(width: 100, height: 900, pinnedCount: 0, expanded: false, lyricsHeight: 192, toolOrder: order)
        #expect(narrow.additionalTools[BuiltinCatalog.lyrics] == nil)
        let short = LayoutComposer.compose(width: 240, height: 100, pinnedCount: 0, expanded: false, lyricsHeight: 192, toolOrder: order)
        #expect(short.additionalTools[BuiltinCatalog.lyrics] == nil)
    }
    @Test @MainActor func lyricsIsOptionalReorderableAndNotARailSample() throws {
        let diagnostics = Diagnostics()
        let registry = ModuleRegistry(bus: SnapshotBus(diagnostics: diagnostics), diagnostics: diagnostics)
        for manifest in BuiltinCatalog.productManifests { try registry.register(manifest) { SampleModule(message: "fixture") } }
        registry.restore([])
        #expect(registry.preferences.first { $0.id == BuiltinCatalog.lyrics }?.enabled == false)
        try registry.setEnabled(BuiltinCatalog.lyrics, true)
        #expect(registry.states[BuiltinCatalog.lyrics] == .resident)
        #expect(!registry.pinnedModules.contains { $0.id == BuiltinCatalog.lyrics })
        try registry.move(BuiltinCatalog.lyrics, by: -1)
        try registry.setEnabled(BuiltinCatalog.lyrics, false)
        #expect(registry.states[BuiltinCatalog.lyrics] == .disabled)
    }
}
