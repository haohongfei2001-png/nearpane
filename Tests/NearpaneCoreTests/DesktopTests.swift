import Foundation
import Testing
@testable import NearpaneCore

@MainActor
@Suite(.serialized)
struct DesktopTests {
    @Test func testAllFixturesHaveProvenanceAndRoundTripWithoutInventingSpaces() async throws {
        for fixture in DesktopFixture.allCases {
            let snapshot = fixture.makeSnapshot()
            #expect(snapshot.isStructurallyValid, "\(fixture.rawValue)")
            #expect(snapshot.userSpaceSemantics == .unknown)
            #expect(snapshot.source == "synthetic-fixture")
            #expect(!(snapshot.capabilities.spaceSwitching))
            #expect(!(snapshot.capabilities.windowActivation))
            #expect((1...3).contains(snapshot.displays.count))
            let decoded = try JSONDecoder().decode(DesktopSnapshot.self, from: JSONEncoder().encode(snapshot))
            #expect(snapshot == decoded)
        }
    }

    @Test func testThreePlusOneIsInternalInventoryWithUnknownUserSemantics() async {
        let snapshot = DesktopFixture.internalScopes3Plus1.makeSnapshot()
        #expect(snapshot.scopes.map { $0.records.count } == [3, 1])
        #expect(snapshot.separateSpaces == false)
        #expect(snapshot.userSpaceSemantics == .unknown)
        #expect(snapshot.displays[1].rotationDegrees == 90)
    }

    @Test func testDisplayCoverageAndMembershipZeroOneManyUnknownArePreserved() async {
        #expect(DesktopFixture.singleDisplay.makeSnapshot().displays.count == 1)
        #expect(DesktopFixture.twoDisplays.makeSnapshot().displays.count == 2)
        #expect(DesktopFixture.threeDisplays.makeSnapshot().displays.count == 3)
        let windows = DesktopFixture.unknownMembership.makeSnapshot().windows
        #expect(windows.contains { $0.membership == .unknown })
        #expect(windows.contains { $0.membership == .known(recordIDs: []) })
        #expect(windows.contains { if case .known(let ids) = $0.membership { return ids.count == 2 }; return false })
        #expect(DesktopFixture.singleDisplay.makeSnapshot().windows.contains {
            if case .known(let ids) = $0.membership { return ids.count == 1 }; return false
        })
    }

    @Test func testFreshnessAgesAndTransientIsNotStable() async {
        let now = Date(timeIntervalSince1970: 1000)
        let snapshot = DesktopFixture.singleDisplay.makeSnapshot(now: now)
        #expect(snapshot.effectiveFreshness(at: now) == .fresh)
        #expect(snapshot.effectiveFreshness(at: now.addingTimeInterval(11)) == .stale)
        #expect(snapshot.effectiveFreshness(at: now.addingTimeInterval(-1)) == .stale)
        #expect(DesktopFixture.stale.makeSnapshot(now: now).effectiveFreshness(at: now) == .stale)
        #expect(DesktopFixture.transient.makeSnapshot(now: now).effectiveFreshness(at: now) == .transient)
    }

    @Test func testSnapshotBusRetainsStableSampleAndRejectsOlderSessionsAndRevisions() async {
        let bus = SnapshotBus(diagnostics: Diagnostics())
        let session = UUID()
        let stable = DesktopFixture.singleDisplay.makeSnapshot(sessionID: session)
        #expect(bus.acceptDesktop(stable))
        #expect(!(bus.acceptDesktop(stable)))
        #expect(!(bus.acceptDesktop(DesktopFixture.twoDisplays.makeSnapshot(revision: 2))))
        let transient = DesktopFixture.transient.makeSnapshot(revision: 2, sessionID: session)
        #expect(bus.acceptDesktop(transient))
        #expect(bus.desktop == transient)
        #expect(bus.lastStableDesktop == stable)
        #expect(bus.acceptDesktop(DesktopFixture.stale.makeSnapshot(revision: 3, sessionID: session)))
        #expect(bus.lastStableDesktop == stable)
        bus.resetDesktopSession()
        #expect(bus.lastStableDesktop == nil)
        #expect(bus.acceptDesktop(DesktopFixture.twoDisplays.makeSnapshot()))
    }

    @Test func testMalformedTopologyDoesNotReplaceKnownSnapshot() async {
        let bus = SnapshotBus(diagnostics: Diagnostics())
        let good = DesktopFixture.singleDisplay.makeSnapshot()
        #expect(bus.acceptDesktop(good))
        var bad = good
        bad.revision = 2
        bad.displays.append(bad.displays[0])
        #expect(!(bus.acceptDesktop(bad)))
        #expect(bus.desktop == good)
    }

    @Test func testMockProviderHasMonotonicRevisionsInOneSession() async throws {
        let provider = MockDesktopObservationProvider()
        let first = try await provider.snapshot()
        provider.fixture = .rotatedDisplay
        let second = try await provider.snapshot()
        #expect(second.sessionID == first.sessionID)
        #expect(second.revision > first.revision)
    }

    @Test func testDesktopActionAdapterAlwaysRefuses() async {
        let provider = UnsupportedDesktopActionProvider()
        let target = DesktopTarget(sessionID: UUID(), revision: 1, runtimeID: "synthetic")
        do { try await provider.switchToSpace(target); Issue.record("Must not switch") } catch {}
        do { try await provider.activateWindow(target); Issue.record("Must not activate") } catch {}
    }

    @Test func testDecodingCannotGrantDesktopActions() async throws {
        let data = Data(#"{"observation":"mockOnly","spaceSwitching":true,"windowActivation":true}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DesktopCapabilities.self, from: data) }
    }
}
