import Foundation
import Testing
@testable import NearpaneCore

@MainActor
@Suite(.serialized)
struct ConfigurationTests {
    @Test func failedWindowRuleSaveRetainsDraftForExplicitRetry() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileConfigurationStore(url: url), host = HostSession(store: store)
        await host.start()
        defer { host.stop() }
        // A regular file's parent cannot be used as a directory. Exercise a real failed atomic save.
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: parent, options: .withoutOverwriting)
        var rules = host.configuration.workspaces
        rules.excludedApps.insert("test.excluded")
        #expect(!host.setWorkspacePreferences(rules))
        #expect(host.unsavedWorkspacePreferences == rules && host.configuration.workspaces != rules)
        try FileManager.default.removeItem(at: parent)
        #expect(host.setWorkspacePreferences(host.workspacePreferencesDraft))
        let persisted = try store.load().workspaces
        #expect(host.unsavedWorkspacePreferences == nil && persisted == rules)
    }
    @Test func preVisibilityConfigurationStillLoadsAndOversizedInputIsProtected() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileConfigurationStore(url: url)
        try store.save(.init())
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["surfaceHidden"] = nil
        object["candidateTrayConnected"] = nil
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(try !store.load().surfaceHidden)
        #expect(try store.load().candidateTrayConnected)
        let oversized = Data(repeating: 32, count: 200_000)
        try oversized.write(to: url)
        let host = HostSession(store: store)
        await host.start()
        host.setSurfaceHidden(true)
        #expect(host.configurationProtected)
        #expect(try Data(contentsOf: url) == oversized)
        host.stop()
    }
    @Test func restartKeepsExplicitTrayDisconnectAndSpaceDismissal() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileConfigurationStore(url: url)
        let host = HostSession(store: store)
        await host.start()
        var secondary = DisplaySettings()
        secondary.policy = .pinned
        secondary.spacesDismissed = true
        host.setDisplaySettings(secondary, id: "secondary")
        host.setCandidateTrayConnected(false)
        host.stop()

        let config = try store.load()
        var panels = MultiDisplayPresentationCoordinator()
        let rect = SurfaceRect(width: 900, height: 700)
        let screens = ["resident", "secondary"].map { ScreenGeometry(id: $0, frame: rect, visibleFrame: rect) }
        let plans = panels.resolve(screens: screens, preferred: "resident", settings: config.displays,
                                   demand: ["secondary": .init(windows: 4, complete: true)], hidden: false,
                                   voice: true, tray: true, spacesEnabled: true, uptime: 1)
        #expect(!config.candidateTrayConnected)
        #expect(plans.first(where: { $0.id == "secondary" })?.content == .hidden)
    }

    private func temporaryURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(ProcessInfo.processInfo.environment["NEARPANE_TEST_DIRECTORY"] ?? ".build/test-data").appendingPathComponent("\(UUID())/configuration.json")
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
