import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor struct WindowAdmissionSettingsTests {
    private final class Reader: AdmissionReading {
        let app = AdmissionApplication(pid: 52, launch: 8, bundle: "test.fixture", name: "合成应用")
        var row = AdmissionWindowChoice(id: UUID(), number: 123, index: 1)
        var enumerations = 0, inspections = 0
        var list: ((AdmissionApplication) async -> [AdmissionWindowChoice])?
        var refresh: (() async -> [AdmissionWindowChoice])?
        var read: (([AdmissionWindowChoice]) async -> [AdmissionPair])?
        func applications() -> [AdmissionApplication] { enumerations += 1; return [app] }
        func windows(_ app: AdmissionApplication) async throws -> [AdmissionWindowChoice] {
            if let list { return await list(app) }
            return [row]
        }
        func refreshedWindows(_ app: AdmissionApplication) async throws -> [AdmissionWindowChoice]? {
            await refresh?()
        }
        func inspect(_ app: AdmissionApplication, selected: [AdmissionWindowChoice]) async throws -> [AdmissionPair] {
            inspections += 1
            if let read { return await read(selected) }
            return []
        }
        func safeguards(_ app: AdmissionApplication) -> AdmissionSafeguards { .init(exclusive:nil,recoveryClear:nil) }
    }

    @Test func liveSiblingsStayUnselectedAndReusedNumberInvalidatesOnlyItsOriginalPick() async {
        let reader = Reader(), sibling = AdmissionWindowChoice(id: UUID(), number: 456, index: 1)
        let selection = AdmissionSelection(reader: reader)
        selection.open()
        await selection.select(reader.app)
        selection.toggle(reader.row)
        let reordered = AdmissionWindowChoice(id: reader.row.id, number: reader.row.number, index: 2)
        reader.refresh = { [sibling, reordered] }
        #expect(await selection.refresh(reader.app))
        #expect(selection.choices == [sibling,reordered] && selection.picks.map(\.choice.id) == [reader.row.id])
        selection.toggle(sibling)
        let replacement = AdmissionWindowChoice(id: UUID(), number: reader.row.number, index: 2)
        reader.refresh = { [sibling, replacement] }
        #expect(await selection.refresh(reader.app))
        #expect(selection.picks.map(\.choice.id) == [sibling.id] && selection.failure != nil)
        #expect(reader.inspections == 0 && selection.ordinaryReview == nil)
    }

    @Test func staleLiveRefreshCannotRestoreClosedSettingsSelection() async {
        let reader = Reader()
        let active = AdmissionSelection(reader: reader)
        active.open()
        await active.select(reader.app)
        var done: CheckedContinuation<[AdmissionWindowChoice], Never>?
        reader.refresh = { await withCheckedContinuation { done = $0 } }
        let refreshing = Task { await active.refresh(reader.app) }
        while done == nil { await Task.yield() }
        active.close()
        done?.resume(returning: [reader.row])
        #expect(await refreshing.value == false)
        #expect(active.choices.isEmpty && active.app == nil)
    }

    @Test func listingAndPickingNeverInspectAndRebuiltChoicesDoNotInheritSelection() async {
        let reader = Reader()
        let scope = AdmissionSelection(reader: reader)
        #expect(reader.enumerations == 0 && scope.apps.isEmpty)
        scope.open()
        #expect(reader.enumerations == 1 && scope.choices.isEmpty)
        await scope.select(reader.app)
        let original = reader.row
        scope.toggle(original)
        #expect(scope.picks.map(\.choice) == [original])
        #expect(reader.inspections == 0)
        reader.row = AdmissionWindowChoice(id: UUID(), number: original.number, index: original.index)
        await scope.select(reader.app)
        scope.toggle(original)
        #expect(scope.picks.isEmpty && scope.choices == [reader.row])
        scope.toggle(reader.row)
        scope.close()
        #expect(scope.apps.isEmpty && scope.app == nil && scope.choices.isEmpty && scope.picks.isEmpty)
        #expect(reader.inspections == 0 && scope.result == nil)
    }

    @Test func removingWindowDuringDetailReadDiscardsThatResult() async {
        let reader = Reader()
        let scope = AdmissionSelection(reader: reader)
        let host = HostSession(store: MemoryConfigurationStore())
        scope.open()
        await scope.select(reader.app)
        scope.toggle(reader.row)
        var completion: CheckedContinuation<[AdmissionPair], Never>?
        let (started, signal) = AsyncStream<Void>.makeStream()
        reader.read = { choices in
            #expect(choices == [reader.row])
            return await withCheckedContinuation {
                completion = $0
                signal.yield(())
            }
        }
        let reading = Task { await scope.inspect(host: host, blocked: false, scenario: .current, ratio: 0.5, swap: false, custom: false) }
        for await _ in started { break }
        scope.toggle(reader.row)
        completion?.resume(returning: [])
        await reading.value
        #expect(scope.picks.isEmpty && !scope.reading && scope.result == nil && scope.failure == nil)
        #expect(reader.inspections == 1)
        reader.read = nil
    }

    @Test func closedPreviewDiscardsDelayedDiscoveryAndStaleButtonActions() async {
        let reader = Reader()
        let scope = AdmissionSelection(reader: reader)
        scope.open()
        var continuation: CheckedContinuation<[AdmissionWindowChoice], Never>?
        let (started, signal) = AsyncStream<Void>.makeStream()
        reader.list = { _ in
            await withCheckedContinuation {
                continuation = $0
                signal.yield(())
            }
        }
        let listing = Task { await scope.select(reader.app) }
        for await _ in started { break }
        scope.close()
        continuation?.resume(returning: [reader.row])
        await listing.value
        #expect(!scope.reading && scope.app == nil && scope.choices.isEmpty)
        // A queued control event delivered after the preview closed cannot reopen discovery.
        await scope.select(reader.app)
        scope.toggle(reader.row)
        #expect(scope.picks.isEmpty && scope.choices.isEmpty && reader.inspections == 0)
    }
}
