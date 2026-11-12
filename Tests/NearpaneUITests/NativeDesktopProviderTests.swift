import AppKit
import Darwin
import os
import Foundation
import NearpaneCore
import Testing
@testable import NearpaneUI

private func sample(_ request: DesktopReadRequest, status: SpaceReadStatus) -> DesktopSnapshot {
    let area = SurfaceRect(width: 800, height: 1200), now = Date(), t = ProcessInfo.processInfo.systemUptime
    return .observed(request, from: now, to: now, build: "test", topology: "one", consistent: true,
        separateSpaces: true, displays: [.init(id: "secondary", frame: area, rotationDegrees: 90, backingScale: 2, usable: area)],
        scopes: status == .observed ? [.init(id: "scope", displayID: "secondary", records: [.init(id: "8", isCurrent: true)])] : [],
        windows: [], evidence: .init(population: request.fixtureWindows == nil ? .workWindows : .markedFixture,
            accessibility: .denied, spaces: status, rows: [], windowLimitReached: false, beganUptime: t, endedUptime: t))
}

private actor Attempts {
    var modes: [Bool] = []
    func call(_ request: DesktopReadRequest) throws -> DesktopSnapshot {
        modes.append(request.experimentalSpaces)
        if request.experimentalSpaces { throw ReaderFailure.unavailable }
        return sample(request, status: .disabled)
    }
}

@MainActor private final class DelayedRead: LiveDesktopObservationProvider {
    let capabilities = DesktopCapabilities(observation: .readOnly)
    private(set) var waiting: CheckedContinuation<DesktopSnapshot, Never>?
    func snapshot(experimentalSpaces: Bool) async throws -> DesktopSnapshot {
        await withCheckedContinuation { waiting = $0 }
    }
    func finish() {
        let request = DesktopReadRequest(session: UUID(), revision: 1, parentPID: getpid(), fixtureWindows: nil, anchors: [], experimentalSpaces: false)
        waiting?.resume(returning: sample(request, status: .disabled)); waiting = nil
    }
}

@MainActor private final class CountingRead: LiveDesktopObservationProvider {
    let capabilities = DesktopCapabilities(observation: .readOnly)
    private(set) var reads = 0
    func snapshot(experimentalSpaces: Bool) async throws -> DesktopSnapshot {
        reads += 1
        return sample(.init(session: UUID(), revision: 1, parentPID: getpid(), fixtureWindows: nil,
                            anchors: [], experimentalSpaces: experimentalSpaces), status: .disabled)
    }
}

@MainActor struct NativeDesktopProviderTests {
    @Test func readerResolvesTheBundleRootButRejectsAnInternalHelperRedirect() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let app = root.appendingPathComponent("Nearpane.app", isDirectory: true)
        let helper = app.appendingPathComponent("Contents/Helpers/NearpaneDesktopReader")
        try files.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: helper)
        let link = root.appendingPathComponent("linked.app")
        try files.createSymbolicLink(at: link, withDestinationURL: app)
        #expect(NativeDesktopProvider.resolvedReader(in: link)?.path == helper.resolvingSymlinksInPath().path)
        let outside = root.appendingPathComponent("other-reader")
        try Data().write(to: outside)
        try files.removeItem(at: helper)
        try files.createSymbolicLink(at: helper, withDestinationURL: outside)
        #expect(NativeDesktopProvider.resolvedReader(in: app) == nil)
    }

    @Test func accessibleWindowPositionUsesTheClippedDrawingWithinItsDisplay() {
        let desktop = SurfaceRect(x: 18, y: 56, width: 80, height: 120)
        let visible = SurfaceRect(x: 58, y: 86, width: 40, height: 90)
        #expect(DesktopSurface.windowDescription(index: 1, frame: visible, within: desktop) ==
                "窗口 2，左距 50%，上距 25%，宽 50%，高 75%")
    }

    @Test func privateCrashFallsBackToPublicAndStaysLatchedUntilOptInChanges() async throws {
        let attempts = Attempts()
        let provider = NativeDesktopProvider(fixtureWindows: { nil }, anchors: { [] }) { try await attempts.call($0) }
        let first = try await provider.snapshot(experimentalSpaces: true)
        let second = try await provider.snapshot(experimentalSpaces: true)
        #expect(first.native?.spaces == .unavailable && first.native?.accessibility == .denied)
        #expect(first.sessionID == second.sessionID && second.revision == first.revision+1)
        #expect(await attempts.modes == [true,false,false])
        let plain = try await provider.snapshot(experimentalSpaces: false)
        #expect(plain.native?.spaces == .disabled)
        _ = try await provider.snapshot(experimentalSpaces: true)
        #expect(await attempts.modes == [true,false,false,false,true,false])
    }

    @Test func rejectsUnrequestedSpaceProofAndExpiredOwnerWitness() async throws {
        let anchor = ActiveSpaceAnchor(number: 15, displayID: "secondary", globalFrame: .init(x: 1, y: 4, width: 60, height: 40))
        var count = 0
        let provider = NativeDesktopProvider(fixtureWindows: { nil }, anchors: {
            count += 1; return count == 1 ? [anchor] : []
        }) { r in
            var s = sample(r, status: .observed)
            s.native?.rows = [.init(displayID: "secondary", scopeID: "scope", recordID: "8", anchor: anchor)]
            s.userSpaceSemantics = .witnessedCurrent
            return s
        }
        let expired = try await provider.snapshot(experimentalSpaces: true)
        #expect(expired.freshness == .transient && expired.native?.rows.isEmpty == true && expired.userSpaceSemantics == .unknown)
        await #expect(throws: ReaderFailure.self) { try await provider.snapshot(experimentalSpaces: false) }
    }

    @Test func foreignActiveListWitnessMustStillBePubliclyActiveAtDelivery() async throws {
        let provider = NativeDesktopProvider(fixtureWindows: { nil }, anchors: { [] }, activeNumbers: { [] }) { request in
            var s = sample(request, status: .observed)
            let frame = SurfaceRect(x: 4, y: 5, width: 100, height: 90)
            let anchor = ActiveSpaceAnchor(number: 44, displayID: "secondary", globalFrame: frame, witness: .appKitActiveList)
            s.windows = [.init(id: "w", displayID: "secondary", bounds: frame, membership: .known(recordIDs: ["8"]),
                               confidence: .corroboratedMetadata, metadata: .init(number: 44, pid: 721, launchMicroseconds: 123,
                                   element: UUID(), globalFrame: frame, frontToBack: 0, minimized: false, fullScreen: false, axFrame: frame, isOnscreen: true,
                                   axStandardWindowNumber: 44))]
            s.native?.rows = [.init(displayID: "secondary", scopeID: "scope", recordID: "8", anchor: anchor)]
            s.userSpaceSemantics = .witnessedCurrent
            return s
        }
        let s = try await provider.snapshot(experimentalSpaces: true)
        #expect(s.freshness == .transient && s.native?.rows.isEmpty == true)
    }

    @Test func cancellationResistantReadCannotPublishAfterDisableHideOrShutdown() async throws {
        for operation in 0..<3 {
            let read = DelayedRead(), host = HostSession(store: MemoryConfigurationStore(), provider: read)
            await host.start()
            for _ in 0..<100 where read.waiting == nil { try await Task.sleep(for: .milliseconds(2)) }
            try #require(read.waiting != nil)
            switch operation {
            case 0: #expect(host.handle(.setEnabled(BuiltinCatalog.desktop, false)) == .accepted)
            case 1: host.setSurfaceHidden(true)
            default: host.stop()
            }
            read.finish()
            try await Task.sleep(for: .milliseconds(10))
            #expect(host.bus.desktop == nil)
            host.stop()
        }
    }

    @Test func openingAProfileWhileLockedDoesNotStartObservationUntilWakeAndUnlock() async throws {
        let reader = CountingRead()
        let host = HostSession(store: MemoryConfigurationStore(), provider: reader)
        host.setDesktopPause(.inactiveSession, paused: true)
        host.setDesktopPause(.screensAsleep, paused: true)
        await host.start()
        let modules = host.registry.states
        await host.refreshDesktop()
        #expect(reader.reads == 0 && host.bus.desktop == nil)
        host.setDesktopPause(.screensAsleep, paused: false)
        await host.refreshDesktop()
        #expect(reader.reads == 0 && host.bus.desktop == nil)
        host.setDesktopPause(.inactiveSession, paused: false)
        for _ in 0..<100 where host.bus.desktop == nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(reader.reads == 1 && host.bus.desktop != nil && host.registry.states == modules)
        host.stop()
    }

    @Test func sleepAndInactiveSessionRequireBothReasonsToClearBeforeASingleFreshRead() async throws {
        let gate = DelayedRead(), host = HostSession(store: MemoryConfigurationStore(), provider: gate)
        await host.start()
        for _ in 0..<100 where gate.waiting == nil { try await Task.sleep(for: .milliseconds(2)) }
        try #require(gate.waiting != nil)
        host.setDesktopPause(.screensAsleep, paused: true)
        host.setDesktopPause(.inactiveSession, paused: true)
        host.setDesktopPause(.screensAsleep, paused: false)
        gate.finish()
        await host.refreshDesktop()
        try await Task.sleep(for: .milliseconds(8))
        #expect(host.bus.desktop == nil && gate.waiting == nil)
        host.setDesktopPause(.inactiveSession, paused: false)
        for _ in 0..<100 where gate.waiting == nil { try await Task.sleep(for: .milliseconds(2)) }
        try #require(gate.waiting != nil)
        host.stop()
        var drained = false
        let shutdown = Task { await host.waitForDesktopStop(); drained = true }
        try await Task.sleep(for: .milliseconds(8))
        #expect(!drained)
        gate.finish()
        await shutdown.value
        #expect(drained && host.bus.desktop == nil)
    }

    @Test func hangingProcessTimesOutAndIsReapedBeforeReturning() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("np-reader-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let executable = root.appendingPathComponent("reader")
        try "#!/bin/sh\nexec /bin/sleep 15\n".write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let req = DesktopReadRequest(session: UUID(), revision: 1, parentPID: getpid(), fixtureWindows: [], anchors: [], experimentalSpaces: false)
        let launched = OSAllocatedUnfairLock<pid_t?>(initialState: nil)
        await #expect(throws: ReaderFailure.timeout) {
            try await DesktopReaderProcess.read(executable: executable, request: req, timeout: 0.3) { pid in
                launched.withLock { $0 = pid }
            }
        }
        let pid = try #require(launched.withLock { $0 })
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func malformedOrMismatchedSubprocessResponseNeverPublishes() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("np-result-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let executable = root.appendingPathComponent("reader"), output = root.appendingPathComponent("reader.output")
        try "#!/bin/sh\nexec /bin/cat \"$0.output\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let req = DesktopReadRequest(session: UUID(), revision: 1, parentPID: getpid(), fixtureWindows: [], anchors: [], experimentalSpaces: false)
        let good = sample(req, status: .disabled)
        try JSONEncoder().encode(good).write(to: output)
        #expect(try await DesktopReaderProcess.read(executable: executable, request: req) == good)
        var wrong = good; wrong.revision += 1
        try JSONEncoder().encode(wrong).write(to: output)
        await #expect(throws: ReaderFailure.invalidResponse) { try await DesktopReaderProcess.read(executable: executable, request: req) }
        try Data("{".utf8).write(to: output)
        await #expect(throws: DecodingError.self) { try await DesktopReaderProcess.read(executable: executable, request: req) }
        try Data(repeating: 32, count: 1_049_000).write(to: output)
        await #expect(throws: ReaderFailure.outputLimit) { try await DesktopReaderProcess.read(executable: executable, request: req) }
    }
}
