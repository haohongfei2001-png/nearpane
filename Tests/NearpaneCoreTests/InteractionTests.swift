import Foundation
import Testing
@testable import NearpaneCore

@MainActor
@Suite(.serialized)
struct InteractionTests {
    @Test func testEnableDoesNotRequestPermissionsAndActionsRequireExplicitIntent() async throws {
        let h = RegistryHarness()
        let module = TrackingModule()
        try h.add("calendar", module: module, permissions: [.calendarRead])
        #expect(h.router.route(.setEnabled("calendar", true), userInitiated: false) == .rejected(.userIntentRequired))
        #expect(h.router.route(.setEnabled("calendar", true), userInitiated: true) == .accepted)
        #expect(h.broker.requests.isEmpty)
        #expect(h.router.route(.module("calendar", .refresh), userInitiated: true) == .rejected(.permissionRequired))
        #expect(module.actions == 0)
        #expect(h.registry.states["calendar"] == .permissionRequired)
        let key = PermissionKey(moduleID: "calendar", permission: .calendarRead)
        #expect(h.broker.requests == [key])
        h.broker.setDecision(.granted, for: key)
        #expect(h.router.route(.module("calendar", .refresh), userInitiated: true) == .accepted)
        #expect(module.actions == 1)
    }

    @Test func testPermissionGrantIsPerModuleAndDoesNotLeak() async throws {
        let h = RegistryHarness()
        try h.add("a", permissions: [.calendarRead]); try h.add("b", permissions: [.calendarRead])
        try h.registry.setEnabled("a", true); try h.registry.setEnabled("b", true)
        h.broker.setDecision(.granted, for: .init(moduleID: "a", permission: .calendarRead))
        #expect(h.router.route(.module("a", .refresh), userInitiated: true) == .accepted)
        #expect(h.router.route(.module("b", .refresh), userInitiated: true) == .rejected(.permissionRequired))
    }

    @Test func testPermissionRevocationStopsOnlyAffectedModule() async {
        let host = HostSession(store: MemoryConfigurationStore())
        await host.start()
        host.handle(.setEnabled(BuiltinCatalog.calendar, true))
        host.handle(.setEnabled(BuiltinCatalog.notes, true))
        let key = PermissionKey(moduleID: BuiltinCatalog.calendar, permission: .calendarRead)
        host.permissions.setDecision(.granted, for: key)
        #expect(host.handle(.module(BuiltinCatalog.calendar, .refresh)) == .accepted)
        host.permissions.setDecision(.denied, for: key)
        #expect(host.registry.states[BuiltinCatalog.calendar] == .degraded)
        #expect(host.registry.states[BuiltinCatalog.notes] == .resident)
        #expect(host.bus.moduleSnapshots[BuiltinCatalog.calendar] == nil)
        host.stop()
    }

    @Test func testDesktopTargetsFailClosedForEveryFixtureAndStaleIdentity() async {
        for fixture in DesktopFixture.allCases {
            let h = RegistryHarness()
            let snapshot = fixture.makeSnapshot()
            h.bus.acceptDesktop(snapshot)
            let target = DesktopTarget(sessionID: snapshot.sessionID, revision: snapshot.revision, runtimeID: snapshot.scopes[0].records[0].id)
            #expect(h.router.route(.switchSpace(target), userInitiated: true) != .accepted)
            #expect(h.router.route(.activateWindow(target), userInitiated: true) != .accepted)
            let expired = DesktopTarget(sessionID: UUID(), revision: 1, runtimeID: "reused-id")
            #expect(h.router.route(.activateWindow(expired), userInitiated: true) == .rejected(.staleSnapshot))
        }
    }

    @Test func testUnknownAndDisabledModulesCannotDispatch() async throws {
        let h = RegistryHarness()
        #expect(h.router.route(.module("unknown", .refresh), userInitiated: true) == .rejected(.unknownModule))
        try h.add("known")
        #expect(h.router.route(.module("known", .refresh), userInitiated: true) == .rejected(.moduleUnavailable))
    }
}
