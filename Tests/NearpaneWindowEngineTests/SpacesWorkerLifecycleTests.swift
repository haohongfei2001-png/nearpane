import Darwin
import Foundation
import NearpaneCore
import Testing
@testable import NearpaneWindowEngine

struct SpacesWorkerLifecycleTests {
    private typealias Lifecycle = SpacesWorkerLifecycle

    private func owner() -> StageEngineOwner {
        .init(spacesCandidate: .init(osBuild: "26A428", engineRevision: String(repeating: "1", count: 40),
            hostCDHash: String(repeating: "2", count: 40), hardware: "fixture", topology: "fixture",
            windowClass: "ordinary-standard", sipEnabled: true), generation: UUID(), evidence: UUID())
    }

    private func record(owner: StageEngineOwner, boot: UUID = UUID()) -> Lifecycle.Record {
        let nonce = UUID()
        return .init(schema: 1, owner: owner, nonce: nonce, bootID: boot,
            host: .init(pid: 700_001, birth: 101, executable: "/fixture/Nearpane.app/Contents/MacOS/NearpaneHost"),
            worker: .init(pid: 700_002, birth: 102, executable: "/fixture/Nearpane.app/Contents/Helpers/NearpaneSpacesEngine"),
            diagnostic: "spaces-worker-" + nonce.uuidString.lowercased() + ".jsonl")
    }

    private func terminal(_ record: Lifecycle.Record, replacing: [String: Any] = [:]) throws -> Data {
        var row: [String: Any] = ["event": "spacesWorker", "phase": "released", "lifecycleNonce": record.nonce.uuidString,
            "pid": record.worker.pid, "birth": record.worker.birth, "parentPID": record.host.pid,
            "parentBirth": record.host.birth, "transport": 0, "owned": 0, "flags": 0,
            "engineDestroyed": true, "pendingDrained": true]
        row.merge(replacing) { _, new in new }
        var data = try JSONSerialization.data(withJSONObject: row); data.append(10)
        return data
    }

    @Test func aHomeWindowAndAnEmptyWALCannotSubstituteForTheExactWorkerTerminal() throws {
        let record = record(owner: owner()), good = try terminal(record)
        #expect(Lifecycle.terminal(good, for: record))
        let replacements: [[String: Any]] = [
            ["phase": "release-pending"], ["lifecycleNonce": UUID().uuidString], ["birth": record.worker.birth + 1],
            ["parentBirth": record.host.birth + 1], ["engineDestroyed": false], ["pendingDrained": false],
            ["transport": 2], ["owned": 1], ["flags": 128], ["engineDestroyed": 1]
        ]
        for replacement in replacements {
            #expect(!Lifecycle.terminal(try terminal(record, replacing: replacement), for: record))
        }
        #expect(!Lifecycle.terminal(Data(good.dropLast()), for: record))
        #expect(!Lifecycle.terminal(good + (try terminal(record, replacing: ["phase": "release-pending"])), for: record))
    }

    @Test func currentWorkerCannotBeMistakenForAnExitedGeneration() throws {
        let live = try Lifecycle.ProcessStamp.read(getpid())
        #expect(!Lifecycle.exited(live))
        let older = Lifecycle.ProcessStamp(pid: live.pid, birth: live.birth - 1, executable: live.executable)
        #expect(Lifecycle.exited(older))
    }

    @Test func differentBootRetiresOnlyTheMatchingPrivateOwnerAssociation() throws {
        let profile = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: profile) }
        let owner = owner(), current = try #require(Lifecycle.bootID()), previous = UUID()
        #expect(previous != current)
        let original = record(owner: owner, boot: previous)
        let file = Lifecycle.location(owner: owner, profile: profile)
        func save(_ record: Lifecycle.Record) throws {
            try JSONEncoder().encode(record).write(to: file)
            #expect(chmod(file.path, 0o600) == 0)
        }
        try save(original)
        #expect(Lifecycle.completed(owner: owner, profile: profile)?.previousBoot == true)
        let wrong = StageEngineOwner(spacesCandidate: owner.environment, generation: owner.generation, evidence: UUID())
        #expect(Lifecycle.completed(owner: wrong, profile: profile) == nil)
        // On the same boot an absent terminal is still unknown, even when the
        // recorded PIDs no longer exist and the window requirements are empty.
        try save(record(owner: owner, boot: current))
        #expect(Lifecycle.completed(owner: owner, profile: profile) == nil)
        try Data("{\"schema\":1}".utf8).write(to: file)
        #expect(Lifecycle.completed(owner: owner, profile: profile) == nil)
    }
}
