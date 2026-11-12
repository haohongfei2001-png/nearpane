import Foundation
import Darwin

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
    /// Missing in early v1 configurations, which always opened visible.
    public var surfaceHidden: Bool = false
    public var candidateTrayConnected = true
    public var experimentalSpaceObservation = false
    public var workspaces = WorkspacePreferences()
    public var displays: [String: DisplaySettings] = [:]
    public var modules: [ModulePreference] = []
    public var clockTimeZoneID: String?
    public var fixture: DesktopFixture = .internalScopes3Plus1

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        edge = try c.decode(SurfaceEdge.self, forKey: .edge)
        preferredDisplayID = try c.decodeIfPresent(String.self, forKey: .preferredDisplayID)
        candidateTrayConnected = try c.decodeIfPresent(Bool.self, forKey: .candidateTrayConnected) ?? true
        surfaceHidden = try c.decodeIfPresent(Bool.self, forKey: .surfaceHidden) ?? false
        experimentalSpaceObservation = try c.decodeIfPresent(Bool.self, forKey: .experimentalSpaceObservation) ?? false
        workspaces = try c.decodeIfPresent(WorkspacePreferences.self,forKey:.workspaces) ?? .init()
        displays = try c.decodeIfPresent([String: DisplaySettings].self, forKey: .displays) ?? [:]
        modules = try c.decode([ModulePreference].self, forKey: .modules)
        let clockZone = try c.decodeIfPresent(String.self, forKey: .clockTimeZoneID)
        clockTimeZoneID = clockZone.flatMap { TimeZone.knownTimeZoneIdentifiers.contains($0) ? $0 : nil }
        fixture = try c.decode(DesktopFixture.self, forKey: .fixture)
    }

    public func validated() throws -> Self {
        guard version == Self.schemaVersion else { throw ConfigurationError.unsupportedVersion }
        guard workspaces.excludedApps.allSatisfy({ !$0.isEmpty && $0.count <= 255 }), displays.count <= 64, displays.allSatisfy({ key, value in
            !key.isEmpty && key.count <= 120 && value.toolAnchor?.anchor.geometry.isValid != false && value.floatingPosition?.x.isFinite != false && value.floatingPosition?.y.isFinite != false && value.measures.allSatisfy { metric, measure in
                metric == .panelWidth || metric == .panelHeight ? measure.validPanelExtent : measure.valid
            }
        }), modules.count <= 100,
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
    func saveClock(_ configuration: HostConfiguration) throws
    var clockNeedsAttention: Bool { get }
}
extension ConfigurationStore {
    public var clockNeedsAttention: Bool { false }
    public func saveClock(_ configuration: HostConfiguration) throws { try save(configuration) }
}

@MainActor
public final class FileConfigurationStore: ConfigurationStore {
    public let url: URL
    private let clockFile: URL?
    public private(set) var clockNeedsAttention = false
    private var inlineClock: String?
    public init(url: URL, activeProfile: Bool = false) {
        self.url = url
        clockFile = activeProfile ? url.deletingLastPathComponent().appendingPathComponent("clock-time-zone.v1.json") : nil
    }

    public func load() throws -> HostConfiguration {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
            return HostConfiguration()
        }
        defer { try? handle.close() }
        let limit = 128 * 1024
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ConfigurationError.invalid }
        var configuration = try JSONDecoder().decode(HostConfiguration.self, from: data).validated()
        inlineClock = configuration.clockTimeZoneID
        clockNeedsAttention = false
        if let clockFile {
            do { configuration.clockTimeZoneID = try readClock(at: clockFile, configuration: configuration) }
            catch {
                clockNeedsAttention = true
                configuration.clockTimeZoneID = nil
            }
        }
        return configuration
    }

    private func readClock(at file: URL, configuration: HostConfiguration) throws -> String? {
        // Staged import validation uses the default store and sees exactly its canonical document.
        try ProfileLease.checkPath(file)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            guard errno == ENOENT else { throw CocoaError(.fileReadNoPermission) }
            if configuration.clockTimeZoneID != nil { try saveClock(configuration) }
            return configuration.clockTimeZoneID
        }
        let reader = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? reader.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_size <= 256 else { throw ConfigurationError.invalid }
        let bytes = try reader.read(upToCount: 257) ?? Data()
        guard bytes.count <= 256 else { throw ConfigurationError.invalid }
        let zone = try JSONDecoder().decode(String?.self, from: bytes)
        guard zone.map(TimeZone.knownTimeZoneIdentifiers.contains) ?? true else { throw ConfigurationError.invalid }
        return zone
    }

    public func saveClock(_ configuration: HostConfiguration) throws {
        guard let clockFile else { try save(configuration); return }
        let zone = configuration.clockTimeZoneID
        guard zone.map(TimeZone.knownTimeZoneIdentifiers.contains) ?? true else { throw ConfigurationError.invalid }
        try ProfileLease.checkPath(clockFile)
        if clockNeedsAttention {
            var info = stat()
            if lstat(clockFile.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { throw ConfigurationError.invalid }
                // Preserve the bad record until explicit reset. A hard link retains even a large
                // bad file without copying its contents. The atomic replacement unlinks only our name.
                let backup = clockFile.deletingLastPathComponent().appendingPathComponent("clock-recovery-\(info.st_dev)-\(info.st_ino)")
                if info.st_nlink == 1 {
                    guard link(clockFile.path, backup.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
                } else {
                    var saved = stat()
                    guard info.st_nlink == 2, lstat(backup.path, &saved) == 0,
                          saved.st_dev == info.st_dev, saved.st_ino == info.st_ino else { throw ConfigurationError.invalid }
                }
            } else if errno != ENOENT { throw CocoaError(.fileReadNoPermission) }
        }
        // A single atomic replacement is the entire clock change. JSON null records a clear even
        // if an older Host still has an inline value. No authority or other settings live here.
        try JSONEncoder().encode(zone).write(to: clockFile, options: .atomic)
        clockNeedsAttention = false
    }

    public func save(_ configuration: HostConfiguration) throws {
        var value = try configuration.validated()
        if clockNeedsAttention { value.clockTimeZoneID = inlineClock }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 128 * 1024 else { throw ConfigurationError.invalid }
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
