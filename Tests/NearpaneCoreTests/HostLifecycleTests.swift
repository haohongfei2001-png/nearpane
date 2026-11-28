import Foundation
import Testing
@testable import NearpaneCore

@MainActor
@Suite(.serialized)
struct HostLifecycleTests {
    @Test func sameSessionRestartReadsDefaultsAndDropsOldSubscriptionsAndGrants() async throws {
        let store = MemoryConfigurationStore()
        let host = HostSession(store: store)
        await host.start()
        host.handle(.setEnabled(BuiltinCatalog.calendar, true))
        let key = PermissionKey(moduleID: BuiltinCatalog.calendar, permission: .calendarRead)
        host.permissions.setDecision(.granted, for: key)
        host.handle(.module(BuiltinCatalog.calendar, .refresh))
        var oldDeliveries = 0
        _ = host.bus.subscribe(moduleIDs: [BuiltinCatalog.voice]) { _ in oldDeliveries += 1 }
        host.stop()
        try store.save(.init())
        await host.start()
        #expect(host.registry.states[BuiltinCatalog.calendar] == .disabled)
        #expect(host.permissions.decision(for: key) == .notRequested)
        #expect(host.permissions.requests.isEmpty)
        #expect(host.lastAction == nil)
        #expect(oldDeliveries == 0)
        host.stop()
    }
    @Test func testStartStopAreIdempotentAndRestorePreferencesWithFreshRuntimeIDs() async throws {
        let store = MemoryConfigurationStore()
        let host = HostSession(store: store)
        await host.start(); await host.start()
        #expect(host.diagnostics.records.filter { $0.code == .hostStarted }.count == 1)
        host.handle(.setEnabled(BuiltinCatalog.notes, true))
        host.handle(.setEnabled(BuiltinCatalog.clock, true))
        host.handle(.move(BuiltinCatalog.clock, -1))
        host.handle(.setPinned(BuiltinCatalog.clock, false))
        host.handle(.expand(BuiltinCatalog.notes))
        let old = try #require(host.bus.moduleSnapshots[BuiltinCatalog.notes])
        host.stop(); host.stop()
        #expect(!(host.isRunning))
        #expect(host.bus.moduleSnapshots.isEmpty)
        #expect(host.bus.desktop == nil)
        let restored = HostSession(store: store)
        await restored.start()
        #expect(restored.registry.preferences == store.value.modules)
        #expect(restored.bus.moduleSnapshots[BuiltinCatalog.notes]?.instanceID != old.instanceID)
        #expect(restored.registry.expandedID == nil)
        #expect(restored.permissions.decisions.isEmpty)
        restored.stop()
    }

    @Test func testStoppedHostRejectsActions() async {
        let host = HostSession(store: MemoryConfigurationStore())
        #expect(host.handle(.setEnabled(BuiltinCatalog.notes, true)) == .rejected(.hostStopped))
    }

    @Test func testProviderFailureDoesNotStopModulesAndRetainsLastKnownSnapshot() async {
        let provider = ToggleFailureProvider()
        let host = HostSession(store: MemoryConfigurationStore(), provider: provider)
        await host.start()
        let stable = host.bus.desktop
        provider.shouldFail = true
        await host.refreshDesktop()
        #expect(host.providerFailed)
        #expect(host.bus.desktop == stable)
        #expect(host.isRunning)
        #expect(host.registry.states[BuiltinCatalog.voice] == .resident)
        host.stop()
    }

    @Test func testSnapshotCompletingAfterShutdownIsIgnored() async throws {
        let provider = DeferredProvider()
        let host = HostSession(store: MemoryConfigurationStore(), provider: provider)
        let start = Task { await host.start() }
        try await provider.awaitRequests(1)
        host.stop()
        provider.complete(index: 0, revision: 1)
        await start.value
        #expect(host.bus.desktop == nil)
        #expect(!(host.isRunning))
    }

    @Test func testOlderConcurrentRefreshCannotReplaceNewerResult() async throws {
        let provider = DeferredProvider()
        let host = HostSession(store: MemoryConfigurationStore(), provider: provider)
        let first = Task { await host.start() }
        try await provider.awaitRequests(1)
        let second = Task { await host.refreshDesktop() }
        try await provider.awaitRequests(2)
        provider.complete(index: 1, revision: 2)
        await second.value
        provider.complete(index: 0, revision: 1)
        await first.value
        #expect(host.bus.desktop?.revision == 2)
        host.stop()
    }

    @Test func testFixtureSelectionPersistsAndTransientRetainsStableData() async {
        let store = MemoryConfigurationStore()
        let host = HostSession(store: store)
        await host.start()
        let stable = host.bus.desktop
        await host.selectFixture(.transient)
        #expect(host.bus.lastStableDesktop == stable)
        #expect(host.bus.desktop?.freshness == .transient)
        #expect(store.value.fixture == .transient)
        host.stop()
    }

    @Test func testDisablingDesktopInvalidatesInFlightObservation() async throws {
        let provider = DeferredProvider()
        let host = HostSession(store: MemoryConfigurationStore(), provider: provider)
        let start = Task { await host.start() }
        try await provider.awaitRequests(1)
        host.handle(.setEnabled(BuiltinCatalog.desktop, false))
        provider.complete(index: 0, revision: 1)
        await start.value
        #expect(host.bus.desktop == nil)
        #expect(host.registry.states[BuiltinCatalog.desktop] == .disabled)
        host.stop()
    }
}

@MainActor
private final class ToggleFailureProvider: DesktopObservationProvider {
    var shouldFail = false
    let capabilities = DesktopCapabilities()
    let session = UUID()
    func snapshot() async throws -> DesktopSnapshot {
        if shouldFail { throw SampleFailure.injected }
        return DesktopFixture.singleDisplay.makeSnapshot(sessionID: session)
    }
}

@MainActor
private final class DeferredProvider: DesktopObservationProvider {
    let capabilities = DesktopCapabilities()
    let session = UUID()
    var waiters: [CheckedContinuation<DesktopSnapshot, any Error>?] = []
    func snapshot() async throws -> DesktopSnapshot {
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func complete(index: Int, revision: UInt64) {
        waiters[index]?.resume(returning: DesktopFixture.singleDisplay.makeSnapshot(revision: revision, sessionID: session))
        waiters[index] = nil
    }
    func awaitRequests(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while waiters.count < count && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(waiters.count >= count)
    }
}
