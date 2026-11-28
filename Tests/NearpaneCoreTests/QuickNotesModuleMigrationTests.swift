import Foundation
import Testing
@testable import NearpaneCore

@MainActor struct QuickNotesModuleMigrationTests {
    @Test func legacyModulesMergeAtTheirFirstPositionAndPreserveEveryOtherPreference() {
        let leading = ModulePreference(id: BuiltinCatalog.clock, enabled: true, pinned: false)
        let between = ModulePreference(id: "future.module", enabled: false, pinned: false)
        let trailing = ModulePreference(id: BuiltinCatalog.voice, enabled: false)
        let legacy = [leading, .init(id: BuiltinCatalog.tasks, enabled: true, pinned: false), between,
                      .init(id: BuiltinCatalog.memo, enabled: false, pinned: true), trailing]
        let migrated = QuickNotesModuleMigration.merge(legacy)
        #expect(migrated == [leading, .init(id: BuiltinCatalog.memo, enabled: true, pinned: true), between, trailing])
        #expect(QuickNotesModuleMigration.merge(migrated) == migrated)
    }

    @Test func disabledAndUnpinnedIntentSurvivesConsolidation() {
        let disabled = [ModulePreference(id: BuiltinCatalog.memo, enabled: false, pinned: false),
                        .init(id: BuiltinCatalog.tasks, enabled: false, pinned: false)]
        #expect(QuickNotesModuleMigration.merge(disabled) == [.init(id: BuiltinCatalog.memo, enabled: false, pinned: false)])
        let onlyTask = [ModulePreference(id: BuiltinCatalog.tasks, enabled: true, pinned: false)]
        #expect(QuickNotesModuleMigration.merge(onlyTask) == [.init(id: BuiltinCatalog.memo, enabled: true, pinned: false)])
    }

    @Test func freshInstallationCanRecordImmediatelyWithoutRegisteringTwoWritingRuntimes() async {
        let host = HostSession(store: MemoryConfigurationStore(), includeSampleModules: false)
        await host.start()
        #expect(host.registry.preferences.first { $0.id == BuiltinCatalog.memo }?.enabled == true)
        #expect(host.registry.states[BuiltinCatalog.memo] == .resident)
        #expect(host.registry.states[BuiltinCatalog.tasks] == nil)
        #expect(host.registry.preferences.map(\.id) == [BuiltinCatalog.voice, BuiltinCatalog.screenshots,
            BuiltinCatalog.memo, BuiltinCatalog.clock, BuiltinCatalog.desktop])
        #expect(BuiltinCatalog.sidebarTools.filter { $0 == BuiltinCatalog.memo }.count == 1)
        #expect(!BuiltinCatalog.sidebarTools.contains(BuiltinCatalog.tasks))
        host.stop()
    }

    @Test func upgradeWithoutWritingModulesDoesNotEnableAnotherModule() async {
        var configuration = HostConfiguration()
        configuration.modules = [.init(id: BuiltinCatalog.desktop, enabled: false),
                                 .init(id: BuiltinCatalog.voice, enabled: true)]
        let host = HostSession(store: MemoryConfigurationStore(configuration), includeSampleModules: false)
        await host.start()
        #expect(host.registry.preferences.first { $0.id == BuiltinCatalog.memo }?.enabled == false)
        #expect(host.registry.preferences.prefix(2) == configuration.modules.prefix(2))
        #expect(host.registry.states[BuiltinCatalog.memo] == .disabled)
        host.stop()
    }

    @Test func migrationIsPersistedAndLaterDisablingCannotResurrectLegacyTasks() async {
        var configuration = HostConfiguration()
        configuration.modules = [.init(id: BuiltinCatalog.screenshots, enabled: false),
                                 .init(id: BuiltinCatalog.tasks, enabled: true),
                                 .init(id: BuiltinCatalog.desktop, enabled: false),
                                 .init(id: BuiltinCatalog.memo, enabled: false),
                                 .init(id: BuiltinCatalog.voice, enabled: false)]
        let store = MemoryConfigurationStore(configuration)
        let host = HostSession(store: store, includeSampleModules: false)
        await host.start()
        #expect(store.value.modules == QuickNotesModuleMigration.merge(configuration.modules))
        #expect(host.registry.states[BuiltinCatalog.memo] == .resident)
        #expect(host.handle(.setEnabled(BuiltinCatalog.memo, false)) == .accepted)
        #expect(!store.value.modules.contains { $0.id == BuiltinCatalog.tasks })
        host.stop()
        await host.start()
        #expect(host.registry.states[BuiltinCatalog.memo] == .disabled)
        #expect(host.registry.states[BuiltinCatalog.tasks] == nil)
        #expect(host.registry.preferences.prefix(4).map(\.id) == [BuiltinCatalog.screenshots, BuiltinCatalog.memo,
            BuiltinCatalog.desktop, BuiltinCatalog.voice])
        host.stop()
    }

    @Test func migrationKeepsRetiredSampleSlotsWhenNewPreferencesAreSaved() async {
        var configuration = HostConfiguration()
        let retired = ModulePreference(id: BuiltinCatalog.notes, enabled: true, pinned: false)
        configuration.modules = [.init(id: BuiltinCatalog.tasks, enabled: true), retired,
                                 .init(id: BuiltinCatalog.memo, enabled: false),
                                 .init(id: BuiltinCatalog.clock, enabled: true),
                                 .init(id: BuiltinCatalog.desktop, enabled: false)]
        let store = MemoryConfigurationStore(configuration)
        let host = HostSession(store: store, includeSampleModules: false)
        await host.start()
        #expect(host.handle(.setEnabled(BuiltinCatalog.memo, false)) == .accepted)
        #expect(store.value.modules[1] == retired)
        #expect(store.value.modules.filter { $0.id == BuiltinCatalog.memo }.count == 1)
        #expect(store.value.modules[2].id == BuiltinCatalog.clock)
        host.stop()
    }
}
