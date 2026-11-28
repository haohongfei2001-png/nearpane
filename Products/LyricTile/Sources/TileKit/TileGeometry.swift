import Foundation

/// All persisted placement coordinates are points, local to a display's visible area,
/// with a top-left origin. Only the AppKit window shell converts to global coordinates.
public struct TileRect: Codable, Hashable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public func intersects(_ other: TileRect) -> Bool {
        x < other.x + other.width && other.x < x + width &&
        y < other.y + other.height && other.y < y + height
    }
}

public struct TileDisplay: Codable, Hashable, Sendable {
    public var id: String, width: Double, height: Double, isPrimary: Bool
    public init(id: String, width: Double, height: Double, isPrimary: Bool = false) {
        self.id = id; self.width = width; self.height = height; self.isPrimary = isPrimary
    }
}

public struct TileMember: Codable, Equatable, Sendable {
    public var id: String
    public var instanceID: UUID
    public var pid: Int32
    public var processToken: String
    public var preferredDisplayID: String?
    public var reservedHeight: Double
    public var windowIDs: [UInt32]
    public var userOrder: Int?
    public init(id: String, instanceID: UUID = UUID(), pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                processToken: String? = nil, preferredDisplayID: String? = nil,
                reservedHeight: Double = 272, windowIDs: [UInt32] = [], userOrder: Int? = nil) {
        self.id = id; self.instanceID = instanceID; self.pid = pid
        self.processToken = processToken ?? TileProcess.token(for: pid) ?? "unknown:\(instanceID.uuidString)"
        self.preferredDisplayID = preferredDisplayID; self.reservedHeight = reservedHeight
        self.windowIDs = windowIDs; self.userOrder = userOrder
    }
}

public struct TilePlacement: Codable, Equatable, Sendable {
    public var displayID: String
    public var rect: TileRect
    public init(displayID: String, rect: TileRect) { self.displayID = displayID; self.rect = rect }
}

public enum TileGeometry {
    public static func standaloneWidth(visibleWidth: Double) -> Double {
        guard visibleWidth.isFinite else { return 176 }
        return min(224, max(176, 4 * (visibleWidth / 32).rounded()))
    }
    public static func placements(members: [TileMember], displays: [TileDisplay],
                                  previous: [String: TilePlacement] = [:],
                                  obstacles: [TilePlacement] = []) -> [String: TilePlacement] {
        let valid = displays.filter { $0.width.isFinite && $0.height.isFinite && $0.width >= 208 && $0.height >= 64 }
            .sorted { $0.isPrimary != $1.isPrimary ? $0.isPrimary : $0.id < $1.id }
        let customOrder = members.contains { $0.userOrder != nil }
        let ordered = members.sorted {
            let a = $0.userOrder ?? (customOrder ? Int.max : defaultOrder($0.id))
            let b = $1.userOrder ?? (customOrder ? Int.max : defaultOrder($1.id))
            return a == b ? $0.id < $1.id : a < b
        }
        var y = Dictionary(uniqueKeysWithValues: valid.map { ($0.id, 16.0) })
        var result: [String: TilePlacement] = [:]
        for member in ordered {
            guard member.reservedHeight.isFinite, member.reservedHeight >= 1 else { continue }
            let chosen = previous[member.id]?.displayID ?? member.preferredDisplayID
            var candidates = valid
            if let index = candidates.firstIndex(where: { $0.id == chosen }) {
                candidates.insert(candidates.remove(at: index), at: 0)
            }
            for screen in candidates {
                let width = standaloneWidth(visibleWidth: screen.width)
                var top = y[screen.id, default: 16]
                // Older HOLDSNOW apps do not participate in the protocol. Avoid their
                // observed windows without moving them or requiring Accessibility access.
                let blocked = obstacles.filter { $0.displayID == screen.id }.map(\.rect).sorted { $0.y < $1.y }
                for rect in blocked where rect.x.isFinite && rect.y.isFinite && rect.width.isFinite && rect.height.isFinite {
                    let proposed = TileRect(x: screen.width - 16 - width, y: top, width: width, height: member.reservedHeight)
                    let withGap = TileRect(x: rect.x - 10, y: rect.y - 10, width: rect.width + 20, height: rect.height + 20)
                    if proposed.intersects(withGap) { top = rect.y + rect.height + 10 }
                }
                guard width + 32 <= screen.width, top + member.reservedHeight + 16 <= screen.height else { continue }
                result[member.id] = TilePlacement(displayID: screen.id,
                    rect: TileRect(x: screen.width - 16 - width, y: top, width: width, height: member.reservedHeight))
                y[screen.id] = top + member.reservedHeight + 10
                break
            }
        }
        return result
    }
    private static func defaultOrder(_ id: String) -> Int {
        let value = id.lowercased()
        if value.contains("saytile") { return 0 }
        if value.contains("riftlet") { return 1 }
        if value.contains("lyrictile") || value == "lyrics" { return 2 }
        return 3
    }
}
