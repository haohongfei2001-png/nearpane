import Foundation

/// A read model for one physical display. The subsystem that performs actions must
/// independently validate this inventory and the outcome of each user request.
public struct NativeSpaceCatalog {
    public struct Row: Identifiable {
        public let record: SpaceRecord
        public let windows: [WindowObservation]
        /// This reader covers regular app surfaces. Even a complete empty catalogue
        /// cannot certify a Space is empty for removal.
        public let regularWindowListComplete: Bool
        public var id: String { record.id }
    }
    public let session: UUID
    public let topology: String
    public let display: DisplayObservation
    public let current: SpaceRecord
    public let rows: [Row]

    public init?(_ snapshot: DesktopSnapshot, displayID: String, now: Date, uptime: Double) {
        guard snapshot.isStructurallyValid, snapshot.nativeIsFresh(now: now, uptime: uptime),
              let evidence = snapshot.native, evidence.population == .workWindows,
              evidence.spaces == .observed, !evidence.windowLimitReached,
              snapshot.displays.count == 1 || snapshot.separateSpaces == true,
              let display = snapshot.displays.first(where: { $0.id == displayID }) else { return nil }
        let scopes = snapshot.scopes.filter { $0.displayID == displayID }
        guard scopes.count == 1, let scope = scopes.first else { return nil }
        let uuidCounts = Dictionary(grouping: snapshot.scopes.flatMap(\.records)
            .compactMap { $0.ordinaryUUID ?? $0.fullscreenUUID }, by: { $0 })
        let records = scope.records.filter { r in
            guard let uuid = r.ordinaryUUID ?? r.fullscreenUUID,
                  (r.ordinaryUUID == nil) != (r.fullscreenUUID == nil) else { return false }
            return uuidCounts[uuid]?.count == 1
        }
        guard let current = records.first(where: \.isCurrent) else { return nil }
        let local = snapshot.windows.filter { $0.displayID == displayID }
        var membership = [String: [WindowObservation]]()
        for window in local {
            if case .known(let ids) = window.membership {
                for id in ids { membership[id, default: []].append(window) }
            }
        }
        let complete = evidence.catalogComplete == true && !local.contains { $0.membership == .unknown }
        rows = records.map { record in
            Row(record: record, windows: (membership[record.id] ?? []).sorted {
                ($0.metadata?.frontToBack ?? .max) < ($1.metadata?.frontToBack ?? .max)
            }, regularWindowListComplete: complete)
        }
        session = snapshot.sessionID; topology = snapshot.topologyFingerprint
        self.display = display; self.current = current
    }
}
