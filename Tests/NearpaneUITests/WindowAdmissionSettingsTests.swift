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
        var retained: ManagedWindowID?
        func retainedRuleID(_ choice: AdmissionWindowChoice, app: AdmissionApplication) -> ManagedWindowID? { retained }
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

    @Test func screenshotConsentRevokesOnSameNumberReplacementAndWhileRefreshingAWithdrawnSelection() async throws {
        let reader = Reader(), selection = AdmissionSelection(reader: reader)
        selection.open()
        await selection.select(reader.app)
        let original = reader.row
        reader.retained = ManagedWindowID(pid: reader.app.pid, launch: reader.app.launch,
            number: try #require(original.number), element: original.id)
        selection.toggle(original)
        let id = try #require(selection.ruleID)
        let consent = selection.previewConsent(for: id, owner: reader.app)
        reader.refresh = { [original] in [original] }
        #expect(await consent())
        let sibling = AdmissionWindowChoice(id: UUID(), number: original.number, index: 1)
        reader.refresh = { [sibling] in [sibling] }
        #expect(await !consent())
        reader.refresh = { [original, sibling] in [original, sibling] }
        #expect(await !consent())
        reader.refresh = { [weak selection] in
            selection?.close()
            return [original]
        }
        #expect(await !consent())
    }

    @Test func applicationPickerUsesPackageIdentityInsteadOfItsFilename() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("随意改名.app")
        let contents = app.appendingPathComponent("Contents")
        let exe = contents.appendingPathComponent("MacOS")
        try fm.createDirectory(at: exe, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let plist = ["CFBundlePackageType":"APPL", "CFBundleExecutable":"test-fixture",
                     "CFBundleIdentifier":"org.example.settings-fixture"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let binary = exe.appendingPathComponent("test-fixture")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: binary)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        #expect(WorkspacePolicySettings.exclusionIdentifier(at: app) == "org.example.settings-fixture")
        #expect(WorkspacePolicySettings.exclusionIdentifier(at: binary) == nil)
        #expect(WorkspacePolicySettings.exclusionIdentifier(at: root.appendingPathComponent("absent.app")) == nil)
    }

    @Test func rulesRequireFreshRetainedIdentityAndNeverStartManagement() async {
        let reader = Reader(), selection = AdmissionSelection(reader: reader)
        let store = MemoryConfigurationStore(), host = HostSession(store: store)
        await host.start()
        defer { host.stop() }
        let persisted = ManagedWindowID(pid: 318, launch: 33, number: 5, element: UUID())
        var prefs = host.workspacePreferencesDraft
        prefs.excludedApps.insert(reader.app.bundle)
        prefs.windows[persisted] = .exclude
        #expect(host.setWorkspacePreferences(prefs))
        selection.open()
        await selection.select(reader.app)
        selection.toggle(reader.row)
        let id = ManagedWindowID(pid: reader.app.pid, launch: reader.app.launch, number: 123, element: reader.row.id)
        reader.refresh = { [reader.row] }
        await selection.setRule(.include, host: host, isManaged: { _ in false })
        #expect(host.workspacePreferencesDraft == prefs)
        reader.retained = id
        await selection.setRule(.include, host: host, isManaged: { _ in true })
        #expect(host.workspacePreferencesDraft == prefs)
        reader.refresh = { [.init(id: UUID(), number: id.number, index: 1)] }
        await selection.setRule(.include, host: host, isManaged: { _ in false })
        #expect(host.workspacePreferencesDraft == prefs)
        reader.refresh = { [reader.row] }
        await selection.setRule(.include, host: host, isManaged: { _ in false })
        #expect(host.workspacePreferencesDraft.windows == [persisted:.exclude, id:.include])
        #expect(host.workspacePreferencesDraft.excludedApps == [reader.app.bundle])
        await selection.setRule(.exclude, host: host, isManaged: { _ in false })
        #expect(host.workspacePreferencesDraft.windows == [persisted:.exclude, id:.exclude])
        #expect(reader.inspections == 0 && selection.ordinaryReview == nil)
    }

    @Test func lateWindowRuleCannotUndoRevocationOrOverridePriorIncarnation() async {
        let reader = Reader(), selection = AdmissionSelection(reader: reader)
        let host = HostSession(store: MemoryConfigurationStore())
        await host.start()
        defer { host.stop() }
        selection.open()
        await selection.select(reader.app)
        selection.toggle(reader.row)
        let id = ManagedWindowID(pid: reader.app.pid, launch: reader.app.launch, number: 123, element: reader.row.id)
        let prior = ManagedWindowID(pid: id.pid, launch: id.launch, number: id.number, element: UUID())
        var prefs = host.workspacePreferencesDraft
        prefs.windows[prior] = .exclude
        prefs.excludedApps.insert(reader.app.bundle)
        #expect(host.setWorkspacePreferences(prefs))
        reader.retained = id
        reader.refresh = { [reader.row] }
        await selection.setRule(.include, host: host, isManaged: { _ in false })
        #expect(host.workspacePreferencesDraft == prefs && selection.failure != nil)
        reader.refresh = { selection.close(); return [reader.row] }
        await selection.setRule(.exclude, host: host, isManaged: { _ in false })
        #expect(host.workspacePreferencesDraft == prefs && selection.picks.isEmpty)
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

    @Test func reportedGrantRefreshesOnlyAnOpenDeniedListingWithoutSelectingOrManagingWindows() async {
        let reader = Reader(), selection = AdmissionSelection(reader: reader)
        selection.open()
        reader.listingFailure = .permission
        await selection.select(reader.app)
        reader.listingFailure = nil
        let other = AdmissionApplication(pid: reader.app.pid, launch: reader.app.launch + 1, bundle: reader.app.bundle, name: reader.app.name)
        await selection.recheckListingAfterGrant(other)
        #expect(selection.permissionDenied && selection.choices.isEmpty)
        await selection.recheckListingAfterGrant(reader.app)
        #expect(!selection.permissionDenied && selection.choices == [reader.row])
        #expect(selection.picks.isEmpty && reader.inspections == 0)
        selection.close()
        await selection.recheckListingAfterGrant(reader.app)
        #expect(selection.app == nil && selection.choices.isEmpty)
    }

    @Test func expiredOrdinaryPreviewWithdrawsConfirmationWithoutClearingSelectedWindows() async throws {
        // Each deadline is delivered explicitly, including a cancelled timer whose wait
        // already completed and whose continuation reaches the main actor late.
        let waits = AsyncStream<(TimeInterval, CheckedContinuation<Void, Never>)>.makeStream()
        defer { waits.continuation.finish() }
        var deadlines = waits.stream.makeAsyncIterator()
        let reader = Reader()
        let selection = AdmissionSelection(reader: reader, waitForExpiry: { deadline in
            await withCheckedContinuation { waits.continuation.yield((deadline, $0)) }
        })
        selection.open()
        await selection.select(reader.app)
        selection.toggle(reader.row)
        var released = 0
        selection.cancelOrdinaryPreview = { released += 1 }
        let rect = SurfaceRect(width: 800, height: 600)
        let context = AdmissionContext(display: "test", screen: rect, usable: rect, primary: true,
                                      settings: .init(), edge: .right, preferences: .init(), recoveryClear: true, exclusive: true)
        let expired = OrdinaryWindowReview(token: UUID(), display: "test", validUntil: 100, current: [:], proposed: [:])
        let first = selection.present(expired, context: context)
        let expiry = try #require(await deadlines.next())
        #expect(expiry.0 == expired.validUntil && !selection.expired)
        expiry.1.resume()
        await first.value
        #expect(selection.expired && selection.ordinaryReview == nil && selection.ordinaryContext == nil)
        #expect(released == 1 && selection.picks.first?.choice.id == reader.row.id)

        selection.invalidate()
        let replaced = selection.present(expired, context: context)
        let late = try #require(await deadlines.next())
        let current = OrdinaryWindowReview(token: UUID(), display: "test", validUntil: 160, current: [:], proposed: [:])
        let replacement = selection.present(current, context: context)
        let future = try #require(await deadlines.next())
        #expect(late.0 == expired.validUntil && future.0 == current.validUntil)
        late.1.resume()
        await replaced.value
        #expect(!selection.expired && selection.ordinaryReview?.token == current.token && released == 2)

        selection.close()
        future.1.resume()
        await replacement.value
        #expect(!selection.expired && released == 3 && selection.picks.isEmpty)
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
