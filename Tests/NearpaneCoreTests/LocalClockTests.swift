import Foundation
import Testing
@testable import NearpaneCore

@MainActor struct LocalClockTests {
    @Test func productCatalogStartsWithoutOptionalModulesAndLegacySamplesCannotRun() async throws {
        let store = MemoryConfigurationStore()
        let host = HostSession(store: store, includeSampleModules: false)
        await host.start()
        #expect(host.registry.manifests.map(\.id) == [BuiltinCatalog.voice, BuiltinCatalog.screenshots, BuiltinCatalog.desktop, BuiltinCatalog.clock])
        #expect(host.registry.pinnedModules.isEmpty)
        #expect(host.handle(.setEnabled(BuiltinCatalog.calendar, true)) != .accepted)
        #expect(host.permissions.requests.isEmpty)
        #expect(host.handle(.setEnabled(BuiltinCatalog.clock, true)) == .accepted)
        let before = Date.now
        #expect(host.handle(.module(BuiltinCatalog.clock, .refresh)) == .accepted)
        let snapshot = try #require(host.bus.moduleSnapshots[BuiltinCatalog.clock]?.snapshot)
        #expect([LocalClock.time(before), LocalClock.time(.now)].contains(snapshot.message))
        #expect(host.handle(.expand(BuiltinCatalog.clock)) == .accepted)
        host.handle(.collapse)
        host.stop()
    }

    @Test func legacyOrderingAndExtraZoneSurviveRestartWithoutRevivingUnavailableSamples() async throws {
        let store = MemoryConfigurationStore()
        var config = HostConfiguration()
        let oldNote = ModulePreference(id: BuiltinCatalog.notes, enabled: true)
        let oldCalendar = ModulePreference(id: BuiltinCatalog.calendar, enabled: true, pinned: false)
        config.modules = [.init(id: BuiltinCatalog.voice, enabled: true),
                          .init(id: BuiltinCatalog.screenshots, enabled: true),
                          .init(id: BuiltinCatalog.desktop, enabled: true), oldNote,
                          .init(id: BuiltinCatalog.clock, enabled: true), oldCalendar]
        try store.save(config)
        let host = HostSession(store: store, includeSampleModules: false)
        await host.start()
        #expect(host.registry.pinnedModules.map(\.id) == [BuiltinCatalog.clock])
        var presentations = 0
        host.presentationChanged = { presentations += 1 }
        host.setClockTimeZone("Asia/Shanghai")
        #expect(presentations == 0)
        host.setClockTimeZone("Invalid/Zone")
        host.handle(.setPinned(BuiltinCatalog.clock, false))
        #expect(store.value.modules.map(\.id) == config.modules.map(\.id))
        #expect(store.value.modules.contains(oldNote) && store.value.modules.contains(oldCalendar))
        host.stop()
        await host.start()
        #expect(host.configuration.clockTimeZoneID == "Asia/Shanghai")
        #expect(host.registry.pinnedModules.isEmpty && host.registry.states[BuiltinCatalog.clock] == .resident)
        #expect(host.registry.states[BuiltinCatalog.notes] == nil)
        host.setClockTimeZone(nil)
        #expect(store.value.clockTimeZoneID == nil)
        host.stop()
    }

    @Test func clockFormatsTheSameInstantForDifferentZonesAndTheirDaylightSavingRules() throws {
        let utc = try #require(TimeZone(identifier: "Etc/UTC"))
        let york = try #require(TimeZone(identifier: "America/New_York"))
        let locale = Locale(identifier: "en_GB")
        let format = ISO8601DateFormatter()
        let winter = try #require(format.date(from: "2026-01-15T12:34:00Z"))
        let summer = try #require(format.date(from: "2026-07-15T12:34:00Z"))
        #expect(LocalClock.time(winter, zone: utc, locale: locale) == "12:34")
        #expect(LocalClock.time(winter, zone: york, locale: locale) ==
                LocalClock.time(winter.addingTimeInterval(-5 * 3600), zone: utc, locale: locale))
        #expect(LocalClock.time(summer, zone: york, locale: locale) ==
                LocalClock.time(summer.addingTimeInterval(-4 * 3600), zone: utc, locale: locale))
    }
}
