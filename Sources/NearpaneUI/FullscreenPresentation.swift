import AppKit
import NearpaneCore

/// Presentation owns no AX writer, workspace switcher, speech engine or attachment queue.
@MainActor final class FullscreenPresentation {
    private let host: HostSession
    private let tools: FullscreenToolPanelController
    private var transitions = [String: FullscreenTransitionCoordinator]()
    private var selection: (display: String, kind: FullscreenToolKind, generation: UUID)?
    private var expiry: Task<Void, Never>?
    private var visibleOn: String?
    private var visibilityLease = UUID()
    var refresh: (() -> Void)?
    var management: ((String, String, Double?) -> Void)?
    var topologyChanged: ((Set<String>) -> Void)?
    private var topology: [String: ScreenGeometry]?
    private var changedAt = [String: Double]()
    private var lastManagement = [String: String]()
    init(host: HostSession, domains: EmbeddedModules?) {
        self.host = host
        self.tools = FullscreenToolPanelController(host: host, domains: domains)
    }

    func sample(screen: ScreenGeometry, override: FullscreenDisplaySample?, now: Date, uptime: Double, suspended: Bool = false) -> Bool {
        let id = screen.id
        var state = transitions[id] ?? .init()
        let reading = suspended ? nil : override ?? host.bus.desktop.flatMap { desktop -> FullscreenDisplaySample? in
            guard let native = desktop.native, native.population == .workWindows else { return nil }
            let observation = desktop.fullscreenObservation(for: id, now: now, uptime: uptime)
            var members = Set<ManagedWindowID>()
            if case let .ordinary(.native(_, _, record)) = observation {
                members = Set(desktop.windows.compactMap { item in
                    guard item.displayID == id, item.metadata?.presentation == .confirmed,
                          case let .known(records) = item.membership, records == [record] else { return nil }
                    return ManagedWindowID(item)
                })
            }
            return .init(session: desktop.sessionID, revision: desktop.revision, validUntil: native.beganUptime + 12,
                         observation: observation, ordinaryMembers: members, beganUptime: native.beganUptime)
        }
        let measured = reading.flatMap { sample -> FullscreenDisplaySample? in
            if let cutoff = changedAt[id] {
                guard let began = sample.beganUptime, began >= cutoff, began <= uptime else { return nil }
            }
            return sample
        }
        let accepted = state.observe(measured, uptime: uptime)
        transitions[id] = state
        if state.phase == .native {
            host.reportFullscreen(state.permitsTool(at: uptime)
                ? "已识别本屏原生全屏，普通面板已收起。"
                : "全屏窗口暂时无法核对，精简工具已收起。", on: id)
        } else if accepted, state.returnEvidence == .unconfirmedSource {
            host.reportFullscreen("普通面板已恢复。原空间或原窗口未能核对，未执行空间切换。", on: id)
        } else if accepted, state.returnEvidence == .witnessedSource {
            host.reportFullscreen("系统已返回来源空间，窗口布局由管理器独立核对。", on: id)
        }
        if accepted, let measured {
            let result: String?
            switch measured.observation {
            case .native where state.phase == .native: result = "hold"
            case .ordinary where state.phase == .ordinary:
                result = state.returnEvidence == .witnessedSource ? "returned" : "ordinary"
            default: result = nil
            }
            if let result, result != "hold" || lastManagement[id] != result {
                lastManagement[id] = result
                management?(id, result, result == "hold" ? nil : measured.validUntil)
            }
        } else if measured == nil || measured?.observation == .unknown || (measured?.validUntil ?? 0) <= uptime {
            revokeManagementWitness(on: id)
        }
        return state.phase == .native
    }

    func updateTopology(_ screens: [ScreenGeometry], uptime: Double) {
        let current = Dictionary(uniqueKeysWithValues: screens.map { ($0.id, $0) })
        guard current != topology else { return }
        let displays = Set(current.keys)
        if topology.map({ Set($0.keys) }) != displays { topologyChanged?(displays) }
        changedAt = changedAt.filter { displays.contains($0.key) }
        if let previous = topology {
            for screen in screens where previous[screen.id] != screen {
                changedAt[screen.id] = uptime
                transitions[screen.id]?.invalidatePresentation()
                revokeManagementWitness(on: screen.id)
                if visibleOn == screen.id { hide() }
            }
        }
        topology = current
        for id in transitions.keys where !displays.contains(id) {
            revokeManagementWitness(on: id)
            host.reportFullscreen(nil, on: id)
        }
        transitions = transitions.filter { displays.contains($0.key) }
        lastManagement = lastManagement.filter { displays.contains($0.key) }
        if let visibleOn, !displays.contains(visibleOn) { hide() }
    }

    private func revokeManagementWitness(on display: String) {
        guard lastManagement[display] != "unknown" else { return }
        lastManagement[display] = "unknown"
        management?(display, "unknown", nil)
    }

    func hide() {
        if let id = visibleOn { visibilityLease = UUID(); transitions[id]?.hideTools() }
        visibleOn = nil; selection = nil
        expiry?.cancel(); expiry = nil
        tools.hide()
    }

    /// Lock, fast user switching, a non-console session, and mirroring
    /// veto the overlay. Third-party application sharing has no universal public indicator.
    private func safe(_ display: String) -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true else { return false }
        return NSScreen.screens.contains { screen in
            guard let n = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue(),
                  CFUUIDCreateString(nil, uuid) as String == display else { return false }
            return CGDisplayIsInMirrorSet(n.uint32Value) == 0
        }
    }

    func present(on screen: ScreenGeometry, allowed: Bool) {
        let id = screen.id
        let prefs = host.configuration.displays[id]?.fullscreenTools ?? .init()
        guard allowed, host.isRunning, !host.configuration.surfaceHidden, prefs.enabled,
              let state = transitions[id], state.permitsTool(at: ProcessInfo.processInfo.systemUptime),
              safe(id) else { hide(); return }
        if visibleOn != id { hide(); visibleOn = id }
        let generation = state.selectionGeneration, lease = visibilityLease
        if selection?.generation != generation || selection.map({ !prefs.allows($0.kind) }) == true {
            selection = nil; transitions[id]?.hideTools()
        }
        let valid: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return visibleOn == id && self.visibilityLease == lease && self.host.isRunning && !self.host.configuration.surfaceHidden &&
                self.host.configuration.displays[id]?.fullscreenTools.enabled == true &&
                self.transitions[id]?.selectionGeneration == generation &&
                self.transitions[id]?.permitsTool(at: ProcessInfo.processInfo.systemUptime) == true && self.safe(id)
        }
        tools.show(on: screen, expanded: transitions[id]?.toolsOpen == true ? selection?.kind : nil,
            presentationID: generation, permitInteraction: valid, open: { [weak self] kind in
                guard let self, valid(), self.host.configuration.displays[id]?.fullscreenTools.allows(kind) == true else { return }
                self.transitions[id]?.clickStatusStrip()
                self.selection = (id, kind, generation)
                self.refresh?()
            }, close: { [weak self] in
                guard let self, valid() else { return }
                self.transitions[id]?.hideTools(); self.selection = nil; self.refresh?()
            })
        if expiry == nil {
            expiry = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, let id = self.visibleOn else { return }
                    if self.transitions[id]?.permitsTool(at: ProcessInfo.processInfo.systemUptime) != true || !self.safe(id) {
                        self.hide(); return
                    }
                }
            }
        }
    }
}
