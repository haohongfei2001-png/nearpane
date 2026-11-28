import Foundation

extension NativeSpacesProvider {
    /// Read-only P4.3 rehearsal. The caller must supply a separately enrolled window.
    /// Neither two current observations nor an internal inventory record proves a destination.
    /// AX element tokens are reader-local: a restarted reader must establish a fresh pair.
    public func stableTestOrigin(previous: DesktopSnapshot, current: DesktopSnapshot,
                                 session: UUID, display: String, enrolled: ManagedWindowID,
                                 date: Date, uptime: Double) throws -> WorkspaceID {
        guard previous.sessionID == session, current.sessionID == session,
              !display.isEmpty, current.revision > previous.revision,
              previous.topologyFingerprint == current.topologyFingerprint,
              previous.sourceBuild == current.sourceBuild, previous.displays == current.displays,
              previous.scopes == current.scopes, previous.sampledTo <= current.sampledFrom,
              let a = previous.native, let b = current.native, a.endedUptime < b.beganUptime
        else { throw WorkspaceFailure.stale }
        var ids = Set<WorkspaceID>()
        for snapshot in [previous, current] {
            guard snapshot.isStructurallyValid, snapshot.nativeIsFresh(now: date, uptime: uptime),
                  snapshot.separateSpaces == true, snapshot.native?.accessibility == .available,
                  snapshot.native?.population == .markedFixture, snapshot.native?.windowLimitReached == false,
                  let row = snapshot.native?.rows.first(where: { $0.displayID == display }),
                  row.anchor.witness == .ownedWindow, row.anchor.number == enrolled.number,
                  snapshot.windows.count == 1, let w = snapshot.windows.first, w.displayID == display,
                  ManagedWindowID(w) == enrolled, w.metadata?.presentation == .confirmed, w.metadata?.globalFrame == row.anchor.globalFrame,
                  w.membership == .known(recordIDs: [row.recordID]),
                  let id = snapshot.workspaceID(display: display, record: row.recordID)
            else { throw WorkspaceFailure.membership }
            ids.insert(id)
        }
        guard ids.count == 1, let id = ids.first else { throw WorkspaceFailure.membership }
        return id
    }
}
