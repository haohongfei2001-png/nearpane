import Foundation
import NearpaneCore

/// Only the visible window roster asks the installed action helper to retain a
/// reference. Its token has no meaning for previews, management or migration.
@MainActor struct NativeSidebarWindowHistory {
    struct Batch {
        let tokens: [UUID?]
        let withheld: Set<Int>
        init(_ tokens: [UUID?], withheld: Set<Int> = []) { self.tokens = tokens; self.withheld = withheld }
    }
    typealias Read = @MainActor ([NativeSidebarWindowProbe]) async -> Batch
    private struct Original {
        let token: UUID
        let confirmed: TimeInterval
        var published: Bool
    }
    private var retained = [NativeSidebarWindowLocation: Original]()
    private var session: UUID?
    private var topology: String?

    func tracks(_ token: UUID, at location: NativeSidebarWindowLocation) -> Bool {
        retained[location]?.token == token && retained[location]?.published == true
    }

    mutating func update(_ snapshot: inout DesktopSnapshot, audit: NativeSidebarWindowAudit.Sample? = nil, read: Read) async {
        for i in snapshot.windows.indices where snapshot.windows[i].sidebarOriginalWindow != nil {
            snapshot.windows[i].sidebarOriginalWindow = nil
        }
        if session != snapshot.sessionID || topology != snapshot.topologyFingerprint {
            audit?.event("history-reset", ["sessionChanged": session != snapshot.sessionID, "topologyChanged": topology != snapshot.topologyFingerprint])
            retained.removeAll()
        }
        session = snapshot.sessionID
        topology = snapshot.topologyFingerprint
        guard let evidence = snapshot.native, evidence.population == .workWindows, evidence.catalogComplete != nil,
              evidence.spaces == .observed, evidence.accessibility != .denied, !evidence.windowLimitReached else {
            audit?.event("history-reader-ineligible")
            retained.removeAll()
            return
        }
        let now = evidence.endedUptime
        retained = retained.filter { now >= $0.value.confirmed && now - $0.value.confirmed <= 12 }
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
            let original = retained[location]?.token
            let audited = audit?.targets.contains(location.window) == true
            let probe = NativeSidebarWindowProbe(location, current: record.isCurrent, original: original, audit: audited ? true : nil)
            if audited { audit?.event("history-candidate", ["current": record.isCurrent, "hadOriginal": original != nil], window: location.window) }
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
        let numbers = Set(snapshot.windows.compactMap { $0.metadata?.number })
        for location in retained.keys where !live.contains(location) {
            if evidence.catalogComplete == false && !numbers.contains(location.window.number) {
                // During an animation the two CG/membership samples can disagree.
                // Withhold the row; its original can be rechecked from the next sample.
                retained[location]?.published = false
                audit?.event("history-withheld-incomplete-catalog", window: location.window)
            } else {
                retained.removeValue(forKey: location)
                audit?.event("history-invalidated-by-reader", window: location.window)
            }
        }
        guard !work.isEmpty else { return }
        let batch = await read(work.map { $0.1 })
        let tokens = batch.tokens
        // A Space can change between the independent readers. Withhold the row,
        // but keep the private token until a subsequent live check or invalidation.
        guard tokens.count == work.count else {
            for (_, probe) in work { retained[probe.location]?.published = false }
            return
        }
        for (offset, pair) in zip(work, tokens).enumerated() {
            let ((index, probe), token) = pair
            guard let token, probe.original == nil || probe.original == token else {
                if token == nil, batch.withheld.contains(offset), probe.original != nil {
                    // Only the signed helper knows if an unverified original is still
                    // held. It cannot renew its 12s expiry without affirmative evidence.
                    retained[probe.location]?.published = false
                } else {
                    retained.removeValue(forKey: probe.location)
                }
                continue
            }
            if probe.audit == true { audit?.event("history-original-applied", ["current": probe.current], window: probe.location.window) }
            retained[probe.location] = Original(token: token, confirmed: now, published: true)
            snapshot.windows[index].sidebarOriginalWindow = token
        }
    }
}
