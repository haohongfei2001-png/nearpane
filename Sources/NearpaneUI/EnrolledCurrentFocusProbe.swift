import Foundation
import NearpaneCore

extension NativeSidebarWindowAudit.Sample {
    /// Only an authenticated, disposable two-window fixture can enroll. These two
    /// processes explicitly reject activation, writes, permission requests and other IDs.
    @MainActor func inspectEnrolledFocus(_ snapshot: DesktopSnapshot, current: @MainActor () -> Bool) async {
        guard let request = focusRequest, current(), targets.count == 2,
              snapshot.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime) else { return }
        let cards = snapshot.currentDesktopWindows(on: request.desktop.display, now: .now, uptime: ProcessInfo.processInfo.systemUptime)
            .compactMap { DesktopWindowTarget($0, in: snapshot) }
        let matching = targets.map { key in cards.filter { $0.key.pid == key.pid && $0.key.birth == key.birth && $0.key.number == key.number } }
        guard matching.allSatisfy({ $0.count == 1 }), claimFocusProbe() else { return }
        for (key, group) in zip(targets, matching) {
            let card = group[0]
            var state = "unavailable", reason = "cardScopeUnavailable"
            var facts = [OrdinaryFocusScopeFinding]()
            var workerPID: Int32?
            if let scope = card.currentFocusScope, scope.desktop == request.desktop, current(), focusProbeBound(request) {
                do {
                    let owner = card.selectionOwner()
                    guard let bundle = owner.bundle else { throw OrdinaryWindowFailure("owner") }
                    let app = AdmissionApplication(pid: key.pid, launch: key.birth, bundle: bundle, name: "")
                    let directory = try OrdinaryWindowDirectory(app, previewWindow: key.number, scopeProbeOnly: true)
                    let choices = try await directory.choices(initial: true)
                    guard choices.count == 1, let item = choices.first, item.number == key.number, let handle = directory.handles[item.id] else {
                        throw OrdinaryWindowFailure("binding")
                    }
                    defer { handle.invalidate() }
                    workerPID = handle.workerPID
                    let result = try await handle.inspectFocusScope(scope, frame: card.frame)
                    state = result.evidence.rawValue; facts = result.findings
                    reason = "signedControllerReadback"
                } catch { reason = "originalBindingUnavailable" }
            }
            guard current(), focusProbeBound(request) else { return }
            var row: [String: Any] = ["probe": request.binding.token.uuidString, "mode": "readOnlyFocusScope", "state": state,
                                      "reason": reason, "actualAXWrites": 0, "findings": facts.map { fact in
                var info: [String: Any] = ["point": fact.point.rawValue, "reason": fact.reason.rawValue, "state": fact.state.rawValue]
                info["expected"] = fact.expected; info["observed"] = fact.observed; return info
            }]
            row["workerPID"] = workerPID
            event("enrolled-current-focus", row, window: key)
        }
    }
}
