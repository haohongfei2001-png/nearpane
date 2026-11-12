import Foundation
import Testing
@testable import NearpaneCore

@MainActor struct ProfileClockCompatibilityTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        return dir
    }

    @Test func olderSettingsRewritePreservesClockButKeepsOlderDisplayEdits() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("host-configuration.json")
        let disk = FileConfigurationStore(url: path)
        var old = HostConfiguration()
        old.clockTimeZoneID = "Asia/Shanghai"
        try disk.save(old)
        let active = FileConfigurationStore(url: path, activeProfile: true)
        #expect(try active.load().clockTimeZoneID == old.clockTimeZoneID)
        old.edge = .left; old.clockTimeZoneID = nil
        try disk.save(old)
        let restored = try active.load()
        #expect(restored.edge == .left && restored.clockTimeZoneID == "Asia/Shanghai")
        // The import validator and another generation see only their own canonical document.
        #expect(try disk.load().clockTimeZoneID == nil)
        let other = try folder()
        defer { try? FileManager.default.removeItem(at: other) }
        let otherFile = other.appendingPathComponent("host-configuration.json")
        try FileManager.default.copyItem(at: path, to: otherFile)
        #expect(try FileConfigurationStore(url: otherFile, activeProfile: true).load().clockTimeZoneID == nil)

        let host = HostSession(store: active)
        await host.start()
        host.setClockTimeZone("Europe/Paris")
        #expect(host.configuration.clockTimeZoneID == "Europe/Paris")
        host.setClockTimeZone(nil)
        host.stop()
        old.clockTimeZoneID = "Asia/Shanghai"
        try disk.save(old)
        #expect(try active.load().clockTimeZoneID == nil)
    }

    @Test func interruptedOrInvalidClockWriteDoesNotResurrectOlderInlineValue() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("host-configuration.json")
        let clock = dir.appendingPathComponent("clock-time-zone.v1.json")
        let disk = FileConfigurationStore(url: path), active = FileConfigurationStore(url: path, activeProfile: true)
        var old = HostConfiguration()
        old.clockTimeZoneID = "Asia/Shanghai"
        try disk.save(old)
        _ = try active.load()
        // Simulate interruption before replacement and after an atomic clear.
        try Data("null".utf8).write(to: dir.appendingPathComponent(".clock-unpublished"))
        #expect(try active.load().clockTimeZoneID == "Asia/Shanghai")
        try Data("null".utf8).write(to: clock, options: .atomic)
        #expect(try active.load().clockTimeZoneID == nil)
        try Data("{".utf8).write(to: clock, options: .atomic)
        let host = HostSession(store: active)
        await host.start()
        #expect(!host.configurationProtected && host.clockNeedsAttention && host.configuration.clockTimeZoneID == nil)
        host.setSurfaceHidden(true)
        #expect(try Data(contentsOf: clock) == Data("{".utf8))
        #expect(try disk.load().clockTimeZoneID == "Asia/Shanghai" && disk.load().surfaceHidden)
        host.setClockTimeZone(nil)
        #expect(!host.clockNeedsAttention && host.configuration.clockTimeZoneID == nil)
        #expect(try active.load().clockTimeZoneID == nil)
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("clock-recovery-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: #require(backups.first)) == Data("{".utf8))
        host.stop()
        #expect(try disk.load().clockTimeZoneID == "Asia/Shanghai")
    }
}
