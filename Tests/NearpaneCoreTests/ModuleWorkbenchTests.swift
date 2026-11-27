import Foundation
import Testing
@testable import NearpaneCore

@MainActor @Suite struct ModuleWorkbenchTests {
    @Test func dragOrderPersistsWithoutChangingEnablementOrDesktopSlots() throws {
        let harness = RegistryHarness()
        for manifest in BuiltinCatalog.productManifests {
            try harness.registry.register(manifest) { TrackingModule() }
        }
        let before = harness.registry.preferences
        try harness.registry.move(BuiltinCatalog.lyrics, before: BuiltinCatalog.voice)
        let tools = harness.registry.preferences.filter { BuiltinCatalog.sidebarTools.contains($0.id) }
        #expect(tools.map(\.id).prefix(3) == [BuiltinCatalog.lyrics, BuiltinCatalog.voice, BuiltinCatalog.screenshots])
        #expect(harness.registry.preferences.first { $0.id == BuiltinCatalog.lyrics }?.enabled == false)
        #expect(harness.registry.preferences.firstIndex { $0.id == BuiltinCatalog.desktop } == before.firstIndex { $0.id == BuiltinCatalog.desktop })
        let saved = harness.registry.preferences
        harness.registry.restore(saved)
        #expect(harness.registry.preferences == saved)
        try harness.registry.move(BuiltinCatalog.voice, before: nil)
        #expect(harness.registry.preferences.filter { BuiltinCatalog.sidebarTools.contains($0.id) }.last?.id == BuiltinCatalog.voice)
        #expect(throws: RegistryError.coreOrderLocked) { try harness.registry.move(BuiltinCatalog.voice, before: BuiltinCatalog.desktop) }
        #expect(throws: RegistryError.unknownModule) { try harness.registry.move("missing", before: nil) }
    }

    @Test func onlyUserContentCreatesLibraryDestinations() {
        let entries = BuiltinCatalog.productManifests
        #expect(entries.first { $0.id == BuiltinCatalog.voice }?.capabilities.library == .voice)
        #expect(entries.first { $0.id == BuiltinCatalog.screenshots }?.capabilities.library == .screenshots)
        #expect(entries.first { $0.id == BuiltinCatalog.lyrics }?.capabilities.library == nil)
        #expect(entries.first { $0.id == BuiltinCatalog.desktop }?.capabilities.library == nil)
        #expect(entries.allSatisfy { !$0.summary.isEmpty })
    }
}
