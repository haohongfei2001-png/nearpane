import Foundation
import Testing
@testable import NearpaneCore

@MainActor @Suite struct ModuleWorkbenchTests {
    @Test func everyShippedModuleCanMoveAcrossTheWholePersistedOrder() throws {
        let harness = RegistryHarness()
        for manifest in BuiltinCatalog.productManifests {
            try harness.registry.register(manifest) { TrackingModule() }
        }
        let enabledBefore = Dictionary(uniqueKeysWithValues: harness.registry.preferences.map { ($0.id, $0.enabled) })
        try harness.registry.move(BuiltinCatalog.lyrics, before: BuiltinCatalog.voice)
        #expect(harness.registry.preferences.map(\.id).prefix(3) == [BuiltinCatalog.lyrics, BuiltinCatalog.voice, BuiltinCatalog.screenshots])
        try harness.registry.move(BuiltinCatalog.desktop, before: BuiltinCatalog.lyrics)
        try harness.registry.move(BuiltinCatalog.clock, before: BuiltinCatalog.desktop)
        #expect(harness.registry.preferences.map(\.id).prefix(3) == [BuiltinCatalog.clock, BuiltinCatalog.desktop, BuiltinCatalog.lyrics])
        let saved = harness.registry.preferences
        harness.registry.restore(saved)
        #expect(harness.registry.preferences == saved)
        try harness.registry.move(BuiltinCatalog.voice, before: nil)
        #expect(harness.registry.preferences.last?.id == BuiltinCatalog.voice)
        try harness.registry.move(BuiltinCatalog.voice, before: BuiltinCatalog.desktop)
        #expect(harness.registry.preferences.map(\.id).prefix(3) == [BuiltinCatalog.clock, BuiltinCatalog.voice, BuiltinCatalog.desktop])
        #expect(Dictionary(uniqueKeysWithValues: harness.registry.preferences.map { ($0.id, $0.enabled) }) == enabledBefore)
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
