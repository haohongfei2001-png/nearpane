import Foundation
import NearpaneCore
@testable import NearpaneUI
import Testing

@MainActor struct NativeSpaceMenuTests {
    private let display = UUID().uuidString, secondDisplay = UUID().uuidString
    private let a = UUID(), b = UUID(), full = UUID(), other = UUID(), session = UUID()

    private func snapshot(order: [String] = ["17", "29", "31"], current: String = "17", build: String = "qualified-test",
                          stage: Bool? = false, session: UUID? = nil, target: UUID? = nil, separate: Bool = true,
                          catalogComplete: Bool = true, age: TimeInterval = 0) -> DesktopSnapshot {
        let date = Date().addingTimeInterval(-age), uptime = ProcessInfo.processInfo.systemUptime - age
        let frame = SurfaceRect(width: 800, height: 600), right = SurfaceRect(x: 800, y: 0, width: 800, height: 600)
        let records: [SpaceRecord] = order.map { id in
            switch id {
            case "17": return .init(id: id, isCurrent: id == current, ordinaryUUID: a)
            case "29": return .init(id: id, isCurrent: id == current, ordinaryUUID: target ?? b)
            case "31": return .init(id: id, isCurrent: id == current, fullscreenUUID: full)
            default: return .init(id: id, isCurrent: false)
            }
        }
        return .observed(.init(session: session ?? self.session, revision: 1, parentPID: 1, fixtureWindows: nil,
                               anchors: [], experimentalSpaces: false), from: date, to: date, build: build,
                         topology: "two-displays", consistent: true, separateSpaces: separate,
                         displays: [.init(id: display, frame: frame, rotationDegrees: 0, backingScale: 1, usable: frame),
                                    .init(id: secondDisplay, frame: right, rotationDegrees: 0, backingScale: 1, usable: frame)],
                         scopes: [.init(id: "physical-A", displayID: display, records: records),
                                  .init(id: "physical-B", displayID: secondDisplay, records: [
                                    .init(id: "99", isCurrent: true, ordinaryUUID: other)])],
                         windows: [], evidence: .init(population: .workWindows, accessibility: .available, spaces: .observed,
                            rows: [], windowLimitReached: false, beganUptime: uptime, endedUptime: uptime,
                            stageManagerEnabled: stage, catalogComplete: catalogComplete))
    }

    @Test func explicitDirectoryUsesRealDisplayOrderEvenWithoutAnyWindows() throws {
        let first = try #require(SpaceMenuInventory(snapshot(catalogComplete: false), display: display))
        #expect(first.rows.map(\.title) == ["桌面 1", "桌面 2", "全屏空间 1"])
        #expect(first.rows.map(\.id) == [a, b, full])
        #expect(first.rows.map(\.isCurrent) == [true, false, false])
        #expect(first.rows[1].isAdjacent)
        #expect(first.permits(first.rows[1].destination, canSwitch: true))
        #expect(!first.permits(first.rows[0].destination, canSwitch: true))
        #expect(!first.permits(first.rows[2].destination, canSwitch: true))
        let middle = try #require(SpaceMenuInventory(snapshot(current: "29"), display: display))
        #expect(middle.permits(middle.rows[2].destination, canSwitch: true))
        let second = try #require(SpaceMenuInventory(snapshot(), display: secondDisplay))
        #expect(second.rows.map(\.id) == [other])
        #expect(!first.permits(second.source, canSwitch: true))
        #expect(SpaceMenuInventory(snapshot(), display: UUID().uuidString) == nil)
        #expect(SpaceMenuInventory(snapshot(separate: false), display: display) == nil)
        #expect(SpaceMenuInventory(snapshot(age: 20), display: display) == nil)
    }

    @Test func existingCatalogueAndRuntimeCapabilityCannotOverrideOSQuarantineOrUnknownOwnership() throws {
        let closed = try #require(SpaceMenuInventory(snapshot(build: "26A428"), display: display))
        #expect(closed.rows.count == 3)
        #expect(!closed.permits(closed.rows[1].destination, canSwitch: true))
        #expect(!closed.stillOffers(closed.rows[1].destination, in: snapshot(build: "26A428")))
        let uncertain = try #require(SpaceMenuInventory(snapshot(stage: nil), display: display))
        #expect(!uncertain.permits(uncertain.rows[1].destination, canSwitch: true))
        #expect(SpaceMenuInventory(snapshot(stage: true), display: display) == nil)
        let open = try #require(SpaceMenuInventory(snapshot(), display: display))
        #expect(!open.permits(open.rows[1].destination, canSwitch: false))
    }

    @Test func freshPreDispatchReadMustMatchSourceTargetAndEntirePhysicalOrder() throws {
        let menu = try #require(SpaceMenuInventory(snapshot(), display: display))
        let dest = menu.rows[1].destination
        #expect(menu.stillOffers(dest, in: snapshot(catalogComplete: false)))
        for replacement in [snapshot(current: "31"), snapshot(order: ["31", "17", "29"]), snapshot(session: UUID()),
                            snapshot(target: UUID()), snapshot(stage: true), snapshot(stage: nil),
                            snapshot(build: "26A428"), snapshot(age: 20), snapshot(order: ["17", "unresolved", "29", "31"])] {
            #expect(!menu.stillOffers(dest, in: replacement))
        }
        let gap = try #require(SpaceMenuInventory(snapshot(order: ["17","unresolved","29","31"]), display: display))
        #expect(!gap.permits(gap.rows[1].destination, canSwitch: true))
    }

    @Test func pickerCloseOwnershipAndNewDisplayRevokeEarlierChoice() throws {
        let menu = NativeSpaceMenu(), owner = UUID()
        menu.open(on: display, ownership: owner)
        let first = try #require(menu.active)
        menu.appeared(first)
        #expect(first.inventory(snapshot(age: 1)) == nil)
        #expect(first.inventory(snapshot())?.rows.count == 3)
        #expect(menu.accepts(first, display: display, ownership: owner, allowed: true))
        #expect(!menu.accepts(first, display: secondDisplay, ownership: owner, allowed: true))
        #expect(!menu.accepts(first, display: display, ownership: UUID(), allowed: true))
        #expect(!menu.accepts(first, display: display, ownership: owner, allowed: false))
        #expect(menu.beginSelection(first))
        #expect(!menu.beginSelection(first))
        menu.open(on: secondDisplay, ownership: owner)
        let newer = try #require(menu.active)
        menu.close(first)
        #expect(menu.active == newer)
        #expect(!menu.beginSelection(first))
        menu.close(newer)
        #expect(!menu.accepts(newer, display: secondDisplay, ownership: owner, allowed: true))
        #expect(!menu.beginSelection(newer))
    }

    @Test func closingThePickerDuringAnOwnershipCheckCancelsTheQueuedProductionSelection() async throws {
        let inventory = try #require(SpaceMenuInventory(snapshot(), display: display))
        let menu = NativeSpaceMenu(), lane = NativeSidebarNavigation()
        menu.open(on: display, ownership: lane.ownershipEpoch)
        let request = try #require(menu.active)
        menu.appeared(request)
        var release: CheckedContinuation<Bool, Never>?
        lane.confirmDispatch = { await withCheckedContinuation { release = $0 } }
        let feed = CurrentDesktopWindows(read: { _ in
            Issue.record("A cancelled choice reached the desktop reader")
            throw CancellationError()
        }, sessionAvailable: { true }, fingerprint: { 0 })
        var finished = false
        lane.select(inventory.rows[1].destination, member: nil, feed: feed, menuInventory: inventory,
                    finished: { finished = true }, allowed: {
            menu.accepts(request, display: self.display, ownership: lane.ownershipEpoch, allowed: true)
        })
        while release == nil { await Task.yield() }
        menu.close(request)
        release?.resume(returning: true)
        while !finished { await Task.yield() }
        #expect(lane.issue == nil)
    }
}
