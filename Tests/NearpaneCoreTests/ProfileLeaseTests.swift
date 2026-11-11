import Foundation
import Darwin
import Testing
@testable import NearpaneCore

struct ProfileLeaseTests {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let generation = root.appendingPathComponent("generations/" + UUID().uuidString.lowercased())
        for leaf in ["Nearpane/Voice/Saytile.sqlite", "Nearpane/Voice/.writer-lock", "Nearpane/host-configuration.json",
                     "Riftlet/instance.lock", "Riftlet/queue.sqlite", "profile.version"] {
            let file = generation.appendingPathComponent(leaf)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (leaf == "profile.version" ? ProfileLease.marker : Data()).write(to: file)
        }
        try index(root, generation.lastPathComponent)
        return (root, generation)
    }

    private func index(_ root: URL, _ active: String, format: Int = 1) throws {
        let obj: [String: Any] = ["format": format, "active": active, "previous": NSNull(), "imports": [String: String]()]
        try JSONSerialization.data(withJSONObject: obj).write(to: root.appendingPathComponent("profile-index.json"), options: .atomic)
    }

    @Test func anotherHostCanOpenOnlyAfterTheFirstLeaseEnds() throws {
        let (root, generation) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let first = try ProfileLease(root: root)
            let opened = try first.activeGeneration()
            withExtendedLifetime(first) {
                #expect(opened.path == generation.path)
                #expect(throws: (any Error).self) { try ProfileLease(root: root) }
            }
        }
        let second = try ProfileLease(root: root)
        #expect(try second.activeGeneration().path == generation.path)
    }

    @Test func drainedOwnerReleasesLockEvenWithInheritedDescriptionAwaitingExec() throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var first: ProfileLease? = try ProfileLease(root: root)
        let lock = root.appendingPathComponent("writer.lock")
        var identity = stat()
        #expect(stat(lock.path, &identity) == 0)
        let inherited = try withExtendedLifetime(first) {
            let fd = try #require((3..<getdtablesize()).first { descriptor in
                var current = stat()
                return fstat(descriptor, &current) == 0 && current.st_dev == identity.st_dev && current.st_ino == identity.st_ino
            })
            return fcntl(fd, F_DUPFD_CLOEXEC, 3)
        }
        try #require(inherited >= 0)
        defer { close(inherited) }
        #expect(throws: (any Error).self) { try ProfileLease(root: root) }
        first = nil
        let restarted = try ProfileLease(root: root)
        withExtendedLifetime(restarted) {
            #expect(throws: (any Error).self) { try ProfileLease(root: root) }
        }
    }

    @Test func unresolvedTransactionsUnknownFormatAndReplacedStoresRefuseOpen() throws {
        let (root, generation) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try ProfileLease(root: root)
        let pending = root.appendingPathComponent("transaction.json")
        try Data().write(to: pending)
        #expect(throws: (any Error).self) { try lease.activeGeneration() }
        try FileManager.default.removeItem(at: pending)
        try index(root, generation.lastPathComponent, format: 2)
        #expect(throws: (any Error).self) { try lease.activeGeneration() }
        try index(root, "../other")
        #expect(throws: (any Error).self) { try lease.activeGeneration() }
        try index(root, generation.lastPathComponent)
        let database = generation.appendingPathComponent("Riftlet/queue.sqlite")
        try FileManager.default.removeItem(at: database)
        #expect(throws: (any Error).self) { try lease.activeGeneration() }
        try FileManager.default.createSymbolicLink(at: database, withDestinationURL: generation.appendingPathComponent("profile.version"))
        #expect(throws: (any Error).self) { try lease.activeGeneration() }
    }
}
