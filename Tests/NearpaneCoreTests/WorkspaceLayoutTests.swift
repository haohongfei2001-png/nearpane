import Foundation
import Testing

@testable import NearpaneCore

struct WorkspaceLayoutTests {
    let area = SurfaceRect(x: -700, y: 17, width: 700, height: 1000)
    func member(_ i: Int) -> ManagedMember {
        .init(
            .init(pid: 11, launch: 200, number: UInt32(i), element: UUID()), minimumWidth: 20, minimumHeight: 20,
            canResize: true)
    }

    @Test func everyAdmissionCoversWorkRectIncludingNinthThroughSeventeenth() throws {
        var layout = ManagedWindowTiler(workspace: .virtual(UUID()))
        #expect(try layout.frames(in: area).isEmpty)
        for n in 1...17 {
            layout = try layout.adding(member(n), in: area)
            let frames = try layout.frames(in: area)
            #expect(frames.count == n)
            let ordered = layout.members.compactMap { frames[$0.id]?.geometry }
            #expect(ordered.reduce(0) { $0 + $1.area } == area.geometry.area)
            for (i, rect) in ordered.enumerated() {
                #expect(rect.intersection(area.geometry) == rect)
                #expect(ordered.dropFirst(i + 1).allSatisfy { rect.intersection($0) == nil })
            }
            let shares = ordered.map { $0.area / area.geometry.area }
            switch n {
            case 1: #expect(shares == [1])
            case 2: #expect(shares == [0.5, 0.5] && ordered[0].x == area.x)
            case 3: #expect(shares == [0.25, 0.25, 0.5] && ordered[2].x == area.x && ordered[1].y > ordered[0].y)
            case 4: #expect(shares == Array(repeating: 0.25, count: 4))
            case 5: #expect(shares == [0.125, 0.125, 0.25, 0.25, 0.25])
            case 8: #expect(shares == Array(repeating: 0.125, count: 8))
            case 9: #expect(shares[0] == 1.0 / 16 && shares[8] == 1.0 / 16)
            case 16: #expect(shares == Array(repeating: 1.0 / 16, count: 16))
            case 17: #expect(shares[0] == 1.0 / 32 && shares[16] == 1.0 / 32)
            default: break
            }
        }
        #expect(layout.members.map(\.id.number) == Array(1...17).map(UInt32.init))
    }

    @Test func userPartitionPersistsButJoiningThirdResetsTemplate() throws {
        let ids = (1...3).map(member)
        var layout = ManagedWindowTiler(workspace: .virtual(UUID()))
        for m in ids.prefix(2) { layout = try layout.adding(m, in: area) }
        layout = try layout.adjusting(path: [], axis: .rows, ratio: 0.7, in: area).swapping(ids[0].id, ids[1].id, in: area)
        let saved = try JSONDecoder().decode(ManagedWindowTiler.self, from: JSONEncoder().encode(layout))
        #expect(try saved.frames(in: area)[ids[1].id]?.height == 700)
        layout = try saved.adding(ids[2], in: area)
        #expect(try layout.frames(in: area)[ids[2].id] == SurfaceRect(x: -700, y: 17, width: 350, height: 1000))
        #expect(try layout.frames(in: area)[ids[0].id] == SurfaceRect(x: -350, y: 17, width: 350, height: 500))
        let restored = try layout.removing(ids[2].id, in: area)
        #expect(try restored.frames(in: area) == saved.frames(in: area))
        #expect(restored.userAdjusted)
        #expect(try layout.removing(ids[1].id, in: area).members.map(\.id) == [ids[0].id, ids[2].id])
    }

    @Test func insufficientMinimumOrPermissionRejectsWholePlan() throws {
        let base = try ManagedWindowTiler(workspace: .virtual(UUID())).adding(member(1), in: area)
        #expect(throws: WorkspaceFailure.minimumSize) {
            try base.adding(.init(member(2).id, minimumWidth: 351, minimumHeight: 1, canResize: true), in: area)
        }
        #expect(throws: WorkspaceFailure.permission) {
            try base.adding(.init(member(2).id, minimumWidth: 1, minimumHeight: 1, canResize: false), in: area)
        }
        #expect(try base.frames(in: area).values.first == area)
    }

    @Test func workRectSurvivesEveryPresentationAndInternalEdit() throws {
        var settings = DisplaySettings()
        func work() throws -> DesktopWorkArea {
            try DesktopWorkArea(
                display: "portrait", screen: .init(x: -800, y: 0, width: 800, height: 1280),
                usable: .init(x: -800, y: 17, width: 800, height: 1240), primary: true, settings: settings,
                fallbackEdge: .left)
        }
        let baseline = try work()
        for _ in [PanelContent.full, .compact, .voiceOnly, .trayOnly, .spacesOnly, .hidden] {
            settings.measures[.textSize] = .init(21)
            #expect(try work() == baseline)
        }
        #expect(baseline.frame(nativeFullscreen: false).width == 700)
        #expect(baseline.frame(nativeFullscreen: true).width == 800)
        settings.measures[.reservedWidth] = Measure(150)
        #expect(try work().ordinary.x == -650)
    }

    @Test func singleResidenceAndSecondaryPoliciesRemainIndependent() {
        let screens = ["A", "B", "C"].map { ScreenGeometry(id: $0, frame: area, visibleFrame: area) }
        var coord = MultiDisplayPresentationCoordinator()
        var pinned = DisplaySettings()
        var auto = DisplaySettings()
        pinned.policy = .pinned
        auto.policy = .contextualAuto
        let multiple = DisplayDemand(spaces: 2, complete: true)
        func plans(_ settings: [String: DisplaySettings], _ d: DisplayDemand) -> [PanelContent] {
            coord.resolve(
                screens: screens, preferred: "B", settings: settings, demand: ["A": d, "B": d, "C": d],
                hidden: false, voice: true, tray: true, spacesEnabled: true, uptime: 10
            ).map(\.content)
        }
        #expect(plans([:], multiple) == [.hidden, .full, .hidden])
        coord.request("C")
        #expect(plans(["A": auto], multiple) == [.spacesOnly, .full, .spacesOnly])
        coord.dismiss("C")
        #expect(plans(["C": pinned], .init(spaces: 1, windows: 1, complete: true)) == [.hidden, .compact, .spacesOnly])
        #expect(plans(["C": pinned], .init(blocked: true)) == [.hidden, .hidden, .hidden])
    }
}
