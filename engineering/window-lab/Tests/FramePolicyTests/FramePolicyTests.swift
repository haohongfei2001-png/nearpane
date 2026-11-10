import Foundation
import NearpaneCore
import Testing
@testable import WindowLab
@testable import NearpaneFrameController

struct FramePolicyTests {
    let primary = SurfaceRect(width: 1920, height: 1080)
    let member = Member(index: 1, id: .init(pid: 123, launch: 999, number: 7, element: UUID()),
                        width: 144, height: 96, session: UUID())
    func screens(_ frame: SurfaceRect) -> Screens {
        .init(main: "primary", secondary: "secondary", mainFrame: primary, frame: frame, usable: frame,
              rotation: 90, scale: 2, separateSpaces: true, consoleSet: 1)
    }
    @Test func mixedMoveAndResizeHasOnlySafeSingleAttributeSteps() throws {
        let screen = screens(.init(x: -800, width: 800, height: 1280))
        let old = SurfaceRect(x: -800, y: 250, width: 650, height: 320)
        let target = SurfaceRect(x: -310, y: 30, width: 305, height: 1200)
        var last = old
        let steps = FramePolicy.steps(from: old, to: target)
        #expect(steps.count == 3)
        for step in steps {
            try FramePolicy.validateStep(last, step, member: member, screens: screen, parking: false)
            last = step
        }
        #expect(last == target && FramePolicy.steps(from: target, to: target).isEmpty)
        #expect(throws: Refusal.self) { try FramePolicy.validateStep(old, target, member: member, screens: screen, parking: false) }
    }
    @Test func corridorsOnlyExtendAwayFromProtectedDisplay() throws {
        for secondary in [SurfaceRect(x: -800, width: 800, height: 1280), .init(x: 1920, width: 800, height: 1280),
                          .init(y: -1280, width: 800, height: 1280), .init(y: 1080, width: 800, height: 1280)] {
            let s = screens(secondary), f = SurfaceRect(x: secondary.x + 60, y: secondary.y + 90, width: 240, height: 160)
            let parked = try FramePolicy.parkingFrame(f, screens: s)
            #expect(parked.geometry.intersection(primary.geometry) == nil && parked.geometry.intersection(secondary.geometry) == nil)
            try FramePolicy.validateStep(f, parked, member: member, screens: s, parking: true)
            try FramePolicy.validateStep(parked, f, member: member, screens: s, parking: true)
            #expect(throws: Refusal.self) { try FramePolicy.validateStep(f, parked, member: member, screens: s, parking: false) }
        }
    }
    @Test func minimumPrimaryAndPartialParkingAreRejected() throws {
        let s = screens(.init(x: -800, width: 800, height: 1280)), f = SurfaceRect(x: -681, y: 1034, width: 240, height: 160)
        var partial = f; partial.x = -881
        var small = f; small.width = 143
        var main = f; main.x = 5
        for to in [partial, small, main] {
            #expect(throws: Refusal.self) { try FramePolicy.validateStep(f, to, member: member, screens: s, parking: true) }
        }
        let off = try FramePolicy.parkingFrame(f, screens: s)
        #expect(off.x == -1042)
        let change = FrameChange(member: member, original: f, target: off, confirmed: f, inFlight: off)
        #expect(!change.permitsRecovery(from: partial))
    }
    @Test func recoveryOnlyAcceptsAcknowledgedOrInFlightBoundaries() {
        let old = SurfaceRect(x: -700, y: 600, width: 240, height: 160)
        var first = old; first.width = 200
        var next = first; next.x += 20
        var target = next; target.height = 300
        var change = FrameChange(member: member, original: old, target: target, confirmed: first, inFlight: nil)
        #expect(change.permitsRecovery(from: old) && change.permitsRecovery(from: first))
        #expect(!change.permitsRecovery(from: next) && !change.permitsRecovery(from: target))
        change.inFlight = next
        #expect(change.permitsRecovery(from: next) && !change.permitsRecovery(from: target))
    }
    @Test func approvalRequiresTheSameMemberAndBothLiveFrameReadbacks() {
        let f = SurfaceRect(x: -680, y: 300, width: 240, height: 160)
        let approved = WindowBaseline(member: member, initial: f, confirmed: f)
        var changed = f; changed.x += 8
        let rebuilt = Member(index: member.index, id: .init(pid: member.id.pid, launch: member.id.launch,
            number: member.id.number, element: UUID()), width: 144, height: 96, session: UUID())
        #expect(approved.matches(.init(member: member, cg: f, ax: f, onScreen: true)))
        #expect(!approved.matches(.init(member: member, cg: changed, ax: changed, onScreen: true)))
        #expect(!approved.matches(.init(member: member, cg: f, ax: changed, onScreen: true)))
        #expect(!approved.matches(.init(member: rebuilt, cg: f, ax: f, onScreen: true)))
        #expect(!approved.matches(.init(member: member, cg: f, ax: f, onScreen: false)))
    }
    @Test func leaseAndDurableRecordsSurviveReopeningAndRejectCorruption() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = ["revision": 3]
        do {
            let first = try SessionFiles(dir)
            try first.persist(record, "record.json")
            #expect(throws: Refusal.self) { _ = try SessionFiles(dir) }
            withExtendedLifetime(first) {}
        }
        let reopened = try SessionFiles(dir)
        let saved: [String: Int]? = try reopened.load("record.json")
        #expect(saved == record)
        try Data("{".utf8).write(to: dir.appendingPathComponent("record.json"))
        #expect(throws: DecodingError.self) { let _: [String: Int]? = try reopened.load("record.json") }
    }
}

extension FramePolicyTests {
    @Test func minimumChangeKeepsTheUserPartitionOrRefusesBeforeWrite() throws {
        let area = SurfaceRect(width: 800, height: 800)
        let other = ManagedWindowID(pid: 9, launch: 33, number: 29, element: UUID())
        let second = ManagedMember(other, minimumWidth: 100, minimumHeight: 100, canResize: true)
        let layout = try ManagedWindowTiler(workspace: nil).adding(member.managed, in: area)
            .adding(second, in: area).adjusting(path: [], axis: .columns, ratio: 0.6, in: area)
        let newer = ManagedMember(other, minimumWidth: 320, minimumHeight: 96, canResize: true)
        let updated = try layout.refreshingRequirements([newer, member.managed], in: area)
        #expect(updated.partition == layout.partition && updated.userAdjusted && updated.workspace == nil)
        #expect(throws: WorkspaceFailure.minimumSize) {
            try layout.refreshingRequirements([member.managed, .init(other, minimumWidth: 321, minimumHeight: 96, canResize: true)], in: area)
        }
        #expect(throws: WorkspaceFailure.membership) { try layout.refreshingRequirements([second, second], in: area) }
    }
}

extension FramePolicyTests {
    @Test func productRollbackHonorsUserEditsEvenWhenGeometryMatchesTheWAL() {
        let original = SurfaceRect(width: 300, height: 200)
        let automatic = SurfaceRect(width: 600, height: 400)
        let edit = UUID()
        var change = FrameChange(member: member, original: original, target: automatic, confirmed: original,
                                 inFlight: automatic, editToken: edit)
        #expect(change.permitsProductRecovery(from: automatic, currentEdit: edit))
        #expect(!change.permitsProductRecovery(from: automatic, currentEdit: UUID()))
        #expect(!change.permitsProductRecovery(from: automatic, currentEdit: nil))
        change.editToken = nil
        #expect(!change.permitsProductRecovery(from: automatic, currentEdit: nil))
    }
}
