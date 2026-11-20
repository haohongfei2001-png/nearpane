import Foundation
import NearpaneCore

/// Only the visible window roster asks the installed action helper to retain a
/// reference. Its token has no meaning for previews, management or migration.
@MainActor struct NativeSidebarWindowHistory {
    typealias Read = @MainActor ([NativeSidebarWindowProbe]) async -> [UUID?]
    private var retained = [NativeSidebarWindowLocation: UUID]()
    private var session: UUID?
    private var topology: String?

    func tracks(_ token: UUID, at location: NativeSidebarWindowLocation) -> Bool {
        retained[location] == token
    }

    mutating func update(_ snapshot: inout DesktopSnapshot, read: Read) async {
        if session != snapshot.sessionID || topology != snapshot.topologyFingerprint {
            retained.removeAll()
        }
        session = snapshot.sessionID
        topology = snapshot.topologyFingerprint
        guard let evidence = snapshot.native, evidence.population == .workWindows, evidence.catalogComplete != nil,
              evidence.spaces == .observed, evidence.accessibility != .denied, !evidence.windowLimitReached else {
            retained.removeAll()
            return
        }
        let scopes = Dictionary(grouping: snapshot.scopes, by: \.displayID)
        var foreground = [(Int, NativeSidebarWindowProbe)](), background = foreground
        for (index, window) in snapshot.windows.enumerated() {
            guard case .known(let spaces) = window.membership, spaces.count == 1, let space = spaces.first,
                  let display = UUID(uuidString: window.displayID), let local = scopes[window.displayID], local.count == 1,
                  let records = local.first?.records, records.first(where: \.isCurrent)?.nativeKind == .ordinary,
                  records.filter({ $0.nativeKind == .ordinary }).count >= 2,
                  let record = records.first(where: { $0.id == space }), let uuid = record.ordinaryUUID,
                  let m = window.metadata, let birth = m.launchMicroseconds, birth > 0, m.number > 0, m.pid > 1,
                  m.overviewOrdinaryRole != false, m.minimized != true, m.fullScreen != true else { continue }
            let location = NativeSidebarWindowLocation(window: .init(pid: m.pid, birth: birth, number: m.number),
                                                       display: display, space: space, spaceUUID: uuid)
            let original = retained[location]
            let probe = NativeSidebarWindowProbe(location, current: record.isCurrent, original: original)
            if record.isCurrent {
                if m.overviewOrdinaryRole == true, m.overviewSpaceID == space, m.overviewIsPresented == true,
                   m.onActiveDesktop == true, m.isOnscreen == true { foreground.append((index, probe)) }
            } else if original != nil {
                background.append((index, probe))
            }
        }
        // Give the first visible window and small, previously visited Spaces a turn
        // even on a desktop with many windows. The helper has its own time budget.
        func schedule(_ candidates: [(Int, NativeSidebarWindowProbe)], limit: Int) -> [(Int, NativeSidebarWindowProbe)] {
            guard candidates.count > limit else { return candidates }
            guard limit > 0 else { return [] }
            let others = Array(candidates.dropFirst())
            let offset = Int(snapshot.revision % UInt64(others.count))
            return [candidates[0]] + (others[offset...] + others[..<offset]).prefix(limit - 1)
        }
        let front = schedule(foreground, limit: max(8, 16 - background.count))
        let work = front + schedule(background, limit: 16 - front.count)
        let live = Set((foreground + background).map { $0.1.location })
        retained = retained.filter { live.contains($0.key) }
        guard !work.isEmpty else { return }
        let tokens = await read(work.map { $0.1 })
        // A Space can change between the independent readers. Withhold the row,
        // but keep the private token until a subsequent live check or invalidation.
        guard tokens.count == work.count else { return }
        for ((index, probe), token) in zip(work, tokens) {
            guard let token, probe.original == nil || probe.original == token else {
                retained.removeValue(forKey: probe.location)
                continue
            }
            retained[probe.location] = token
            snapshot.windows[index].sidebarOriginalWindow = token
        }
    }
}
