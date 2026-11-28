import Foundation
import Testing
import NearpaneCore
@testable import NearpaneUI

@MainActor
struct ModuleSwitchCoordinatorTests {
    private func host() async -> HostSession {
        let value = HostSession(store: MemoryConfigurationStore(), includeSampleModules: false)
        await value.start()
        return value
    }
    private func enabled(_ host: HostSession) -> Bool {
        host.registry.preferences.contains { $0.id == BuiltinCatalog.desktop && $0.enabled }
    }
    private func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
    private func lane() -> NativeSidebarNavigation {
        NativeSidebarNavigation(beginUserActivity: { {} })
    }

    @Test func offWaitsForReturnProofAndCanBeEnabledAgain() async {
        let host = await host()
        defer { host.stop() }
        let navigation = lane()
        var entered = false
        var release: CheckedContinuation<Void, Never>?
        let switches = ModuleSwitchCoordinator(navigation: navigation) { current in
            entered = true
            await withCheckedContinuation { release = $0 }
            if !current() { throw CancellationError() }
        }
        switches.setEnabled(BuiltinCatalog.desktop, false, host: host, modules: nil)
        let started = await wait { entered }
        #expect(started)
        #expect(enabled(host))
        #expect(switches.changing.contains(BuiltinCatalog.desktop))
        release?.resume()
        let completed = await wait { !switches.changing.contains(BuiltinCatalog.desktop) }
        #expect(completed)
        #expect(!enabled(host))
        #expect(switches.issues[BuiltinCatalog.desktop] == nil)
        switches.setEnabled(BuiltinCatalog.desktop, true, host: host, modules: nil)
        #expect(enabled(host))
    }

    @Test func failurePreservesEnabledStateAndAllowsRetry() async {
        let host = await host()
        defer { host.stop() }
        let navigation = lane()
        var attempts = 0
        let switches = ModuleSwitchCoordinator(navigation: navigation) { _ in
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileReadNoPermission) }
        }
        switches.setEnabled(BuiltinCatalog.desktop, false, host: host, modules: nil)
        let first = await wait { !switches.changing.contains(BuiltinCatalog.desktop) }
        #expect(first)
        #expect(enabled(host))
        #expect(switches.issues[BuiltinCatalog.desktop] != nil)
        switches.setEnabled(BuiltinCatalog.desktop, false, host: host, modules: nil)
        let retried = await wait { !switches.changing.contains(BuiltinCatalog.desktop) }
        #expect(retried)
        #expect(!enabled(host))
        #expect(attempts == 2)
        #expect(switches.issues[BuiltinCatalog.desktop] == nil)
        switches.setEnabled(BuiltinCatalog.desktop, true, host: host, modules: nil)
        switches.setEnabled(BuiltinCatalog.desktop, false, host: host, modules: nil)
        let repeated = await wait { !switches.changing.contains(BuiltinCatalog.desktop) }
        #expect(repeated)
        #expect(!enabled(host))
        #expect(attempts == 3)
    }

    @Test func discardedLaneJobDoesNotLeavePermanentBusyState() async {
        let host = await host()
        defer { host.stop() }
        let navigation = lane()
        navigation.confirmDispatch = { false }
        var prepared = false
        let switches = ModuleSwitchCoordinator(navigation: navigation) { _ in prepared = true }
        switches.setEnabled(BuiltinCatalog.desktop, false, host: host, modules: nil)
        let settled = await wait { !switches.changing.contains(BuiltinCatalog.desktop) }
        #expect(settled)
        #expect(!prepared)
        #expect(enabled(host))
        #expect(switches.issues[BuiltinCatalog.desktop] != nil)
    }

    @Test func newerWindowIntentCancelsDisableBeforeCommit() async {
        let host = await host()
        defer { host.stop() }
        let navigation = lane()
        var prepared = false
        let switches = ModuleSwitchCoordinator(navigation: navigation) { _ in prepared = true }
        switches.setEnabled(BuiltinCatalog.desktop, false, host: host, modules: nil)
        navigation.submit(selection: false, stage: true) { _ in }
        let settled = await wait { !switches.changing.contains(BuiltinCatalog.desktop) }
        #expect(settled)
        #expect(!prepared)
        #expect(enabled(host))
    }

    @Test func otherToolsDoNotWaitForSpacesLane() async {
        let host = await host()
        defer { host.stop() }
        let navigation = lane()
        navigation.setDispatchAvailable(false)
        let switches = ModuleSwitchCoordinator(navigation: navigation) { _ in throw CancellationError() }
        switches.setEnabled(BuiltinCatalog.memo, true, host: host, modules: nil)
        #expect(host.registry.preferences.contains { $0.id == BuiltinCatalog.memo && $0.enabled })
        #expect(switches.changing.isEmpty)
        switches.setEnabled(BuiltinCatalog.desktop, false, host: host, modules: nil)
        #expect(enabled(host))
        #expect(switches.changing.isEmpty)
        #expect(switches.issues[BuiltinCatalog.desktop] != nil)
    }
}
