import Foundation
import NearpaneCore
@testable import NearpaneUI
import Testing

@MainActor struct NativeSidebarWindowHistoryTests {
    let display = UUID(), a = UUID(), b = UUID(), session = UUID()
    func snapshot(active: Bool, role: Bool?, membership: [String] = ["4975"], birth: UInt64 = 30,
                  denied: Bool = false, include: Bool = true, uuid: UUID? = nil,
                  topology: String = "physical", fullscreen: Bool = false, minimized: Bool = false) -> DesktopSnapshot {
        let frame = SurfaceRect(x: 80, y: 100, width: 200, height: 120), now = Date(), time = ProcessInfo.processInfo.systemUptime
        let m = ObservedWindowMetadata(number: 11, pid: 17, launchMicroseconds: birth, element: nil, globalFrame: frame,
                                       frontToBack: 0, minimized: minimized, fullScreen: fullscreen, isOnscreen: active,
                                       onActiveDesktop: active, overviewSpaceID: active ? "4975" : nil,
                                       overviewIsPresented: active, overviewOrdinaryRole: role)
        let w = WindowObservation(id: "controlled", displayID: display.uuidString, bounds: frame,
                                  membership: .known(recordIDs: membership), confidence: .unknown, metadata: m)
        return .observed(.init(session: session, revision: active ? 1 : 2, parentPID: 1, fixtureWindows: nil, anchors: [],
                               experimentalSpaces: false), from: now, to: now, build: "isolated", topology: topology,
                         consistent: true, separateSpaces: true,
                         displays: [.init(id: display.uuidString, frame: .init(width: 1000, height: 800), rotationDegrees: 0, backingScale: 2,
                                          usable: .init(width: 1000, height: 800))],
                         scopes: [.init(id: "screen", displayID: display.uuidString,
                                       records: [.init(id: "4975", isCurrent: active, ordinaryUUID: uuid ?? a),
                                                 .init(id: "4976", isCurrent: !active, ordinaryUUID: b)])],
                         windows: include ? [w] : [], evidence: .init(population: .workWindows, accessibility: denied ? .denied : .available,
                                             spaces: .observed, rows: [], windowLimitReached: false, beganUptime: time, endedUptime: time,
                                             catalogComplete: true))
    }
    func sections(_ snapshot: DesktopSnapshot) throws -> [[String]] {
        let catalog = try #require(NativeSpaceCatalog(snapshot, displayID: display.uuidString, now: .now,
                                                      uptime: ProcessInfo.processInfo.systemUptime))
        return SidebarBackgroundWindows.sections(in: catalog).map { $0.windows.map(\.id) }
    }

    @Test func exactLiveReferenceRelatesTheRealBackgroundRowAndNeverLeavesTheReaderWire() async throws {
        var history = NativeSidebarWindowHistory()
        let original = UUID()
        var current = snapshot(active: true, role: true)
        await history.update(&current) { probes in
            #expect(probes.count == 1 && probes[0].original == nil && probes[0].current)
            return [original]
        }
        let encoded = try JSONEncoder().encode(current)
        #expect(try JSONDecoder().decode(DesktopSnapshot.self, from: encoded).windows[0].sidebarOriginalWindow == nil)
        var other = snapshot(active: false, role: nil)
        #expect(try sections(other).isEmpty)
        await history.update(&other) { probes in
            #expect(probes.count == 1 && probes[0].original == original && !probes[0].current)
            return [original]
        }
        #expect(other.windows[0].metadata?.overviewOrdinaryRole == nil)
        #expect(try sections(other) == [["controlled"]])
        let projected = try #require(NativeSpaceCatalog(other, displayID: display.uuidString, now: .now,
                                                        uptime: ProcessInfo.processInfo.systemUptime))
        let row = try #require(projected.rows.first(where: { $0.id == "4975" }))
        let dest = try #require(NativeSidebarDestination(row, in: projected))
        let member = try #require(NativeSidebarMember(other.windows[0], source: dest))
        #expect(member.resolve(other) != nil && member.selectionOnly)
        var unseen = snapshot(active: false, role: nil)
        await history.update(&unseen) { _ in [] } // the readers straddled a switch
        #expect(try sections(unseen).isEmpty)
        await history.update(&unseen) { probes in
            #expect(probes.first?.original == original)
            return [nil] // exact original is now closed or cannot be read
        }
        #expect(member.resolve(unseen) == nil)
        #expect(try sections(unseen).isEmpty)
        var next = snapshot(active: true, role: true)
        await history.update(&next) { _ in [UUID()] }
        #expect(member.resolve(next) == nil)
    }

    @Test func contradictionsAndInvalidationCannotSeedOrResurrectABackgroundWindow() async throws {
        let invalid = [snapshot(active:false, role:false), snapshot(active:false, role:nil, membership:["4975","4976"]),
                       snapshot(active:false, role:nil, birth:31), snapshot(active:false, role:nil, denied:true),
                       snapshot(active:false, role:nil, include:false), snapshot(active:false, role:nil, uuid:UUID()),
                       snapshot(active:false, role:nil, topology:"reconnected"),
                       snapshot(active:false, role:nil, fullscreen:true), snapshot(active:false, role:nil, minimized:true)]
        for var changed in invalid {
            let original = UUID()
            var history = NativeSidebarWindowHistory(), first = snapshot(active:true, role:true)
            await history.update(&first) { _ in [original] }
            await history.update(&changed) { probes in Issue.record("unexpected invalid probe \(probes.count)"); return [] }
            #expect(try sections(changed).isEmpty)
            var background = snapshot(active:false, role:nil)
            await history.update(&background) { _ in Issue.record("old window was resurrected"); return [original] }
            #expect(try sections(background).isEmpty)
        }
    }

    @Test func retainedGestureAcceptsOnlyTheWitnessFromItsOwnSignedConnection() async {
        let original = UUID(), id = UUID()
        let permit = NativeSelectionPermit(requiredOriginal: original, checkOriginalWindow: { true })
        #expect(!(await permit.gesturePermission(for: id, after: 0)).proceed)
        #expect(!(await permit.gesturePermission(for: id, after: 0, original: UUID())).proceed)
        #expect((await permit.gesturePermission(for: id, after: 0, original: original)).proceed)
        permit.revoke()
        #expect(!(await permit.gesturePermission(for: id, after: 0, original: original)).proceed)
    }
}
