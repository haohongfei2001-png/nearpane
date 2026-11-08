import Foundation
import CryptoKit
import Darwin

public struct OperatorMarker: Codable, Equatable {
    public enum Kind: String, Codable { case baseline, beforeAction, afterAction, restored, note, stop }
    public enum Action: String, Codable { case none, nativeSpaceChange, settingChange, sessionRestart, restore, visibleObservation }
    public enum DisplayRole: String, Codable { case A, B, both, unspecified }
    public var kind: Kind
    public var action: Action
    public var display: DisplayRole
    public var trial: Int?
    public var reportedSeparateSpaces: Bool?
    public var operatorTimestamp: String?
    public var note: String?
    public init(kind: Kind, action: Action = .none, display: DisplayRole = .unspecified,
                trial: Int? = nil, reportedSeparateSpaces: Bool? = nil,
                operatorTimestamp: String? = nil, note: String? = nil) {
        self.kind = kind; self.action = action; self.display = display; self.trial = trial
        self.reportedSeparateSpaces = reportedSeparateSpaces; self.operatorTimestamp = operatorTimestamp; self.note = note
    }
    public static func parse(_ data: Data) throws -> OperatorMarker {
        guard data.count <= 8192 else { throw ObserverError.invalidMarker }
        let marker = try JSONDecoder().decode(Self.self, from: data)
        guard marker.trial.map({ (1...100).contains($0) }) ?? true,
              (marker.note?.utf8.count ?? 0) <= 4096 else { throw ObserverError.invalidMarker }
        if let date = marker.operatorTimestamp {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard formatter.date(from: date) != nil else { throw ObserverError.invalidMarker }
        }
        return marker
    }
}

// A bounded newline decoder: an overlong input is discarded through the next newline,
// without logging its content or accidentally interpreting its tail as another marker.
public struct MarkerLines {
    private var pending = Data()
    private var discarding = false
    public init() {}
    public mutating func consume(_ bytes: Data) -> [Result<OperatorMarker, ObserverError>] {
        var results: [Result<OperatorMarker, ObserverError>] = []
        for byte in bytes {
            if byte == 10 {
                if discarding { results.append(.failure(.invalidMarker)) }
                else if !pending.isEmpty {
                    do { results.append(.success(try OperatorMarker.parse(pending))) }
                    catch { results.append(.failure(.invalidMarker)) }
                }
                pending.removeAll(keepingCapacity: true); discarding = false
            } else if !discarding {
                if pending.count == 8192 { pending.removeAll(keepingCapacity: true); discarding = true }
                else { pending.append(byte) }
            }
        }
        return results
    }
    public mutating func finish() -> [Result<OperatorMarker, ObserverError>] {
        guard !pending.isEmpty || discarding else { return [] }
        // EOF without a newline is incomplete; do not turn a partial marker into an action claim.
        pending.removeAll(); discarding = false
        return [.failure(.invalidMarker)]
    }
}

public struct SessionConfig: Codable {
    public var source: String
    public var samples, intervalMS, stableCount, maxSeconds, maxLogBytes: Int
    public init(source: String, samples: Int, intervalMS: Int, stableCount: Int, maxSeconds: Int,
                maxLogBytes: Int = 64 * 1024 * 1024) {
        self.source = source; self.samples = samples; self.intervalMS = intervalMS
        self.stableCount = stableCount; self.maxSeconds = maxSeconds; self.maxLogBytes = maxLogBytes
    }
}

public struct LogEvent: Codable {
    public var schemaVersion = 1
    public var sessionID: String
    public var sequence: Int
    public var receivedAt: String
    public var receivedUptimeNS: UInt64
    public var kind: String
    public var config: SessionConfig?
    public var sample: Sample?
    public var assessment: Assessment?
    public var marker: OperatorMarker?
    public var endReason: String?
    public init(sessionID: String, sequence: Int, kind: String, config: SessionConfig? = nil,
                sample: Sample? = nil, assessment: Assessment? = nil, marker: OperatorMarker? = nil,
                endReason: String? = nil) {
        self.sessionID = sessionID; self.sequence = sequence; self.kind = kind
        receivedAt = timestamp(); receivedUptimeNS = DispatchTime.now().uptimeNanoseconds
        self.config = config; self.sample = sample; self.assessment = assessment; self.marker = marker
        self.endReason = endReason
    }
}

public final class Sanitizer {
    private let key = SymmetricKey(size: .bits256) // Never exported; hashes cannot correlate identities across sessions.
    private var aliases: [String: [String: String]] = [:]
    public init() {}
    private func alias(_ kind: String, _ raw: String) -> String {
        if let existing = aliases[kind]?[raw] { return existing }
        let value = "\(kind)-\((aliases[kind]?.count ?? 0) + 1)"
        aliases[kind, default: [:]][raw] = value
        return value
    }
    private func token(_ raw: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(raw.utf8), using: key).map { String(format: "%02x", $0) }.joined()
    }
    private func space(_ id: UInt64?) -> Any { id.map { alias("space", String($0)) } as Any? ?? NSNull() }
    private func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: canonicalData(value), options: [.fragmentsAllowed])
    }
    public func data(for event: LogEvent) throws -> Data {
        var result: [String: Any] = ["schemaVersion": 1, "privacy": "session_pseudonyms_names_removed",
            "sessionID": event.sessionID, "sequence": event.sequence, "kind": event.kind,
            "receivedAt": event.receivedAt, "receivedUptimeNS": event.receivedUptimeNS,
            "behavioralVerdict": "NOT_ASSESSED_BY_OBSERVER"]
        if let config = event.config { result["config"] = try object(config) }
        if let marker = event.marker {
            var summary: [String: Any] = ["kind": marker.kind.rawValue, "action": marker.action.rawValue,
                "displayRole": marker.display.rawValue, "provenance": "operator_claim_only",
                "noteRedacted": marker.note != nil]
            if let trial = marker.trial { summary["trial"] = trial }
            if let mode = marker.reportedSeparateSpaces { summary["reportedSeparateSpaces"] = mode }
            // Free-form notes and operator timestamps remain raw-only. Receipt timestamp is above.
            result["marker"] = summary
        }
        if let endReason = event.endReason { result["endReason"] = endReason }
        if let sample = event.sample, let assessment = event.assessment {
            let state = sample.state, topology = state.boundary.topology
            func displayAlias(_ display: Display) -> String {
                alias("display", display.uuid?.uppercased() ?? "id:\(display.id)")
            }
            let displays: [[String: Any]] = try topology.displays.map { display in
                var row: [String: Any] = ["display": displayAlias(display), "name": "REDACTED",
                    "uuidKnown": display.uuid != nil, "bounds": try object(display.bounds),
                    "rotation": display.rotation, "pixelWidth": display.pixelWidth, "pixelHeight": display.pixelHeight,
                    "isMain": display.isMain, "isBuiltin": display.isBuiltin]
                if let frame = display.appKitFrame { row["appKitFrame"] = try object(frame) }
                if let scale = display.scale { row["scale"] = scale }
                if let mirrorID = display.mirrorsDisplay {
                    row["mirrorsDisplay"] = topology.displays.first(where: { $0.id == mirrorID }).map(displayAlias) ?? "UNKNOWN"
                }
                return row
            }
            let scopes: [[String: Any]] = state.boundary.inventory.scopes.enumerated().map { index, scope in
                let scopeKey = scope.identifier?.uppercased() ?? "missing:\(index)"
                return ["scope": alias("scope", scopeKey), "display": scope.matchedDisplay(in: topology).map(displayAlias) ?? "UNKNOWN",
                    "currentSpace": space(scope.currentSpaceID), "issues": scope.issues,
                    "spaces": scope.spaces.map { ["space": space($0.id), "rawType": $0.rawType as Any? ?? NSNull()] }]
            }
            let knownIDs = Set(state.boundary.inventory.scopes.flatMap { $0.spaces.compactMap(\.id) })
            let windows: [[String: Any]] = state.windows.enumerated().map { index, window in
                let id = window.metadata.id.map { alias("window", String($0)) } ?? "UNKNOWN-record-\(index)"
                return ["window": id, "layer": window.metadata.layer as Any? ?? NSNull(),
                    "onscreen": window.metadata.onscreen as Any? ?? NSNull(),
                    "membershipStatus": window.membership.status.rawValue,
                    "spaces": window.membership.spaceIDs.map { space($0) },
                    "unresolvedSpaces": window.membership.spaceIDs.filter { !knownIDs.contains($0) }.map { space($0) }]
            }
            result["sample"] = ["revision": sample.revision, "startedAt": sample.startedAt, "endedAt": sample.endedAt,
                "startedUptimeNS": sample.startedUptimeNS, "endedUptimeNS": sample.endedUptimeNS,
                "osVersion": state.osVersion, "osBuild": state.osBuild,
                "separateSpaces": state.boundary.separateSpaces,
                "topologyStatus": topology.status.rawValue, "displays": displays,
                "inventoryStatus": state.boundary.inventory.status.rawValue, "scopes": scopes,
                "windowListStatus": state.windowListStatus.rawValue, "windows": windows]
            var safeAssessment = try object(assessment) as! [String: Any]
            safeAssessment["topologyFingerprint"] = token(assessment.topologyFingerprint)
            safeAssessment["stateFingerprint"] = token(assessment.stateFingerprint)
            result["assessment"] = safeAssessment
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

public final class PrivateSessionLog {
    private let rawFD, sanitizedFD: Int32
    private let directoryFD: Int32
    private let maxBytes: Int
    private var written = 0
    private var sequence = 0
    private let sessionID = UUID().uuidString
    private let sanitizer = Sanitizer()
    public init(directory: String, maxBytes: Int = 64 * 1024 * 1024) throws {
        guard maxBytes > 0, directory.hasPrefix("/") else { throw ObserverError.unsafeOutputDirectory }
        let url = URL(fileURLWithPath: directory).standardizedFileURL
        // Reject symlinked paths, repositories and existing directories. Do not chmod someone else's files.
        guard url.path == directory, url.resolvingSymlinksInPath().path == directory else { throw ObserverError.unsafeOutputDirectory }
        var ancestor = url
        while ancestor.path != "/" {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
                throw ObserverError.unsafeOutputDirectory
            }
            ancestor.deleteLastPathComponent()
        }
        guard mkdir(directory, 0o700) == 0 else { throw ObserverError.unsafeOutputDirectory }
        let dir = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw ObserverError.unsafeOutputDirectory }
        var info = stat()
        guard fstat(dir, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            close(dir); throw ObserverError.unsafeOutputDirectory
        }
        let raw = openat(dir, "raw.jsonl", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard raw >= 0 else { close(dir); throw ObserverError.unsafeOutputFile }
        let sanitized = openat(dir, "sanitized.jsonl", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard sanitized >= 0 else { close(raw); close(dir); throw ObserverError.unsafeOutputFile }
        rawFD = raw; sanitizedFD = sanitized; directoryFD = dir; self.maxBytes = maxBytes
    }
    deinit { close(rawFD); close(sanitizedFD); close(directoryFD) }

    private func writeLine(_ data: Data, fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else {
            throw ObserverError.unsafeOutputFile
        }
        let line = data + Data([10])
        try line.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ObserverError.ioFailure }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw ObserverError.ioFailure }
    }

    public func append(kind: String, config: SessionConfig? = nil, sample: Sample? = nil,
                       assessment: Assessment? = nil, marker: OperatorMarker? = nil, endReason: String? = nil) throws {
        let event = LogEvent(sessionID: sessionID, sequence: sequence, kind: kind, config: config,
                             sample: sample, assessment: assessment, marker: marker, endReason: endReason)
        let raw = try canonicalData(event), sanitized = try sanitizer.data(for: event)
        guard raw.count + sanitized.count + 2 <= maxBytes - written else { throw ObserverError.outputLimit }
        var info = stat()
        guard fstat(directoryFD, &info) == 0, info.st_mode & 0o777 == 0o700 else { throw ObserverError.unsafeOutputDirectory }
        try writeLine(raw, fd: rawFD)
        try writeLine(sanitized, fd: sanitizedFD)
        written += raw.count + sanitized.count + 2; sequence += 1
    }
}
