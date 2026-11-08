import Foundation
import Testing
@testable import NearpaneCore

@MainActor
@Suite(.serialized)
struct ConfigurationTests {
    private func temporaryURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/test-data/\(UUID())/configuration.json")
    }

    @Test func testMissingConfigurationUsesSafeDefaultsWithoutWriting() async throws {
        let url = temporaryURL()
        let result = try FileConfigurationStore(url: url).load()
        #expect(result == HostConfiguration())
        #expect(!(FileManager.default.fileExists(atPath: url.path)))
    }

    @Test func testFileRoundTripRestoresPlacementEnabledOrderAndPinning() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileConfigurationStore(url: url)
        var configuration = HostConfiguration()
        configuration.edge = .left
        configuration.preferredDisplayID = "persistent-display-uuid"
        configuration.fixture = .threeDisplays
        configuration.modules = [.init(id: BuiltinCatalog.clock, enabled: true, pinned: false),
                                 .init(id: BuiltinCatalog.notes, enabled: false)]
        try store.save(configuration)
        #expect(try store.load() == configuration)
        configuration.edge = .right
        try store.save(configuration)
        #expect(try store.load() == configuration)
        let text = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["runtimeID", "sessionID", "transcript", "windowID", "token", "granted"] {
            #expect(!(text.contains(forbidden)))
        }
    }

    @Test func testFutureSchemaAndDuplicateIDsAreRejectedWithoutReplacingFile() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileConfigurationStore(url: url)
        try store.save(HostConfiguration())
        let before = try Data(contentsOf: url)
        var future = HostConfiguration(); future.version = 999
        #expect(throws: (any Error).self) { try store.save(future) }
        var duplicates = HostConfiguration()
        duplicates.modules = [.init(id: "a", enabled: true), .init(id: "a", enabled: false)]
        #expect(throws: (any Error).self) { try store.save(duplicates) }
        #expect(try Data(contentsOf: url) == before)
        try JSONEncoder().encode(future).write(to: url)
        #expect(throws: (any Error).self) { try store.load() }
    }

    @Test func testCorruptConfigurationIsPreservedThroughHostChanges() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("{broken-file-retain-me".utf8)
        try corrupt.write(to: url)
        let host = HostSession(store: FileConfigurationStore(url: url))
        await host.start()
        #expect(host.configurationProtected)
        host.handle(.setEnabled(BuiltinCatalog.notes, true))
        host.setPlacement(edge: .left, displayID: nil)
        host.stop()
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test func testSaveFailureDoesNotTerminateHostOrEraseInMemoryConfiguration() async {
        let host = HostSession(store: FailingSaveStore())
        await host.start()
        host.setPlacement(edge: .left, displayID: "missing-display")
        #expect(host.configurationSaveFailed)
        #expect(host.isRunning)
        #expect(host.configuration.preferredDisplayID == "missing-display")
        #expect(host.configuration.edge == .left)
        host.stop()
    }
}

@MainActor
private struct FailingSaveStore: ConfigurationStore {
    func load() throws -> HostConfiguration { HostConfiguration() }
    func save(_ configuration: HostConfiguration) throws { throw SampleFailure.injected }
}
