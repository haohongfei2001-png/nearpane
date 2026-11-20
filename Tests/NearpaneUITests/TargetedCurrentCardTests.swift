import Foundation
import NearpaneCore
@testable import NearpaneUI
import Testing

@MainActor struct TargetedCurrentCardTests {
    let session = UUID(), display = UUID().uuidString, current = UUID(), other = UUID()
    let topology = String(repeating: "b", count: 64), now = Date()
    let frame = SurfaceRect(x: 50, y: 60, width: 300, height: 210)

    func snapshot(stage: Bool? = false, visible: Bool = true, role: Bool = true, shared: Bool = false,
                  screens: Int = 1, desk: UUID? = nil, reordered: Bool = false) -> DesktopSnapshot {
        let window = WindowObservation(id: "test-window", displayID: display, bounds: frame,
            membership: .known(recordIDs: shared ? ["41","53"] : ["41"]), confidence: .unknown,
            metadata: .init(number: 75, pid: 17, launchMicroseconds: 746, element: nil, globalFrame: frame, frontToBack: 0,
                minimized: false, fullScreen: false, isOnscreen: visible, onActiveDesktop: visible, overviewSpaceID: "41",
                overviewIsPresented: true, overviewOrdinaryRole: role))
        let records = [SpaceRecord(id: "41", isCurrent: true, ordinaryUUID: desk ?? current),
                       SpaceRecord(id: "53", isCurrent: false, fullscreenUUID: other)]
        let screen = SurfaceRect(width: 1000, height: 700)
        return .observed(.init(session: session, revision: 1, parentPID: 1, fixtureWindows: nil, anchors: [], experimentalSpaces: false),
            from: now, to: now, build: "test", topology: topology, consistent: true, separateSpaces: true,
            displays: (0..<screens).map { .init(id: $0 == 0 ? display : UUID().uuidString, frame: screen,
                                                rotationDegrees: 0, backingScale: 2, usable: screen) },
            scopes: [.init(id: "scope", displayID: display, records: reordered ? records.reversed() : records)], windows: [window],
            evidence: .init(population: .workWindows, accessibility: .available, spaces: .observed, rows: [], windowLimitReached: false,
                            beganUptime: 99, endedUptime: 100, stageManagerEnabled: stage, catalogComplete: true))
    }

    private func card(_ snapshot: DesktopSnapshot) -> DesktopWindowTarget? { DesktopWindowTarget(snapshot.windows[0], in: snapshot) }

    @Test func onlyTheExactPublicCurrentOrdinaryCardUsesTheSignedTargetedRead() throws {
        let base = snapshot()
        let target = try #require(card(base))
        let scope = try #require(target.currentFocusScope)
        #expect(scope.desktop == OrdinaryDesktopIdentity(display: display, record: "41", uuid: current))
        #expect(scope.topology == topology)
        #expect(scope.order.map(\.id) == ["41", "53"])
        #expect(card(snapshot(screens: 2))?.currentFocusScope == nil)
        #expect(card(snapshot(stage: true))?.currentFocusScope == nil)
        #expect(card(snapshot(stage: nil))?.currentFocusScope == nil)
        #expect(card(snapshot(visible: false))?.currentFocusScope == nil)
        #expect(card(snapshot(role: false))?.currentFocusScope == nil)
        #expect(card(snapshot(shared: true))?.currentFocusScope == nil)
        #expect(target.remainsSelection(in: base, now: now, uptime: 101))
        #expect(!target.remainsSelection(in: snapshot(desk: UUID()), now: now, uptime: 101))
        #expect(!target.remainsSelection(in: snapshot(reordered: true), now: now, uptime: 101))
    }

    @Test func aFullReadIsNeverStartedForConfirmedOrContradictoryEvidence() async throws {
        let scope = try #require(card(snapshot())?.currentFocusScope)
        var fullReads = 0, readTargets = [OrdinaryFocusScope]()
        let actual = try await DesktopWindowSelection.resolveFocusScope(scope, current: { true }, inspect: {
            readTargets.append($0)
            return .confirmed
        }, fullRoster: { fullReads += 1 })
        #expect(actual == scope && readTargets == [scope] && fullReads == 0)
        await #expect(throws: OrdinaryWindowFailure.self) {
            _ = try await DesktopWindowSelection.resolveFocusScope(scope, current: { true }, inspect: { _ in .changed },
                                                                 fullRoster: { fullReads += 1 })
        }
        #expect(fullReads == 0)
        let fallback = try await DesktopWindowSelection.resolveFocusScope(scope, current: { true }, inspect: { _ in .fullRosterRequired },
                                                                         fullRoster: { fullReads += 1 })
        #expect(fallback == nil && fullReads == 1)
    }

    @Test func newerInputOrIncompleteFallbackCannotAuthorizeFocus() async throws {
        let scope = try #require(card(snapshot())?.currentFocusScope)
        var latest = true, fullReads = 0
        await #expect(throws: OrdinaryWindowFailure.self) {
            _ = try await DesktopWindowSelection.resolveFocusScope(scope, current: { latest }, inspect: { _ in
                latest = false
                return .confirmed
            }, fullRoster: { fullReads += 1 })
        }
        #expect(fullReads == 0)
        await #expect(throws: CancellationError.self) {
            _ = try await DesktopWindowSelection.resolveFocusScope(scope, current: { true }, inspect: { _ in .fullRosterRequired },
                                                                 fullRoster: { fullReads += 1; throw CancellationError() })
        }
        #expect(fullReads == 1)
    }
}
