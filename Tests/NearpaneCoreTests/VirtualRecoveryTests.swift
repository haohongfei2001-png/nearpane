import Darwin
import Foundation
import Testing

@testable import NearpaneCore

private final class FixtureWindows: VirtualFixtureBackend {
    let url: URL
    var afterReplace: (() throws -> Void)?
    init(_ directory: URL) { url = directory.appendingPathComponent("synthetic-windows.json") }
    func load() throws -> [VirtualWindowState] {
        try JSONDecoder().decode([VirtualWindowState].self, from: Data(contentsOf: url))
    }
    func inventory() throws -> [VirtualWindowState] { try load() }
    func save(_ rows: [VirtualWindowState]) throws { try JSONEncoder().encode(rows).write(to: url, options: .atomic) }
    func observe(_ id: ManagedWindowID) throws -> VirtualWindowState? { try load().first { $0.id == id } }
    func replace(_ expected: VirtualWindowState, with new: VirtualWindowState) throws {
        var rows = try load()
        guard let i = rows.firstIndex(of: expected), new.id == expected.id else { throw WorkspaceFailure.conflict }
        rows[i] = new
        try save(rows)
        try afterReplace?()
    }
}

struct VirtualRecoveryTests {
    private func fixture(_ directory: URL) throws -> (VirtualRecoveryRecord, FixtureWindows) {
        let area = SurfaceRect(width: 840, height: 700)
        var groups = [VirtualGroup]()
        var changes = [VirtualWindowChange]()
        for i in 0..<2 {
            let member = WorkspaceLayoutTests().member(i + 1)
            let id = UUID()
            let layout = try ManagedWindowTiler(workspace: .virtual(id)).adding(member, in: area)
            groups.append(.init(id: id, display: "fixture", area: area, layout: layout))
            changes.append(
                .init(
                    original: .init(
                        id: member.id, display: "fixture", workspace: nil,
                        frame: .init(x: Double(i * 20), y: 10, width: 200, height: 300), visible: true, zOrder: i,
                        ordinary: true),
                    target: .init(
                        id: member.id, display: "fixture", workspace: id,
                        frame: i == 1 ? area : .init(x: -2000, y: 0, width: 840, height: 700),
                        visible: i == 1, zOrder: i, ordinary: true)))
        }
        let backend = FixtureWindows(directory)
        try backend.save(changes.map(\.original))
        return (.init(version: 1, transaction: UUID(), active: groups[1].id, groups: groups, changes: changes), backend)
    }
    private func directory() throws -> URL {
        let root = ProcessInfo.processInfo.environment["NEARPANE_TEST_DIRECTORY"] ?? ".build/test-data"
        let dir = URL(fileURLWithPath: root).appendingPathComponent("virtual-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    @Test func parkedMembersAndCustomLayoutsSurviveReopenAndExclusiveOwnership() throws {
        let dir = try directory()
        var ledger: VirtualWorkspaceExperiment? = try .init(directory: dir)
        let (r, world) = try fixture(dir)
        try ledger?.begin(r, on: world)
        #expect(try world.load() == r.changes.map(\.target))
        #expect(throws: WorkspaceFailure.conflict) { try VirtualWorkspaceExperiment(directory: dir) }
        ledger = nil
        let reopened = try VirtualWorkspaceExperiment(directory: dir)
        #expect(try reopened.pending() == r)
        try reopened.restore(on: world)
        try reopened.restore(on: world)
        #expect(try world.load() == r.changes.map(\.original))
    }
    @Test func thirdPartyChangesAndReusedWindowNeverOverwritten() throws {
        let dir = try directory()
        let owner = try VirtualWorkspaceExperiment(directory: dir)
        let (r, world) = try fixture(dir)
        try owner.begin(r, on: world)
        var changed = try world.load()
        let old = changed[1]
        changed[1] = .init(
            id: old.id, display: "another-display", workspace: old.workspace, frame: old.frame,
            visible: true, zOrder: 0, ordinary: true)
        try world.save(changed)
        #expect(throws: WorkspaceFailure.recoveryRequired) { try owner.restore(on: world) }
        #expect(try world.load() == [r.changes[0].original, changed[1]])
        changed.removeLast()
        try world.save(changed)
        #expect(throws: WorkspaceFailure.recoveryRequired) { try owner.restore(on: world) }
        #expect(try owner.pending() == r)
    }
    @Test func actualVirtualFixtureDropPersistsMembershipThenCleansOnlyEmptySource() throws {
        let dir = try directory()
        let (r, world) = try fixture(dir)
        let ledger = try VirtualWorkspaceExperiment(directory: dir)
        let old = r.changes.map(\.target)
        try world.save(old)
        let from = WorkspaceID.virtual(r.groups[0].id)
        let to = WorkspaceID.virtual(r.groups[1].id)
        let member = r.groups[0].layout.members[0]
        let session = UUID()
        let rows = Dictionary(
            uniqueKeysWithValues: r.groups.map { g in
                (
                    WorkspaceID.virtual(g.id),
                    WorkspaceRowState(id: .virtual(g.id), display: g.display, area: g.area, layout: g.layout)
                )
            })
        let grant = WorkspaceCapabilities(
            mode: .virtual, build: "fixture", displayID: "fixture", actions: [.tile, .moveMember, .removeWorkspace],
            evidence: .isolated)
        let snap = WorkspaceSnapshot(
            session: session, revision: 1, mode: .virtual, build: "fixture", validUntil: 10, rows: rows,
            grants: ["fixture": grant], stable: true)
        let virtual = VirtualWorkspacesProvider(experiment: .init(ledger: ledger, world: world, active: r.active))
        var route = WorkspaceGestureRouter(isolated: true)
        route.down(row: from, window: member.id, x: 0, y: 0, snapshot: snap)
        #expect(
            try route.release(
                on: to, x: 15, y: 0, current: snap, uptime: 5, native: NativeSpacesProvider(), virtual: virtual)
                == .move(member.id, from: from, to: to))
        let record = try #require(try ledger.pending())
        #expect(try world.load().allSatisfy { $0.workspace == r.groups[1].id && $0.visible })
        let afterRows = Dictionary(
            uniqueKeysWithValues: record.groups.map { g in
                (
                    WorkspaceID.virtual(g.id),
                    WorkspaceRowState(id: .virtual(g.id), display: g.display, area: g.area, layout: g.layout)
                )
            })
        let after = WorkspaceSnapshot(
            session: session, revision: 2, mode: .virtual, build: "fixture", validUntil: 10, rows: afterRows,
            grants: ["fixture": grant], stable: true)
        let e = EmptySourceEvidence(
            from: from, departed: member.id, session: session, beforeRevision: 1, afterRevision: 2, wasMember: true,
            causedByCloseOrMove: true, completeAllMembers: true, remaining: [], active: false, protectedOrFullscreen: false,
            otherDesktopAvailable: true)
        #expect(try ledger.removeEmptySource(e, current: after, uptime: 5, on: world) == .deleted(from))
        #expect(try ledger.pending()?.removedGroups.map(\.id) == [r.groups[0].id])
        try ledger.restore(on: world)
        #expect(try world.load() == old)
    }

    @Test func processKillBetweenWindowWriteAndReceiptRecovers() throws {
        let env = ProcessInfo.processInfo.environment
        if let path = env["NEARPANE_KILL_FIXTURE"] {
            let dir = URL(fileURLWithPath: path)
            let (r, world) = try fixture(dir)
            let owner = try VirtualWorkspaceExperiment(directory: dir)
            world.afterReplace = { kill(getpid(), SIGKILL) }
            try owner.begin(r, on: world)
            Issue.record("synthetic writer survived SIGKILL")
            return
        }
        let dir = try directory()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var arguments = [
            "--testing-library", "swift-testing", "--filter",
            "VirtualRecoveryTests/processKillBetweenWindowWriteAndReceiptRecovers",
        ]
        if let flag = CommandLine.arguments.firstIndex(of: "--test-bundle-path"), flag + 1 < CommandLine.arguments.count {
            arguments.insert(contentsOf: ["--test-bundle-path", CommandLine.arguments[flag + 1]], at: 0)
        }
        child.arguments = arguments
        child.environment = env.merging(["NEARPANE_KILL_FIXTURE": dir.path]) { _, new in new }
        let output = dir.appendingPathComponent("child.log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let log = try FileHandle(forWritingTo: output)
        defer { try? log.close() }
        child.standardOutput = log
        child.standardError = log
        try child.run()
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
        let reopened = try VirtualWorkspaceExperiment(directory: dir)
        let world = FixtureWindows(dir)
        let r = try #require(try reopened.pending())
        #expect(try world.load() == [r.changes[0].target, r.changes[1].original])
        try reopened.restore(on: world)
        #expect(try world.load() == r.changes.map(\.original))
        #expect(try reopened.pending() == nil)
    }
}

extension VirtualRecoveryTests {
    @Test func newVirtualGroupIsReopenedFromDiskAndExplicitQuitKeepsUserIntent() throws {
        let dir = try directory()
        let (r, world) = try fixture(dir)
        let source = r.groups[1]
        let born = WorkspaceLayoutTests().member(9)
        let bornState = VirtualWindowState(
            id: born.id, display: source.display,
            workspace: nil, frame: .init(x: 3, y: 4, width: 120, height: 80), visible: true, zOrder: 2, ordinary: true)
        try world.save(r.changes.map(\.target) + [bornState])
        let ledger = try VirtualWorkspaceExperiment(directory: dir)
        let id = WorkspaceID.virtual(source.id)
        let caps = WorkspaceCapabilities(
            mode: .virtual, build: "fixture", displayID: source.display, actions: [.tile, .moveMember, .createWorkspace],
            evidence: .isolated)
        let rows = Dictionary(
            uniqueKeysWithValues: r.groups.map { g in
                (
                    WorkspaceID.virtual(g.id),
                    WorkspaceRowState(id: .virtual(g.id), display: g.display, area: g.area, layout: g.layout)
                )
            })
        let previous = WorkspaceSnapshot(
            session: UUID(), revision: 1, mode: .virtual, build: "fixture", validUntil: 8, rows: rows,
            grants: [source.display: caps], stable: true)
        var sample = WorkspaceSnapshot(
            session: previous.session, revision: 2, mode: .virtual, build: "fixture", validUntil: 8, rows: rows,
            grants: [source.display: caps], stable: true)
        let live = LiveManagedWindow(
            member: born, bundle: "fixture.app", workspace: id, display: source.display, frame: bornState.frame,
            ordinary: true)
        sample.observed[born.id] = live
        var router = NewWindowAdmissionCoordinator()
        try router.appeared(
            live, role: .ordinary, previous: previous, snapshot: sample, uptime: 4, isolated: true,
            adapter: VirtualWorkspacesProvider(experiment: .init(ledger: ledger, world: world, active: source.id)))
        let committed = try #require(try ledger.pending())
        #expect(committed.groups.count == 3 && !r.groups.map(\.id).contains(committed.active))
        #expect(try world.observe(born.id)?.workspace == committed.active)
        try ledger.restore(on: world)
        #expect(try world.observe(born.id) == bornState)

        let members = [r.groups[0].layout.members[0], r.groups[1].layout.members[0]]
        let group = UUID()
        let area = SurfaceRect(width: 700, height: 1000)
        let full = SurfaceRect(width: 800, height: 1000)
        var custom = ManagedWindowTiler(workspace: .virtual(group))
        for m in members { custom = try custom.adding(m, in: area) }
        custom = try custom.adjusting(path: [], axis: .columns, ratio: 0.7, in: area)
        let frames = try custom.frames(in: area)
        let originals = r.changes.map(\.original)
        try world.save(originals)
        let changes = try originals.map { w in
            VirtualWindowChange(
                original: w,
                target: .init(
                    id: w.id, display: "fixture", workspace: group,
                    frame: try #require(frames[w.id]), visible: true, zOrder: w.zOrder, ordinary: true))
        }
        try ledger.begin(
            .init(
                version: 1, transaction: UUID(), active: group,
                groups: [.init(id: group, display: "fixture", area: area, layout: custom)], changes: changes), on: world)
        try ledger.quit(usable: ["fixture": full], preferences: .init(), bundles: [:], on: world)
        #expect(try world.load().map(\.frame.width) == [560, 240])
        #expect(try world.load().allSatisfy { $0.workspace == nil && $0.visible })
    }
}
