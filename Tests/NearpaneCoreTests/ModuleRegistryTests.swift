import Foundation
import Testing
@testable import NearpaneCore

@MainActor
@Suite(.serialized)
struct ModuleRegistryTests {
    @Test func testEnableDisableIdempotenceAndPreferencesSurviveShutdown() async throws {
        let h = RegistryHarness()
        let runtime = TrackingModule()
        try h.add("a", module: runtime)
        #expect(h.registry.states["a"] == .available)
        try h.registry.setEnabled("a", true)
        try h.registry.setEnabled("a", true)
        #expect(runtime.starts == 1)
        #expect(h.registry.states["a"] == .resident)
        h.registry.stopAll()
        #expect(runtime.stops == 1)
        #expect(h.registry.preferences[0].enabled)
        #expect(h.bus.moduleSnapshots["a"] == nil)
        try h.registry.setEnabled("a", false)
        #expect(!(h.registry.preferences[0].enabled))
    }

    @Test func testRegistryRejectsDuplicateCoreReplacementAndIncompatibleManifest() async throws {
        let h = RegistryHarness()
        try h.add("core", kind: .core)
        #expect(throws: RegistryError.duplicateID) { try h.add("core") }
        #expect(throws: (any Error).self) { try h.registry.register(.init(id: "future", name: "Future", symbol: "circle", minimumHostVersion: 2)) { TrackingModule() } }
        #expect(throws: (any Error).self) { try h.registry.register(.init(id: "bad", name: "Bad", symbol: "circle", actions: [.refresh: [.location]])) { TrackingModule() } }
    }

    @Test func testRestoreOrderingPreservesCoreBoundaryAndIgnoresUnknownIDs() async throws {
        let h = RegistryHarness()
        try h.add("core", kind: .core)
        try h.add("a"); try h.add("b")
        h.registry.restore([.init(id: "b", enabled: true), .init(id: "unknown", enabled: true),
                            .init(id: "core", enabled: false), .init(id: "b", enabled: true)])
        #expect(h.registry.preferences.map(\.id) == ["core", "b", "a"])
        #expect(!(h.registry.preferences[0].enabled))
        #expect(throws: (any Error).self) { try h.registry.move("core", by: 1) }
        try h.registry.move("a", by: -1)
        #expect(h.registry.preferences.map(\.id) == ["core", "a", "b"])
    }

    @Test func testOnlyOneExpandedModuleAndCollapsePreservesRuntimeState() async throws {
        let h = RegistryHarness()
        try h.add("a"); try h.add("b")
        try h.registry.setEnabled("a", true); try h.registry.setEnabled("b", true)
        try h.registry.expand("a")
        try h.registry.perform(.refresh, on: "a")
        try h.registry.expand("b")
        #expect(h.registry.states["a"] == .resident)
        #expect(h.registry.expandedID == "b")
        h.registry.collapse()
        try h.registry.expand("a")
        #expect(h.bus.moduleSnapshots["a"]?.snapshot.refreshCount == 1)
        try h.registry.setPinned("a", false)
        #expect(h.registry.expandedID == nil)
        #expect(throws: (any Error).self) { try h.registry.expand("a") }
    }

    @Test func testDisabledModuleCannotExpandOrHandleActions() async throws {
        let h = RegistryHarness()
        let module = TrackingModule()
        try h.add("a", module: module)
        #expect(throws: (any Error).self) { try h.registry.expand("a") }
        #expect(throws: (any Error).self) { try h.registry.perform(.refresh, on: "a") }
        #expect(module.actions == 0)
    }

    @Test func testSuspendResumeRejectsOldPublicationEpoch() async throws {
        let h = RegistryHarness()
        let module = TrackingModule()
        try h.add("a", module: module)
        try h.registry.setEnabled("a", true)
        let old = try #require(h.bus.moduleSnapshots["a"])
        h.registry.suspend("a")
        #expect(h.registry.states["a"] == .suspended)
        #expect(h.bus.moduleSnapshots["a"] == nil)
        #expect(throws: (any Error).self) { try h.registry.perform(.refresh, on: "a") }
        h.registry.resume("a")
        #expect(module.suspends == 1)
        #expect(module.resumes == 1)
        #expect(h.bus.moduleSnapshots["a"]?.instanceID != old.instanceID)
        #expect(!(h.bus.publish(ModuleEvent(moduleID: "a", instanceID: old.instanceID, revision: 999, snapshot: old.snapshot))))
    }

    @Test func testThrownStartAndSnapshotFailuresAreIsolated() async throws {
        for failure in [TrackingModule.Failure.start, .snapshot] {
            let h = RegistryHarness()
            let bad = TrackingModule(failure: failure)
            try h.add("bad", module: bad); try h.add("healthy")
            try h.registry.setEnabled("healthy", true); try h.registry.setEnabled("bad", true)
            #expect(h.registry.states["bad"] == .degraded)
            #expect(bad.stops == 1)
            #expect(h.registry.states["healthy"] == .resident)
            #expect(h.bus.moduleSnapshots["healthy"] != nil)
            #expect(h.bus.moduleSnapshots["bad"] == nil)
        }
    }

    @Test func testThrownActionAndResumeFailuresAreIsolatedAndRestartable() async throws {
        let h = RegistryHarness()
        let bad = TrackingModule(failure: .action)
        try h.add("bad", module: bad); try h.add("healthy")
        try h.registry.setEnabled("healthy", true); try h.registry.setEnabled("bad", true)
        #expect(throws: (any Error).self) { try h.registry.perform(.refresh, on: "bad") }
        #expect(h.registry.states["bad"] == .degraded)
        bad.failure = nil
        try h.registry.setEnabled("bad", true)
        #expect(h.registry.states["bad"] == .resident)
        h.registry.suspend("bad")
        bad.failure = .resume
        h.registry.resume("bad")
        #expect(h.registry.states["bad"] == .degraded)
        #expect(h.registry.states["healthy"] == .resident)
    }

    @Test func testLateEventsCannotReviveDisabledOrRestartedModule() async throws {
        let h = RegistryHarness()
        try h.add("a"); try h.registry.setEnabled("a", true)
        let event = try #require(h.bus.moduleSnapshots["a"])
        try h.registry.setEnabled("a", false)
        #expect(!(h.bus.publish(event)))
        try h.registry.setEnabled("a", true)
        #expect(!(h.bus.publish(event)))
        #expect(h.bus.moduleSnapshots["a"]?.instanceID != event.instanceID)
    }
}
