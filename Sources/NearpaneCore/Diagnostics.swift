import Foundation
import Observation

public enum DiagnosticCode: String, Codable, Sendable {
    case hostStarted, hostStopped, moduleStarted, moduleStopped, moduleFailed
    case eventRejected, subscriberFailed, snapshotAccepted, snapshotRejected, providerFailed
    case actionRejected, permissionChanged, configurationReadFailed, configurationWriteFailed
}

public struct DiagnosticRecord: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let code: DiagnosticCode
    public let moduleID: String?
}

/// Bounded, local, structured diagnostics: no free-form errors, paths, payloads or desktop identities.
@Observable @MainActor
public final class Diagnostics {
    public private(set) var records: [DiagnosticRecord] = []
    public let capacity: Int
    public init(capacity: Int = 200) { self.capacity = max(1, capacity) }

    public func record(_ code: DiagnosticCode, moduleID: String? = nil) {
        // Only catalog IDs are allowed to leave the runtime in diagnostics.
        let safeID = BuiltinCatalog.manifests.contains(where: { $0.id == moduleID }) ? moduleID : nil
        records.append(DiagnosticRecord(timestamp: Date(), code: code, moduleID: safeID))
        if records.count > capacity { records.removeFirst(records.count - capacity) }
    }

    public func export() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(records)
    }
}
