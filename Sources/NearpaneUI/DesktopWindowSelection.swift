import AppKit
import ApplicationServices
import NearpaneCore
import NearpaneOrdinaryWindowRuntime
import OSLog

extension DesktopWindowTarget {
    /// Bringing a Stage Manager window forward can change its presented bounds before
    /// AX acknowledges focus. Keep the original AX binding and desktop membership for
    /// that selection; pixel reuse continues to require the stricter picture match.
    func remainsSelection(in snapshot: DesktopSnapshot?, now: Date = .now,
                          uptime: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let space = overviewSpace else { return present(in: snapshot, now: now, uptime: uptime) }
        guard let snapshot, snapshot.sessionID == session, snapshot.topologyFingerprint == topology,
              case .known(let originalSpaces) = membership else { return false }
        if let expected = currentFocusScope {
            guard snapshot.displays.count == 1, snapshot.scopes.count == 1, let scope = snapshot.scopes.first, scope.displayID == display,
                  snapshot.native?.stageManagerEnabled == false,
                  OrdinaryFocusScope(display: display, topology: snapshot.topologyFingerprint, order: scope.records,
                                     physicalDisplay: snapshot.displays.first, separateSpaces: snapshot.separateSpaces) == expected else { return false }
        }
        let matches = snapshot.currentDesktopWindows(on: display, now: now, uptime: uptime)
            .filter { $0.metadata?.number == key.number }
        guard matches.count == 1, let window = matches.first, let other = DesktopWindowTarget(window, in: snapshot),
              other.key == key, other.overviewSpace == space, other.current == current,
              case .known(let currentSpaces) = other.membership else { return false }
        return Set(originalSpaces) == Set(currentSpaces)
    }
}

/// A new AppKit lookup by PID can return nil for a live application. For an explicit
/// same-app selection, the foreground reference is independent and can be verified
/// against the front application's exact AX focus and the selected kernel generation.
extension DesktopWindowTarget {
    static func selectionOwner<App: OrdinaryApplicationReference>(
        for key: DesktopWindowKey, direct: DesktopPreviewOwner.Read<App>,
        foreground: () -> App?, focusedPID: () -> pid_t?,
        kernel: (pid_t) throws -> OrdinaryProcessImage = OrdinaryProcessImage.read,
        signing: (pid_t) throws -> Data = OrdinaryProcessImage.signingDigest
    ) -> (app: App?, bundle: String?, evidence: PreviewPipelineAudit.Reason) {
        switch direct {
        case .found(let app, let bundle): return (app, bundle, .allowed)
        case .denied: return (nil, nil, .ownerChanged)
        case .missing(.application):
            guard let app = foreground(), app.processIdentifier == key.pid, focusedPID() == key.pid,
                  let bundle = app.bundleIdentifier,
                  DesktopPreviewOwner(key: key, app: app, kernel: kernel, signing: signing) != nil,
                  app.bundleIdentifier == bundle, focusedPID() == key.pid else { return (nil, nil, .applicationLookupMissing) }
            return (app, bundle, .applicationLookupRecovered)
        case .missing(let gap): return (nil, nil, gap.evidence(recovered: false))
        }
    }

    @MainActor func selectionOwner() -> (app: NSRunningApplication?, bundle: String?, evidence: PreviewPipelineAudit.Reason) {
        let direct = DesktopPreviewOwner.read(key, find: NSRunningApplication.init(processIdentifier:))
        return Self.selectionOwner(for: key, direct: direct, foreground: { NSWorkspace.shared.frontmostApplication }, focusedPID: {
            guard AXIsProcessTrusted() else { return nil }
            return try? FrontFocus.verifiedPID()
        })
    }
}

/// A new click can arrive after AppKit gives a window the keyboard and before the
/// previous acknowledgement reaches the sidebar. Serialize intents and keep the last
/// explicit choice. A refusal discards pending work.
@MainActor final class WindowChoiceQueue {
    private struct Choice {
        let id = UUID()
        let key: DesktopWindowKey
        let input: [UInt32]
        let perform: @MainActor (@escaping @MainActor @Sendable () -> Bool) async throws -> Void
        let failed: @MainActor (Error) -> Void
    }
    private var active: Choice?
    private var next: Choice?

    func choose(_ key: DesktopWindowKey, input: [UInt32],
                perform: @escaping @MainActor (@escaping @MainActor @Sendable () -> Bool) async throws -> Void,
                failed: @escaping @MainActor (Error) -> Void) {
        // Deduplicate delivery of the same click. A new press on the same card must
        // carry its own permission to act, including when the user chose A, B, A.
        if let latest = next ?? active, latest.key == key && latest.input == input { return }
        let choice = Choice(key: key, input: input, perform: perform, failed: failed)
        if active != nil {
            next = choice
            return
        }
        active = choice
        Task {
            var current: Choice? = choice
            while let job = current {
                let id = job.id
                do { try await job.perform { (self.next ?? self.active)?.id == id } }
                catch { next = nil; job.failed(error) }
                current = next; next = nil; active = current
            }
        }
    }
}

@MainActor enum DesktopWindowSelection {
    private static let log = Logger(subsystem: "com.holdsnow.nearpane.alpha", category: "WindowSelection")
    private static var recentWorkerFocus: RecentWorkerFocus?

    static func refusedCurrentCard(_ gate: StaticString) -> Bool {
        log.notice("selection card no longer current: \(String(describing: gate), privacy: .public)")
        return false
    }

    /// macOS can activate an application without Accessibility. Use that path only when
    /// even the off-Space WindowServer inventory contains exactly one visible layer-zero
    /// window for this owner. The returned window number, not just the PID, must be in front.
    static func soleWindow(_ target: DesktopWindowTarget, requireVisible: Bool = true) -> Bool {
        guard let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return soleWindow(target.key, in: rows, requireVisible: requireVisible)
    }

    static func soleWindow(_ key: DesktopWindowKey, in allWindows: [[String: Any]], requireVisible: Bool = true) -> Bool {
        let sameOwner = allWindows.filter { $0[kCGWindowOwnerPID as String] as? Int32 == key.pid &&
            $0[kCGWindowLayer as String] as? Int == 0 }
        return sameOwner.count == 1 && sameOwner[0][kCGWindowNumber as String] as? UInt32 == key.number &&
            (!requireVisible || sameOwner[0][kCGWindowIsOnscreen as String] as? Bool == true)
    }

    /// Stage operations use a retained Host AX object. The ordinary sidebar continues to use its signed controller.
    static func bindStage(_ key: DesktopWindowKey, lifetime: UUID, home: OrdinaryDesktopIdentity,
                          owner: StageEngineOwner, access: StageHostAccess) async throws -> StageHostWindow {
        try await StageHostWindow.bind(.init(pid: key.pid, birth: key.birth, number: key.number), lifetime: lifetime,
                                 home: home, engine: owner, access: access)
    }

    static func bind(_ key: DesktopWindowKey) async throws -> OrdinaryWindowAX {
        guard let owner = NSRunningApplication(processIdentifier: key.pid), let bundle = owner.bundleIdentifier else {
            throw OrdinaryWindowFailure("所选窗口的应用已退出。")
        }
        return try await bind(key, bundle: bundle)
    }

    private static func bind(_ key: DesktopWindowKey, bundle: String, sidebar: Bool = false,
                             timing: WindowFocusTiming? = nil) async throws -> OrdinaryWindowAX {
        let app = AdmissionApplication(pid:key.pid, launch:key.birth, bundle:bundle, name:"")
        let directory = sidebar ? try await OrdinaryWindowDirectory.forSidebarFocus(app) : try OrdinaryWindowDirectory(app)
        timing?.prepared(.controllerReady)
        let choices = try await directory.choices(initial: true).filter { $0.number == key.number }
        guard choices.count == 1, let choice = choices.first, let handle = directory.handles[choice.id] else {
            throw OrdinaryWindowFailure("无法唯一确认这扇窗口的辅助功能身份。")
        }
        return handle
    }

    enum SelectionPath {
        case accessibility, soleWindowApplication

        var focusNotice: String? {
            self == .soleWindowApplication ? "窗口已置前，键盘焦点尚未确认。" : nil
        }
    }

    private static func verifyCurrentSpace(_ verify: (() async -> Bool)?, current: () -> Bool) async throws {
        guard current() else { throw OrdinaryWindowFailure("原选窗操作已取消。") }
        if let verify {
            guard await verify(), current() else { throw OrdinaryWindowFailure("窗口已离开这个桌面。") }
        }
    }

    /// The exact original has already been bound by read-only AX. Bracket its use
    /// with two independent fresh rosters and stop promptly on a newer choice.
    static func focusBoundCard(verify: (() async -> Bool)?, current: () -> Bool,
                               opening: (() async throws -> Void)? = nil, focus: () async throws -> Void) async throws {
        if let opening { try await opening() }
        else { try await verifyCurrentSpace(verify, current: current) }
        try await focus()
        try await verifyCurrentSpace(verify, current: current)
    }

    /// A failed identity/topology witness is terminal. An incomplete read may request
    /// the independent full roster only while no AX write has been attempted.
    static func resolveFocusScope(_ scope: OrdinaryFocusScope?, current: () -> Bool,
                                  inspect: (OrdinaryFocusScope) async throws -> OrdinaryFocusScopeEvidence,
                                  fullRoster: () async throws -> Void, timing: WindowFocusTiming? = nil) async throws -> OrdinaryFocusScope? {
        guard current() else { throw OrdinaryWindowFailure("原选窗操作已取消。") }
        if let scope {
            let result = try await inspect(scope)
            guard current() else { throw OrdinaryWindowFailure("原选窗操作已取消。") }
            switch result {
            case .confirmed:
                timing?.prepared(.targetScopeConfirmed)
                return scope
            case .changed:
                timing?.prepared(.targetScopeChanged)
                throw OrdinaryWindowFailure("这扇窗口或桌面已变化，请重新选择。")
            case .fullRosterRequired:
                timing?.prepared(.targetScopeFallback)
            }
        }
        try await fullRoster()
        guard current() else { throw OrdinaryWindowFailure("原选窗操作已取消。") }
        return nil
    }

    @discardableResult
    static func select(_ target: DesktopWindowTarget, deadline: Double,
                       verifySpace: (() async -> Bool)? = nil, stillCurrent: @escaping @MainActor @Sendable () -> Bool,
                       bound: OrdinaryWindowAX? = nil, permit: NativeSelectionPermit? = nil,
                       timing: WindowFocusTiming? = nil, beforeFocus: () -> Void = {}) async throws -> SelectionPath {
        func current() -> Bool {
            stillCurrent() && WindowContentPreview.sessionAvailable() && ProcessInfo.processInfo.systemUptime <= deadline
        }
        guard stillCurrent() else {
            log.notice("selection admission refused: current intent")
            throw OrdinaryWindowFailure("这扇窗口已变化，请重新选择。")
        }
        guard WindowContentPreview.sessionAvailable(), ProcessInfo.processInfo.systemUptime <= deadline else {
            log.notice("selection admission refused: session or deadline")
            throw OrdinaryWindowFailure("这扇窗口已变化，请重新选择。")
        }
        let owner = target.selectionOwner()
        guard let app = owner.app, let bundle = owner.bundle else {
            log.notice("selection admission refused: owner \(owner.evidence.rawValue, privacy: .public)")
            throw OrdinaryWindowFailure("这扇窗口已变化，请重新选择。")
        }
        if owner.evidence == .applicationLookupRecovered {
            log.notice("selection admission: foreground owner independently verified")
        }
        guard target.overviewSpace == nil || verifySpace != nil else { throw OrdinaryWindowFailure("窗口已离开这个桌面。") }
        let sidebar = bound == nil && permit == nil
        let targetScope = sidebar && verifySpace != nil ? target.currentFocusScope : nil
        let scopeRead = sidebar && targetScope == nil ? verifySpace.map { verify in
            CurrentCardScopeRead {
                let result = await verify()
                timing?.prepared(.rosterReadFinished)
                return result
            }
        } : nil
        defer { scopeRead?.cancel() }
        let focusOwner = AdmissionApplication(pid:target.key.pid, launch:target.key.birth, bundle:bundle, name:"")
        let ready = sidebar && OrdinaryWindowDirectory.prepareSidebarFocus()
        let workerFirst = targetScope != nil || (ready && recentWorkerFocus?.prefers(focusOwner, session:target.session) == true)
        if sidebar { timing?.prepared(workerFirst ? .controllerPreferred : (ready ? .controllerStandby : .controllerCold)) }
        func verifyOpeningScope(after binding: ContinuousClock.Instant) async throws {
            if let scopeRead { try await scopeRead.confirm(boundAt:binding, current:current) }
            else { try await verifyCurrentSpace(verifySpace, current:current) }
            timing?.prepared(.rosterConfirmed)
        }
        func usePublicHostBinding() async throws -> Bool {
            guard sidebar, target.publiclyVisible else { return false }
            let host = HostCurrentWindowFocus(target:target, bundle:bundle, application:app)
            guard await host.bind() else {
                timing?.prepared(.publicBindingUnavailable)
                return false
            }
            let boundAt = ContinuousClock.now
            timing?.prepared(.hostBindingFinished)
            try await focusBoundCard(verify:verifySpace, current:current, opening:{ try await verifyOpeningScope(after:boundAt) }) {
                beforeFocus()
                try await host.focus(deadline:deadline, current:stillCurrent, timing:timing)
            }
            recentWorkerFocus = nil
            timing?.completed(.host)
            return true
        }
        if !workerFirst, try await usePublicHostBinding() { return .accessibility }
        let retained: OrdinaryWindowAX?
        if let bound {
            retained = bound
        } else {
            do { retained = try await bind(target.key, bundle:bundle, sidebar:sidebar, timing:timing) }
            catch {
                // The worker has only listed windows. Fallback here cannot replay an AX action.
                let missingAccess = (error as? AdmissionReadFailure) == .permission
                if workerFirst, (targetScope == nil || missingAccess), current(), try await usePublicHostBinding() { return .accessibility }
                if missingAccess { retained = nil }
                else { throw error }
            }
        }
        if let handle = retained {
            let boundAt = ContinuousClock.now
            timing?.prepared(.workerBindingFinished)
            guard current(), handle.id.pid == target.key.pid, handle.id.launch == target.key.birth,
                  handle.id.number == target.key.number else { throw OrdinaryWindowFailure("这扇窗口的系统身份已变化。") }
            let admitted = try await resolveFocusScope(targetScope, current: current, inspect: { scope in
                let reading = try await handle.inspectFocusScope(scope, frame: target.frame)
                if reading.evidence != .confirmed { timing?.scopeFindings(reading.findings, from: .host) }
                return reading.evidence
            }, fullRoster: { try await verifyOpeningScope(after:boundAt) }, timing: timing)
            beforeFocus()
            try await handle.focusCurrent(frame: target.frame, display: target.display, deadline: deadline,
                                          space: admitted?.desktop.record ?? target.overviewSpace,
                                          permit: permit ?? NativeSelectionPermit(current: stillCurrent), timing: timing, scope: admitted)
            guard current() else { throw OrdinaryWindowFailure("原选窗操作已取消。") }
            timing?.completed(.worker)
            if sidebar {
                recentWorkerFocus = RecentWorkerFocus(application:focusOwner, session:target.session, completed:.now)
                OrdinaryWindowDirectory.prepareSidebarFocus()
            }
            return .accessibility
        }
        let scoped = target.overviewSpace != nil
        guard soleWindow(target, requireVisible: !scoped) else {
            log.notice("selection refused: owner has no unique ordinary surface")
            throw OrdinaryWindowFailure("窗口助手未取得辅助功能权限，无法唯一选择这扇窗口。")
        }
        guard scoped ? target.sharedSurface(visible: false, matchFrame: false, for: .windowSelection)
                     : target.isVisibleSurface(for: .windowSelection) else {
            log.notice("selection refused: surface identity changed")
            throw OrdinaryWindowFailure("系统没有确认原窗口仍然可选。")
        }
        try await verifyCurrentSpace(verifySpace, current: current)
        if scoped {
            guard target.selectionOwner().app != nil,
                  soleWindow(target, requireVisible: false),
                  target.sharedSurface(visible: false, matchFrame: false, for: .windowSelection) else {
                throw OrdinaryWindowFailure("窗口或桌面已变化，请重新选择。")
            }
        }
        guard current() else { throw OrdinaryWindowFailure("原选窗操作已取消。") }
        beforeFocus()
        guard current() else { throw OrdinaryWindowFailure("原选窗操作已取消。") }
        timing?.beforeApplicationActivation()
        guard app.activate(options: []) else {
            log.notice("selection refused: application activation unavailable")
            throw OrdinaryWindowFailure("macOS 未允许这个应用置前。")
        }
        let end = min(deadline, ProcessInfo.processInfo.systemUptime + 0.8)
        repeat {
            if target.selectionOwner().app != nil, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.key.pid,
               soleWindow(target), (scoped ? target.sharedSurface(visible: true, matchFrame: false, for: .windowSelection) : target.isVisibleSurface(for: .windowSelection)),
               let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
               let front = rows.first(where: { $0[kCGWindowLayer as String] as? Int == 0 && ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0 }),
               front[kCGWindowNumber as String] as? UInt32 == target.key.number,
               front[kCGWindowOwnerPID as String] as? Int32 == target.key.pid {
                if !scoped && current() { timing?.completed(.application); return .soleWindowApplication }
                if let verifySpace, await verifySpace(), current() { timing?.completed(.application); return .soleWindowApplication }
                break
            }
            try await Task.sleep(for: .milliseconds(35))
        } while ProcessInfo.processInfo.systemUptime < end
        log.notice("selection outcome unconfirmed: front-window readback")
        throw OrdinaryWindowFailure("系统未确认这扇窗口已置前。")
    }
}
