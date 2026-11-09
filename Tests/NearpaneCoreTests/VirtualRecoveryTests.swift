import Darwin
import Foundation
import Testing
@testable import NearpaneCore

private final class FixtureWindows: VirtualFixtureBackend {
    let url: URL
    var afterReplace: (() throws -> Void)?
    init(_ directory: URL) { url = directory.appendingPathComponent("synthetic-windows.json") }
    func load() throws -> [VirtualWindowState] { try JSONDecoder().decode([VirtualWindowState].self, from: Data(contentsOf: url)) }
    func save(_ rows: [VirtualWindowState]) throws { try JSONEncoder().encode(rows).write(to: url, options: .atomic) }
    func observe(_ id: ManagedWindowID) throws -> VirtualWindowState? { try load().first { $0.id == id } }
    func replace(_ expected: VirtualWindowState, with new: VirtualWindowState) throws {
        var rows = try load()
        guard let i = rows.firstIndex(of: expected), new.id == expected.id else { throw WorkspaceFailure.conflict }
        rows[i] = new; try save(rows)
        try afterReplace?()
    }
}

struct VirtualRecoveryTests {
    private func fixture(_ directory: URL) throws -> (VirtualRecoveryRecord, FixtureWindows) {
        let area = SurfaceRect(width: 840, height: 700)
        var groups = [VirtualGroup](), changes = [VirtualWindowChange]()
        for i in 0..<2 {
            let member = WorkspaceLayoutTests().member(i + 1), id = UUID()
            let layout = try ManagedWindowTiler(workspace: .virtual(id)).adding(member, in: area)
            groups.append(.init(id: id, display: "fixture", area: area, layout: layout))
            changes.append(.init(original: .init(id: member.id, display: "fixture", workspace: nil,
                frame: .init(x: Double(i * 20), y: 10, width: 200, height: 300), visible: true, zOrder: i, ordinary: true),
                target: .init(id: member.id, display: "fixture", workspace: id,
                              frame: i == 0 ? area : .init(x: -2000, y: 0, width: 840, height: 700),
                              visible: i == 0, zOrder: i, ordinary: true)))
        }
        let backend = FixtureWindows(directory)
        try backend.save(changes.map(\.original))
        return (.init(version: 1, transaction: UUID(), active: groups[0].id, groups: groups, changes: changes), backend)
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
        let dir = try directory(), owner = try VirtualWorkspaceExperiment(directory: dir)
        let (r, world) = try fixture(dir)
        try owner.begin(r, on: world)
        var changed = try world.load()
        let old = changed[1]
        changed[1] = .init(id: old.id, display: "another-display", workspace: old.workspace, frame: old.frame,
                           visible: true, zOrder: 0, ordinary: true)
        try world.save(changed)
        #expect(throws: WorkspaceFailure.recoveryRequired) { try owner.restore(on: world) }
        #expect(try world.load() == changed)
        changed.removeLast(); try world.save(changed)
        #expect(throws: WorkspaceFailure.recoveryRequired) { try owner.restore(on: world) }
        #expect(try owner.pending() == r)
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
        let dir = try directory(), child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var arguments = ["--testing-library", "swift-testing", "--filter", "VirtualRecoveryTests/processKillBetweenWindowWriteAndReceiptRecovers"]
        if let flag = CommandLine.arguments.firstIndex(of: "--test-bundle-path"), flag + 1 < CommandLine.arguments.count {
            arguments.insert(contentsOf: ["--test-bundle-path", CommandLine.arguments[flag + 1]], at: 0)
        }
        child.arguments = arguments
        child.environment = env.merging(["NEARPANE_KILL_FIXTURE": dir.path]) { _,new in new }
        let output = dir.appendingPathComponent("child.log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let log = try FileHandle(forWritingTo: output)
        defer { try? log.close() }
        child.standardOutput = log; child.standardError = log
        try child.run(); child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
        let reopened = try VirtualWorkspaceExperiment(directory: dir), world = FixtureWindows(dir)
        let r = try #require(try reopened.pending())
        #expect(try world.load() == [r.changes[0].target, r.changes[1].original])
        try reopened.restore(on: world)
        #expect(try world.load() == r.changes.map(\.original))
        #expect(try reopened.pending() == nil)
    }
}
