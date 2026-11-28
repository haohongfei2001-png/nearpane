import Foundation
import NearpaneCore
import Testing

@MainActor struct StageHostDesktopSchedulingTests {
    @Test(.timeLimit(.minutes(1))) func dispatchDefersAutomaticReadsWithoutDiscardingTheDisplayedSnapshot() async throws {
        let admission = DesktopRefreshAdmission(), provider = ScheduledDesktopReader()
        let host = HostSession(store: MemoryConfigurationStore(), provider: provider,
                               automaticDesktopRefreshAllowed: admission.permits)
        let publications = AsyncStream<DesktopSnapshot>.makeStream()
        host.presentationChanged = { [weak host] in
            guard let snapshot = host?.bus.desktop else { return }
            // Permit exactly one automatic refresh after dispatch ends, even if
            // other test suites keep the main actor busy for another interval.
            if snapshot.revision > 1 { admission.allowed = false }
            publications.continuation.yield(snapshot)
        }
        defer {
            host.stop()
            admission.checks.continuation.finish()
            publications.continuation.finish()
        }
        var checks = admission.checks.stream.makeAsyncIterator()
        var updates = publications.stream.makeAsyncIterator()
        await host.start()
        #expect(await checks.next() == false)
        #expect(provider.reads == 0 && host.bus.desktop == nil)

        // An explicitly requested read does not wait on display scheduling.
        await host.refreshDesktop()
        let displayed = try #require(await updates.next())
        #expect(await checks.next() == false)
        #expect(provider.reads == 1 && provider.discards == 0)
        #expect(host.bus.desktop == displayed && !host.providerFailed)
        #expect(host.bus.lastStableDesktop == displayed)

        admission.allowed = true
        let refreshed = try #require(await updates.next())
        #expect(provider.reads == 2 && provider.discards == 0)
        #expect(refreshed.sessionID == displayed.sessionID && refreshed.revision == displayed.revision + 1)
        #expect(host.bus.desktop == refreshed)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingWhileWaitingCannotStartAReadWhenDispatchEnds() async throws {
        let admission = DesktopRefreshAdmission(), provider = ScheduledDesktopReader()
        let host = HostSession(store: MemoryConfigurationStore(), provider: provider,
                               automaticDesktopRefreshAllowed: admission.permits)
        defer { host.stop(); admission.checks.continuation.finish() }
        var checks = admission.checks.stream.makeAsyncIterator()
        await host.start()
        #expect(await checks.next() == false)
        host.stop()
        await host.waitForDesktopStop()
        admission.allowed = true
        #expect(provider.reads == 0 && host.bus.desktop == nil)
    }
}

@MainActor private final class DesktopRefreshAdmission {
    var allowed = false
    let checks = AsyncStream<Bool>.makeStream()
    func permits() -> Bool {
        checks.continuation.yield(allowed)
        return allowed
    }
}

@MainActor private final class ScheduledDesktopReader: LiveDesktopObservationProvider {
    let capabilities = DesktopCapabilities(observation: .readOnly)
    private let session = UUID()
    private(set) var reads = 0
    private(set) var discards = 0
    func discardVisitedSpaces() { discards += 1 }
    func snapshot(experimentalSpaces: Bool) async throws -> DesktopSnapshot {
        reads += 1
        let now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        let area = SurfaceRect(width: 800, height: 600)
        return .observed(.init(session: session, revision: UInt64(reads),
            parentPID: ProcessInfo.processInfo.processIdentifier, fixtureWindows: nil, anchors: [],
            experimentalSpaces: experimentalSpaces), from: now, to: now, build: "test", topology: "one",
            consistent: true, separateSpaces: true,
            displays: [.init(id: "display", frame: area, rotationDegrees: 0, backingScale: 1, usable: area)],
            scopes: [], windows: [], evidence: .init(population: .workWindows, accessibility: .denied,
                spaces: .disabled, rows: [], windowLimitReached: false, beganUptime: uptime, endedUptime: uptime))
    }
}
