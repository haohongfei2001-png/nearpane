import Foundation
import CryptoKit

public func canonicalData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

public func fingerprint<T: Encodable>(_ value: T) throws -> String {
    SHA256.hash(data: try canonicalData(value)).map { String(format: "%02x", $0) }.joined()
}

public func timestamp(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

public struct Rect: Codable, Equatable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct Display: Codable, Equatable {
    public var id: UInt32
    public var uuid: String?
    public var name: String?
    public var bounds: Rect
    public var appKitFrame: Rect?
    public var scale: Double?
    public var rotation: Double
    public var pixelWidth, pixelHeight: Int
    public var isMain, isBuiltin: Bool
    public var mirrorsDisplay: UInt32?
    public init(id: UInt32, uuid: String?, name: String?, bounds: Rect,
                appKitFrame: Rect? = nil, scale: Double? = nil, rotation: Double = 0,
                pixelWidth: Int = 0, pixelHeight: Int = 0, isMain: Bool = false,
                isBuiltin: Bool = false, mirrorsDisplay: UInt32? = nil) {
        self.id = id; self.uuid = uuid; self.name = name; self.bounds = bounds
        self.appKitFrame = appKitFrame; self.scale = scale; self.rotation = rotation
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.isMain = isMain; self.isBuiltin = isBuiltin; self.mirrorsDisplay = mirrorsDisplay
    }
}

public enum ReadStatus: String, Codable { case ok, unavailable, nullResult, malformed }

public struct Topology: Codable, Equatable {
    public var displays: [Display]
    public var status: ReadStatus
    public var issues: [String]
    public init(displays: [Display], status: ReadStatus = .ok, issues: [String] = []) {
        self.displays = displays.sorted { $0.id < $1.id }; self.status = status; self.issues = issues.sorted()
    }
}

public struct SpaceRecord: Codable, Equatable {
    public var id: UInt64?
    public var rawType: Int64?
    public init(id: UInt64?, rawType: Int64? = nil) { self.id = id; self.rawType = rawType }
}

public struct ManagedScope: Codable, Equatable {
    public var identifier: String?
    public var spaces: [SpaceRecord]
    public var currentSpaceID: UInt64?
    public var issues: [String]
    public init(identifier: String?, spaces: [SpaceRecord], currentSpaceID: UInt64?, issues: [String] = []) {
        self.identifier = identifier; self.spaces = spaces; self.currentSpaceID = currentSpaceID
        self.issues = issues.sorted()
    }
    public func matchedDisplay(in topology: Topology) -> Display? {
        guard let identifier else { return nil }
        let matches = topology.displays.filter { $0.uuid?.caseInsensitiveCompare(identifier) == .orderedSame }
        return matches.count == 1 ? matches[0] : nil // "Main" and unknown scopes are never guessed.
    }
}

public struct Inventory: Codable, Equatable {
    public var status: ReadStatus
    public var scopes: [ManagedScope]
    public var issues: [String]
    public init(status: ReadStatus = .ok, scopes: [ManagedScope], issues: [String] = []) {
        self.status = status
        // Preserve record order inside each scope; it may carry information. Unknown scopes retain their order.
        self.scopes = scopes.enumerated().sorted {
            let a = $0.element.identifier ?? "", b = $1.element.identifier ?? ""
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        self.issues = issues.sorted()
    }
}

public enum MembershipStatus: String, Codable {
    case known, empty, nullResult, unavailable, malformed, notQueried
}

public struct Membership: Codable, Equatable {
    public var status: MembershipStatus
    public var spaceIDs: [UInt64]
    public init(status: MembershipStatus, spaceIDs: [UInt64] = []) {
        self.status = status; self.spaceIDs = spaceIDs.sorted() // Preserve duplicates; do not infer set semantics.
    }
}

public struct WindowMetadata: Codable, Equatable {
    public var id: UInt32?
    public var pid: Int32?
    public var layer: Int32?
    public var bounds: Rect?
    public var onscreen: Bool?
    public init(id: UInt32?, pid: Int32? = nil, layer: Int32?, bounds: Rect?, onscreen: Bool?) {
        self.id = id; self.pid = pid; self.layer = layer; self.bounds = bounds; self.onscreen = onscreen
    }
}

public struct WindowObservation: Codable, Equatable {
    public var metadata: WindowMetadata
    public var membership: Membership
    public init(metadata: WindowMetadata, membership: Membership) {
        self.metadata = metadata; self.membership = membership
    }
}

public struct Boundary: Codable, Equatable {
    public var separateSpaces: Bool
    public var topology: Topology
    public var inventory: Inventory
    public init(separateSpaces: Bool, topology: Topology, inventory: Inventory) {
        self.separateSpaces = separateSpaces; self.topology = topology; self.inventory = inventory
    }
}

public struct ObservationState: Codable, Equatable {
    public var osVersion, osBuild: String
    public var boundary: Boundary
    public var windowListStatus: ReadStatus
    public var windows: [WindowObservation] // CGWindowList order is preserved (front to back).
    public init(osVersion: String, osBuild: String, boundary: Boundary,
                windowListStatus: ReadStatus = .ok, windows: [WindowObservation]) {
        self.osVersion = osVersion; self.osBuild = osBuild; self.boundary = boundary
        self.windowListStatus = windowListStatus; self.windows = windows
    }

    public var incompleteness: [String] {
        var issues = Set(boundary.topology.issues + boundary.inventory.issues)
        if osBuild.isEmpty || osBuild == "UNKNOWN" { issues.insert("os_build_unknown") }
        if boundary.topology.status != .ok || boundary.topology.displays.isEmpty { issues.insert("topology_unavailable") }
        let uuids = boundary.topology.displays.compactMap(\.uuid).map { $0.uppercased() }
        if uuids.count != boundary.topology.displays.count || Set(uuids).count != uuids.count { issues.insert("display_identity_unknown") }
        if boundary.inventory.status != .ok || boundary.inventory.scopes.isEmpty { issues.insert("inventory_unavailable") }
        let scopeIDs = boundary.inventory.scopes.compactMap(\.identifier)
        if Set(scopeIDs).count != scopeIDs.count { issues.insert("duplicate_scope") }
        for scope in boundary.inventory.scopes {
            issues.formUnion(scope.issues)
            if scope.matchedDisplay(in: boundary.topology) == nil { issues.insert("scope_display_unknown") }
            if scope.spaces.isEmpty || scope.spaces.contains(where: { $0.id == nil }) { issues.insert("space_record_unknown") }
            if let current = scope.currentSpaceID {
                if !scope.spaces.contains(where: { $0.id == current }) { issues.insert("current_space_outside_scope") }
            } else { issues.insert("current_space_missing") }
        }
        for display in boundary.topology.displays {
            let matchingScopes = boundary.inventory.scopes.filter { $0.matchedDisplay(in: boundary.topology)?.id == display.id }
            if matchingScopes.count != 1 { issues.insert("display_scope_unresolved") }
        }
        let knownIDs = Set(boundary.inventory.scopes.flatMap { $0.spaces.compactMap(\.id) })
        if windowListStatus != .ok { issues.insert("window_list_unavailable") }
        let windowIDs = windows.compactMap { $0.metadata.id }
        if Set(windowIDs).count != windowIDs.count { issues.insert("duplicate_window_identity") }
        for window in windows {
            let m = window.metadata
            if m.id == nil || m.pid == nil || m.layer == nil || m.bounds == nil || m.onscreen == nil {
                issues.insert("window_metadata_unknown")
            }
            if m.layer == 0 {
                if window.membership.status != .known || window.membership.spaceIDs.isEmpty {
                    issues.insert("window_membership_unknown")
                }
                if !Set(window.membership.spaceIDs).isSubset(of: knownIDs) { issues.insert("membership_outside_inventory") }
            }
        }
        return issues.sorted()
    }
}

public struct Sample: Codable, Equatable {
    public var revision: Int
    public var startedAt, endedAt: String
    public var startedUptimeNS, endedUptimeNS: UInt64
    public var state: ObservationState
    public var afterBoundary: Boundary
    public var afterWindowFingerprint: String
    public var afterWindowStatus: ReadStatus
    public var observerIssues: [String] = []
    public init(revision: Int, startedAt: String, endedAt: String, startedUptimeNS: UInt64,
                endedUptimeNS: UInt64, state: ObservationState, afterBoundary: Boundary,
                afterWindowFingerprint: String, afterWindowStatus: ReadStatus = .ok) {
        self.revision = revision; self.startedAt = startedAt; self.endedAt = endedAt
        self.startedUptimeNS = startedUptimeNS; self.endedUptimeNS = endedUptimeNS
        self.state = state; self.afterBoundary = afterBoundary
        self.afterWindowFingerprint = afterWindowFingerprint; self.afterWindowStatus = afterWindowStatus
    }
    public func consistencyIssues() throws -> [String] {
        var issues = observerIssues
        if state.boundary.topology != afterBoundary.topology { issues.append("topology_changed_during_sample") }
        if state.boundary.inventory != afterBoundary.inventory { issues.append("inventory_changed_during_sample") }
        if state.boundary.separateSpaces != afterBoundary.separateSpaces { issues.append("mode_changed_during_sample") }
        if try fingerprint(state.windows.map(\.metadata)) != afterWindowFingerprint || state.windowListStatus != afterWindowStatus {
            issues.append("window_list_changed_during_sample")
        }
        if endedUptimeNS < startedUptimeNS { issues.append("invalid_sample_time") }
        return issues
    }
}
