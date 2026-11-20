import Foundation
import NearpaneCore
@testable import NearpaneUI
import Testing

@MainActor struct NativeSidebarWindowAuditTests {
    @Test func requiresPrivateIsolatedHomeAndExplicitNumericAllowlistAndRejectsForeignEvents() throws {
        let fm = FileManager.default
        let caches = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let parent = caches.appendingPathComponent("nearpane-native-acceptance.owned")
        let home = parent.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: caches) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        #expect(NativeSidebarWindowAudit(environment: [:], cachesForTesting: caches) == nil)
        #expect(NativeSidebarWindowAudit(environment: ["CFFIXED_USER_HOME": caches.path], cachesForTesting: caches) == nil)
        let audit = try #require(NativeSidebarWindowAudit(environment: ["CFFIXED_USER_HOME": home.path], cachesForTesting: caches))
        let feed = UUID(), epoch = UUID(), listed = NativeSpaceWindow(pid: 100, birth: 101, number: 102)
        #expect(audit.sample(feed: feed, epoch: epoch, revision: 1) == nil)
        let manifest = home.appendingPathComponent("p0-window-audit-targets.json")
        try Data(#"{"version":1,"targets":[{"pid":100,"birth":101,"number":102}]}"#.utf8).write(to: manifest)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifest.path)
        #expect(audit.sample(feed: feed, epoch: epoch, revision: 1) == nil)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        let evidence = try #require(audit.sample(feed: feed, epoch: epoch, revision: 8))
        #expect(evidence.targets == [listed])
        let log = home.appendingPathComponent("p0-window-audit.jsonl")
        evidence.event("disallowed", window: .init(pid: 100, birth: 999, number: 102))
        #expect(!fm.fileExists(atPath: log.path))
        evidence.event("test", window: listed)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let record = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(record["writerPID"] as? Int32 == getpid() && record["stage"] as? String == "test")
        #expect(record["revision"] as? Int == 8 && record["uptime"] is Double)
        try fm.removeItem(at: manifest)
        try fm.createSymbolicLink(at: manifest, withDestinationURL: log)
        #expect(audit.sample(feed: feed, epoch: epoch, revision: 9) == nil)
    }
}
