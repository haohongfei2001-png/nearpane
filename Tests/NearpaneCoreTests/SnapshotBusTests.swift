import Foundation
import Testing
@testable import NearpaneCore

@MainActor
@Suite(.serialized)
struct SnapshotBusTests {
    @Test func testOutOfOrderEventsCannotReplaceSnapshot() async {
        let bus = SnapshotBus(diagnostics: Diagnostics())
        let instance = UUID()
        bus.activate(moduleID: "a", instanceID: instance)
        let event = ModuleEvent(moduleID: "a", instanceID: instance, revision: 2, snapshot: .init(message: "latest"))
        #expect(bus.publish(event))
        #expect(!(bus.publish(ModuleEvent(moduleID: "a", instanceID: instance, revision: 1, snapshot: .init(message: "old")))))
        #expect(!(bus.publish(event)))
        #expect(bus.moduleSnapshots["a"] == event)
    }

    @Test func testFailingSubscriberIsRemovedWithoutBlockingHealthyScopedSubscriber() async {
        let diagnostics = Diagnostics()
        let bus = SnapshotBus(diagnostics: diagnostics)
        let instance = UUID()
        bus.activate(moduleID: "a", instanceID: instance)
        var failureCalls = 0
        var received: [UInt64] = []
        _ = bus.subscribe(moduleIDs: ["a"]) { _ in failureCalls += 1; throw SampleFailure.injected }
        let healthy = bus.subscribe(moduleIDs: ["a"]) { received.append($0.revision) }
        _ = bus.subscribe(moduleIDs: ["other"]) { _ in Issue.record("Unrequested cross-module event") }
        for revision in UInt64(1)...3 {
            bus.publish(ModuleEvent(moduleID: "a", instanceID: instance, revision: revision, snapshot: .init(message: "synthetic")))
        }
        #expect(failureCalls == 1)
        #expect(received == [1, 2, 3])
        #expect(diagnostics.records.contains { $0.code == .subscriberFailed })
        bus.unsubscribe(healthy)
        bus.publish(ModuleEvent(moduleID: "a", instanceID: instance, revision: 4, snapshot: .init(message: "synthetic")))
        #expect(received == [1, 2, 3])
        #expect(bus.moduleSnapshots["a"]?.revision == 4)
    }

    @Test func testReentrantPublicationPreservesDeliveryOrder() async {
        let bus = SnapshotBus(diagnostics: Diagnostics())
        let instance = UUID()
        bus.activate(moduleID: "a", instanceID: instance)
        var revisions: [UInt64] = []
        _ = bus.subscribe(moduleIDs: ["a"]) { event in
            revisions.append(event.revision)
            if event.revision == 1 {
                bus.publish(ModuleEvent(moduleID: "a", instanceID: instance, revision: 2, snapshot: .init(message: "next")))
            }
        }
        bus.publish(ModuleEvent(moduleID: "a", instanceID: instance, revision: 1, snapshot: .init(message: "first")))
        #expect(revisions == [1, 2])
    }

    @Test func testDiagnosticsAreBoundedAndContainNoPayloadOrUnknownIDs() async throws {
        let diagnostics = Diagnostics(capacity: 3)
        let bus = SnapshotBus(diagnostics: diagnostics)
        for _ in 0..<10 {
            bus.publish(ModuleEvent(moduleID: "secret-user-content", instanceID: UUID(), revision: 1, snapshot: .init(message: "secret-transcript")))
        }
        #expect(diagnostics.records.count == 3)
        let text = String(decoding: try diagnostics.export(), as: UTF8.self)
        #expect(!(text.contains("secret")))
        #expect(text.contains("eventRejected"))
    }
}
