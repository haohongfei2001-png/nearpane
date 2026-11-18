import Foundation
import NearpaneCore
@testable import NearpaneUI
import Testing

@MainActor struct NativeSidebarNavigationTests {
    let a = UUID(), b = UUID(), c = UUID(), session = UUID()
    let frame = SurfaceRect(x: 10, y: 20, width: 300, height: 200)

    func window(_ number: UInt32, _ spaces: [String], front: Int, birth: UInt64 = 9) -> WindowObservation {
        .init(id: "w" + String(number), displayID: "screen", bounds: frame,
              membership: spaces.isEmpty ? .unknown : .known(recordIDs: spaces), confidence: .unknown,
              metadata: .init(number: number, pid: 54, launchMicroseconds: birth, element: nil, globalFrame: frame,
                frontToBack: front, minimized: nil, fullScreen: nil, isOnscreen: spaces.contains("1"),
                onActiveDesktop: spaces.contains("1"), overviewSpaceID: spaces.contains("1") ? "1" : nil))
    }

    func snapshot(_ windows: [WindowObservation], complete: Bool = true, rev: UInt64 = 1,
                  backgroundID: UUID? = nil, topology: String = "screens") -> DesktopSnapshot {
        let size = SurfaceRect(width: 800, height: 600), now = Date(), uptime = ProcessInfo.processInfo.systemUptime
        return .observed(.init(session: session, revision: rev, parentPID: 1, fixtureWindows: nil,
                               anchors: [], experimentalSpaces: false), from: now, to: now, build: "fixture",
                topology: topology, consistent: true, separateSpaces: true,
                displays: [.init(id: "screen", frame: size, rotationDegrees: 0, backingScale: 1, usable: size)],
                scopes: [.init(id: "scope", displayID: "screen", records: [
                    .init(id: "1", isCurrent: true, ordinaryUUID: a), .init(id: "2", isCurrent: false, ordinaryUUID: backgroundID ?? b),
                    .init(id: "3", isCurrent: false, ordinaryUUID: c), .init(id: "7", isCurrent: false)
                ])], windows: windows, evidence: .init(population: .workWindows, accessibility: .available,
                        spaces: .observed, rows: [], windowLimitReached: false, beganUptime: uptime, endedUptime: uptime,
                        catalogComplete: complete))
    }

    func map(_ s: DesktopSnapshot) throws -> NativeSpaceCatalog {
        try #require(NativeSpaceCatalog(s, displayID: "screen", now: .now, uptime: ProcessInfo.processInfo.systemUptime))
    }

    @Test func navigatorIncludesNeverVisitedAndEmptySpacesWithoutLeakingIntoCurrentCards() throws {
        let all = snapshot([window(8, ["1"], front: 2), window(9, ["2"], front: 1), window(7, ["1","2"], front: 0)])
        let rows = try map(all).rows
        #expect(rows.map(\.id) == ["1","2","3"])
        #expect(rows.map { $0.windows.map(\.id) } == [["w7","w8"],["w7","w9"],[]])
        #expect(rows[2].regularWindowListComplete)
        #expect(all.currentDesktopWindows(on: "screen", now: .now, uptime: ProcessInfo.processInfo.systemUptime).map(\.id) == ["w7","w8"])
        #expect(try !map(snapshot([], complete: false)).rows[2].regularWindowListComplete)
        #expect(try !map(snapshot([window(9, [], front: 0)])).rows[2].regularWindowListComplete)
    }

    @Test func gestureSurvivesUnrelatedRefreshButNotReplacedOwnerSpaceOrTopology() throws {
        let w = window(8, ["2"], front: 0), initial = try map(snapshot([w]))
        let dest = try #require(NativeSidebarDestination(initial.rows[1], in: initial))
        let member = try #require(NativeSidebarMember(w, source: dest))
        #expect(member.resolve(snapshot([w, window(7, ["1"], front: 1)], rev: 5)) != nil)
        #expect(member.resolve(snapshot([window(8, ["2"], front: 0, birth: 33)])) == nil)
        #expect(member.resolve(snapshot([w], backgroundID: UUID())) == nil)
        #expect(member.resolve(snapshot([w], topology: "reconnected")) == nil)
        #expect(member.resolve(snapshot([window(8, ["1"], front: 0)])) == nil)
    }

    @Test func newerChoiceSuppressesOldPostSwitchFocusAndCoalescesIntermediateIntent() async {
        let router = NativeSidebarNavigation()
        var resume: CheckedContinuation<Void, Never>?, effects = [String]()
        router.submit { token in
            effects.append("switch")
            await withCheckedContinuation { resume = $0 }
            if router.isCurrent(token) { effects.append("stale focus") }
        }
        while resume == nil { await Task.yield() }
        router.submit { _ in effects.append("intermediate") }
        router.submit { _ in effects.append("latest") }
        resume?.resume()
        for _ in 0..<100 where effects.count < 2 { await Task.yield() }
        #expect(effects == ["switch", "latest"])
    }
    @Test func subsequentSelectionCannotDiscardQueuedMove() async {
        let router = NativeSidebarNavigation()
        var resume: CheckedContinuation<Void, Never>?, effects = [String]()
        router.submit { _ in await withCheckedContinuation { resume = $0 } }
        while resume == nil { await Task.yield() }
        router.submit(selection: false) { _ in effects.append("move") }
        router.submit { _ in effects.append("intermediate") }
        router.submit { _ in effects.append("latest") }
        resume?.resume()
        for _ in 0..<100 where effects.count < 2 { await Task.yield() }
        #expect(effects == ["move", "latest"])
    }
    @Test func revocationCancelsOnlyFutureGestureSteps() {
        let permit = NativeSelectionPermit()
        let command = NativeSpaceCommand(id: UUID(), action: .select, display: "", source: "", target: "", createdAtUptime: 50)
        let started = permit.permission(for: command.id, after: 0)
        permit.revoke()
        #expect(started.permits(command, after: 0, now: 51))
        #expect(!permit.permission(for: command.id, after: 1).permits(command, after: 1, now: 51))
    }

}
