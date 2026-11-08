import Foundation

public struct ModulePreference: Codable, Equatable, Sendable {
    public var id: String
    public var enabled: Bool
    public var pinned: Bool

    public init(id: String, enabled: Bool, pinned: Bool = true) {
        self.id = id; self.enabled = enabled; self.pinned = pinned
    }
}

public struct HostConfiguration: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public var version = schemaVersion
    public var edge: SurfaceEdge = .right
    public var preferredDisplayID: String?
    public var modules: [ModulePreference] = []
    public var fixture: DesktopFixture = .internalScopes3Plus1

    public init() {}

    public func validated() throws -> Self {
        guard version == Self.schemaVersion else { throw ConfigurationError.unsupportedVersion }
        guard modules.count <= 100,
              Set(modules.map(\.id)).count == modules.count,
              modules.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 120 }),
              (preferredDisplayID?.count ?? 0) <= 120 else { throw ConfigurationError.invalid }
        return self
    }
}

public enum ConfigurationError: Error { case unsupportedVersion, invalid }

@MainActor
public protocol ConfigurationStore {
    func load() throws -> HostConfiguration
    func save(_ configuration: HostConfiguration) throws
}

@MainActor
public final class FileConfigurationStore: ConfigurationStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> HostConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return HostConfiguration() }
        let data = try Data(contentsOf: url)
        guard data.count <= 128 * 1024 else { throw ConfigurationError.invalid }
        return try JSONDecoder().decode(HostConfiguration.self, from: data).validated()
    }

    public func save(_ configuration: HostConfiguration) throws {
        let value = try configuration.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

@MainActor
public final class MemoryConfigurationStore: ConfigurationStore {
    public private(set) var value: HostConfiguration
    public init(_ value: HostConfiguration = HostConfiguration()) { self.value = value }
    public func load() throws -> HostConfiguration { try value.validated() }
    public func save(_ configuration: HostConfiguration) throws { value = try configuration.validated() }
}
