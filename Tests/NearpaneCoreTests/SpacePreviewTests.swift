import Foundation
import CoreGraphics
import Testing
@testable import NearpaneCore

struct SpacePreviewTests {
    let now = Date(timeIntervalSince1970: 1000)
    let screen = CGRect(x: 0, y: 20, width: 1440, height: 860)
    typealias Plan = FixtureSpacePreview.Plan
    func plan(_ id: String, _ order: [String]) -> Plan {
        Plan(spaceID: id, displayID: "fixture-display-0", usable: screen, frontToBack: order)
    }

    @Test func sharedScaleCropsAtUsableBoundsAndRespectsFrontWindow() throws {
        var snapshot = DesktopFixture.singleDisplay.makeSnapshot(now: now)
        let space = snapshot.scopes[0].records[0].id
        func window(_ id: String, _ b: SurfaceRect) -> WindowObservation {
            WindowObservation(id: id, displayID: snapshot.displays[0].id, bounds: b, membership: .known(recordIDs: [space]), confidence: .synthetic)
        }
        snapshot.windows = [
            window("back", .init(x: -80, y: 20, width: 1600, height: 250)),
            window("front", .init(x: 240, y: -40, width: 300, height: 1290)),
            window("floating", .init(x: 660, y: 340, width: 240, height: 140))]
        let viewport = CGRect(x: 10, y: 15, width: 288, height: 200)
        let preview = try #require(FixtureSpacePreview(snapshot: snapshot,
            plans: [plan(space, ["floating","front","back"])], in: viewport, now: now))
        let row = preview.rows[0]
        #expect(row.desktop == CGRect(x: 10, y: 29, width: 288, height: 172))
        #expect(row.windows.map(\.frame) == [CGRect(x: 142, y: 93, width: 48, height: 28),
            CGRect(x: 58, y: 29, width: 60, height: 172), CGRect(x: 10, y: 29, width: 288, height: 50)])
        func target(_ id: String) -> DesktopTarget { .init(sessionID: snapshot.sessionID, revision: snapshot.revision, runtimeID: id) }
        func hit(_ x: Int, _ y: Int) -> FixtureSpacePreview.Hit? { preview.hit(at: CGPoint(x: x, y: y), current: snapshot, now: now) }
        #expect(hit(65,40) == .window(target("front")))
        #expect(hit(30,40) == .window(target("back")))
        #expect(hit(151,100) == .window(target("floating")))
        #expect(hit(260,170) == .space(target(space)))
        #expect(hit(20,18) == nil)
    }

    @Test func extraRowsResizeOnlyTheDesktopAndKeepDisplayLocalGeometry() throws {
        var snapshot = DesktopFixture.rotatedDisplay.makeSnapshot(now: now)
        let display = snapshot.displays[1]
        let space = snapshot.scopes[1].records[0].id
        let more = (0..<5).map { SpaceRecord(id: "explicit-fixture-row-\($0)", isCurrent: false) }
        snapshot.scopes[1] = ManagedDisplayScope(id: snapshot.scopes[1].id, displayID: display.id,
            records: [SpaceRecord(id: space, isCurrent: true)] + more)
        let usable = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        let plans = snapshot.scopes[1].records.map { Plan(spaceID: $0.id, displayID: display.id, usable: usable,
            frontToBack: $0.id == space ? ["fixture-window-1-a"] : []) }
        let desktop = LayoutComposer.compose(width: 120, height: 1280, pinnedCount: 0, expanded: false).desktop
        let frame = CGRect(x: desktop.x, y: desktop.y, width: desktop.width, height: desktop.height)
        for n in 2...6 {
            let preview = try #require(FixtureSpacePreview(snapshot: snapshot, plans: Array(plans.prefix(n)), in: frame, now: now))
            #expect(preview.rows.map(\.spaceID) == plans.prefix(n).map(\.spaceID))
            #expect(preview.rows.allSatisfy { frame.contains($0.desktop) })
            let window = try #require(preview.rows[0].windows.first)
            #expect(abs(window.frame.width/window.frame.height - 640.0/720.0) < 0.00001)
            #expect(window.frame.minX > preview.rows[0].desktop.minX)
        }
    }

    @Test func ambiguousMembershipOrderAndOutdatedIdentitiesRefuseHits() throws {
        let s = DesktopFixture.singleDisplay.makeSnapshot(now: now)
        let id = s.scopes[0].records[0].id, order = s.windows.map(\.id)
        let frame = CGRect(x: 0, y: 0, width: 144, height: 90)
        func preview(_ snapshot: DesktopSnapshot, _ order: [String]) -> FixtureSpacePreview? {
            FixtureSpacePreview(snapshot: snapshot, plans: [plan(id, order)], in: frame, now: now)
        }
        #expect(preview(s, [order[0], order[0]]) == nil)
        #expect(preview(s, [order[0]]) == nil)
        #expect(preview(DesktopFixture.unknownMembership.makeSnapshot(now: now), order) == nil)
        #expect(preview(DesktopFixture.transient.makeSnapshot(now: now), order) == nil)
        let model = try #require(preview(s, order)), p = CGPoint(x: 50, y: 40)
        var changed = s; changed.revision += 1
        #expect(model.hit(at: p, current: changed, now: now) == nil)
        changed = s; changed.sessionID = UUID()
        #expect(model.hit(at: p, current: changed, now: now) == nil)
        changed = s; changed.topologyFingerprint += "-new"
        #expect(model.hit(at: p, current: changed, now: now) == nil)
        #expect(model.hit(at: p, current: s, now: now.addingTimeInterval(11)) == nil)
    }

    @Test func asymmetricSplitAndFullyCoveredSiblingKeepTheirActualClickRegions() throws {
        var s = DesktopFixture.singleDisplay.makeSnapshot(now: now)
        let space = s.scopes[0].records[0].id, display = s.displays[0].id
        func window(_ id: String, x: Double, w: Double) -> WindowObservation {
            .init(id: id, displayID: display, bounds: .init(x: x, y: 20, width: w, height: 860),
                  membership: .known(recordIDs: [space]), confidence: .synthetic)
        }
        s.windows = [window("app-A/front", x: 0, w: 960), window("app-A/back", x: 120, w: 600),
                     window("app-B", x: 960, w: 480)]
        let model = try #require(FixtureSpacePreview(snapshot: s, plans: [plan(space, s.windows.map(\.id))],
            in: CGRect(x: 0, y: 0, width: 144, height: 86), now: now))
        let windows = model.rows[0].windows
        #expect(windows.map { $0.frame.width } == [96, 60, 48])
        #expect(windows[1].exposed.isEmpty)
        #expect(windows[0].exposed == [windows[0].frame] && windows[2].exposed == [windows[2].frame])
        #expect(model.hit(at: CGPoint(x: 120, y: 30), current: s, now: now) ==
            .window(.init(sessionID: s.sessionID, revision: s.revision, runtimeID: "app-B")))
    }
}
