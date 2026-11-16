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
        var listingFailure: AdmissionReadFailure?
        var refresh: (() async -> [AdmissionWindowChoice])?
        var read: (([AdmissionWindowChoice]) async -> [AdmissionPair])?
        func applications() -> [AdmissionApplication] { enumerations += 1; return [app] }
        func windows(_ app: AdmissionApplication) async throws -> [AdmissionWindowChoice] {
            if let listingFailure { throw listingFailure }
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
        #expect(selection.picks.first?.choice.index == 2)
        selection.toggle(sibling)
        let replacement = AdmissionWindowChoice(id: UUID(), number: reader.row.number, index: 2)
        reader.refresh = { [sibling, replacement] }
        #expect(await selection.refresh(reader.app))
        #expect(selection.picks.map(\.choice.id) == [sibling.id] && selection.failure != nil)
        #expect(reader.inspections == 0 && selection.ordinaryReview == nil)
    }

    @Test func dailyWindowLabelsDistinguishInstancesAndNeverTransferReviewToReusedNumbers() async {
        let reader = Reader(), selection = AdmissionSelection(reader: reader)
        selection.open()
        let second = AdmissionApplication(pid: 82, launch: 22, bundle: reader.app.bundle, name: reader.app.name)
        #expect(selection.label(for: reader.app) == reader.app.name)
        selection.apps.append(second)
        #expect(selection.label(for: reader.app) == "合成应用（实例 1）")
        #expect(selection.label(for: second) == "合成应用（实例 2）")
        await selection.select(reader.app)
        selection.toggle(reader.row)
        let original = ManagedWindowID(pid: reader.app.pid, launch: reader.app.launch, number: 123, element: reader.row.id)
        #expect(selection.label(for: original, requireSameElement: true) == "合成应用（实例 1） · 窗口 1")
        let replacement = ManagedWindowID(pid: original.pid, launch: original.launch, number: original.number, element: UUID())
        #expect(selection.label(for: replacement, requireSameElement: true) == nil)
    }

    @Test func onlyConfirmedAccessibilityDenialOffersPermissionSettings() async {
        let reader = Reader(), selection = AdmissionSelection(reader: reader)
        selection.open()
        reader.listingFailure = .permission
        await selection.select(reader.app)
        #expect(selection.permissionDenied && selection.choices.isEmpty)
        reader.listingFailure = .unavailable
        await selection.select(reader.app)
        #expect(!selection.permissionDenied && selection.failure != nil)
        reader.listingFailure = nil
        await selection.select(reader.app)
        #expect(!selection.permissionDenied && selection.failure == nil)
    }

    @Test func expiredOrdinaryPreviewWithdrawsConfirmationWithoutClearingSelectedWindows() async throws {
        let reader = Reader(), selection = AdmissionSelection(reader: reader)
        selection.open()
        await selection.select(reader.app)
        selection.toggle(reader.row)
        var released = 0
        selection.cancelOrdinaryPreview = { released += 1 }
        let rect = SurfaceRect(width: 800, height: 600)
        let context = AdmissionContext(display: "test", screen: rect, usable: rect, primary: true,
                                      settings: .init(), edge: .right, preferences: .init(), recoveryClear: true, exclusive: true)
        let now = ProcessInfo.processInfo.systemUptime
        let expired = OrdinaryWindowReview(token: UUID(), display: "test", validUntil: now, current: [:], proposed: [:])
        selection.present(expired, context: context)
        let deadline = ContinuousClock.now + .seconds(1)
        while !selection.expired && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(selection.expired && selection.ordinaryReview == nil && selection.ordinaryContext == nil)
        #expect(released == 1 && selection.picks.first?.choice.id == reader.row.id)
        selection.invalidate()
        selection.present(expired, context: context)
        let current = OrdinaryWindowReview(token: UUID(), display: "test", validUntil: now + 60, current: [:], proposed: [:])
        selection.present(current, context: context)
        try await Task.sleep(for: .milliseconds(10))
        #expect(!selection.expired && selection.ordinaryReview?.token == current.token && released == 2)
        selection.close()
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

    @Test func withdrawnSettingsClearPrivateSelectionAndNeverResumeListingWithoutANewChoice() async {
        let reader = Reader(), exposure = SettingsPreviewExposure()
        let scope = AdmissionSelection(reader: reader, exposure: exposure)
        var refreshes = 0
        reader.refresh = { refreshes += 1; return [reader.row] }
        func expose() { exposure.update(visible: true, miniaturized: false, appHidden: false, sessionUnavailable: false) }
        scope.open()
        #expect(reader.enumerations == 0 && !scope.opened)
        for reason in 0..<4 {
            expose()
            #expect(!scope.opened && scope.app == nil)
            scope.open()
            await scope.select(reader.app)
            scope.toggle(reader.row)
            #expect(await scope.refresh(reader.app))
            exposure.update(visible: reason != 0, miniaturized: reason == 1, appHidden: reason == 2, sessionUnavailable: reason == 3)
            #expect(!scope.opened && scope.app == nil && scope.choices.isEmpty && scope.picks.isEmpty)
            #expect(await !scope.refresh(reader.app))
            expose()
            await scope.select(reader.app)
            #expect(await !scope.refresh(reader.app))
            #expect(refreshes == reason + 1 && reader.enumerations == reason + 1)
        }
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
