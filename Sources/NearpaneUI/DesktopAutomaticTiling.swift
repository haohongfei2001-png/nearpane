import AppKit
import NearpaneCore
import Observation

/// Switching windows may include covered, minimized or all-desktops windows.
/// Automatic frame writes require a single ordinary desktop and a currently presented window.
struct DesktopTilingRoster: Equatable {
    let space: OrdinaryDesktopIdentity
    let keys: [DesktopWindowKey]
    let unpresented: Int

    func hasSamePresentedMembers(as other: Self) -> Bool {
        space == other.space && Set(keys) == Set(other.keys)
    }

    init?(_ sample: DesktopSnapshot?, display: String, now: Date = .now,
          uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard let sample, sample.isStructurallyValid, sample.nativeIsFresh(now: now, uptime: uptime),
              sample.native?.population == .workWindows, sample.native?.spaces == .observed,
              sample.native?.windowLimitReached == false, sample.displays.count == 1 || sample.separateSpaces == true else { return nil }
        let scopes = sample.scopes.filter { $0.displayID == display }
        let current = scopes.flatMap(\.records).filter(\.isCurrent)
        guard scopes.count == 1, current.count == 1, let record = current.first, let uuid = record.ordinaryUUID,
              sample.scopes.flatMap(\.records).filter({ $0.ordinaryUUID == uuid }).count == 1 else { return nil }
        self.space = .init(display: display, record: record.id, uuid: uuid)
        let members = sample.currentDesktopWindows(on: display, now: now, uptime: uptime)
            .compactMap { DesktopWindowTarget($0, in: sample) }
            .filter { $0.overviewSpace == record.id && $0.membership == .known(recordIDs: [record.id]) }
        self.keys = members.filter(\.publiclyVisible).map(\.key)
        self.unpresented = members.count - keys.count
    }
}

@MainActor @Observable final class DesktopAutomaticTiling {
    typealias Resolve = @MainActor ([DesktopWindowKey], OrdinaryDesktopIdentity, WorkspacePreferences) async throws -> [any OrdinaryWindowObserving]
    private let manager: OrdinaryWindowManager
    private let resolve: Resolve
    @ObservationIgnored private weak var feed: CurrentDesktopWindows?
    @ObservationIgnored private var permitsOwner: (DesktopWindowKey) -> Bool = { _ in true }
    @ObservationIgnored var nativeModeAvailable: () -> Bool = { true }
    private var grant: UUID?
    private(set) var waitingForDesktop: OrdinaryDesktopIdentity?
    private var ending = false
    private var exitEvidence: DesktopSnapshot?
    private(set) var starting = false
    private(set) var notice = ""
    private(set) var unpresented = 0
    var scope: OrdinaryDesktopIdentity? { manager.desktopScope }
    @ObservationIgnored private var job: Task<Void, Never>?
    /// A geometry refusal is retried only on a new membership, policy or explicit user request.
    private var previous: Set<DesktopWindowKey>?
    private var preferences: WorkspacePreferences?
    private var observedSpace: OrdinaryDesktopIdentity?
    private var lastPaused = false
    private var explicitArrivals = [DesktopWindowKey: UUID]()

    init(manager: OrdinaryWindowManager, resolve: @escaping Resolve = DesktopAutomaticTiling.resolveWindows) {
        self.manager = manager; self.resolve = resolve
    }

    func connect(_ feed: CurrentDesktopWindows, permitsOwner: @escaping (DesktopWindowKey) -> Bool = { _ in true }) {
        self.feed?.automaticTiling = nil
        self.feed = feed
        feed.automaticTiling = self
        self.permitsOwner = permitsOwner
        feed.didSample = { [weak self] in self?.changed() }
        manager.desktopIsCurrent = { [weak self] in
            guard let self, let scope else { return false }
            let evidence = self.ending ? self.exitEvidence : self.feed?.snapshot
            return self.nativeModeAvailable() && observedSpace == scope && evidence?.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime) == true
        }
        manager.didStopDesktop = { [weak self] in self?.end() }
    }

    func proposed(on display: String) async -> OrdinaryDesktopIdentity? {
        guard !ending, waitingForDesktop == nil, nativeModeAvailable(), let feed, manager.liveContext?(display) != nil, !starting, scope == nil else {
            notice = "当前无法确认本屏工作区域。"; return nil
        }
        feed.observeManagement(true)
        defer { if grant == nil { feed.observeManagement(false) } }
        guard let roster = DesktopTilingRoster(await feed.readNow(), display: display) else {
            notice = "当前显示器的普通桌面尚未得到确认。"; return nil
        }
        return roster.space
    }

    func start(_ selected: OrdinaryDesktopIdentity) async {
        let display = selected.display
        guard !ending, nativeModeAvailable(), grant == nil, !starting, manager.activeIDs.isEmpty, !manager.blocked, !manager.busy,
              let feed, manager.liveContext?(display) != nil else {
            notice = "当前无法确认本屏工作区域，或已有另一项窗口管理正在运行。"; return
        }
        starting = true
        defer { starting = false }
        let token = UUID()
        grant = token
        feed.observeManagement(true)
        let sample = await feed.readNow()
        guard grant == token, !ending else { return }
        guard nativeModeAvailable(), let roster = DesktopTilingRoster(sample, display: display), roster.space == selected, manager.liveContext?(display) != nil,
              manager.activeIDs.isEmpty, !manager.blocked, !manager.busy else {
            end(); notice = "尚未确认这个显示器上的普通桌面。请在普通桌面打开窗口调度。"; return
        }
        manager.desktopScope = roster.space
        notice = "正在等待可平铺的普通窗口。"
        previous = nil
        feed.changed()
        changed()
    }

    /// Serialize an explicit Space move with frame transactions. Frame writes remain
    /// conditional on the destination desktop grant and a later fresh roster.
    func transfer(_ key: DesktopWindowKey, lifetime: UUID, from source: OrdinaryDesktopIdentity,
                  to target: OrdinaryDesktopIdentity, perform: () async throws -> Void) async throws -> String {
        guard !ending, nativeModeAvailable() else { throw OrdinaryRefusal.stale }
        try await manager.performUserAction {
            try await manager.releaseForTransfer(key, from: source, perform: perform)
        }
        guard scope == target, let feed, grant != nil else {
            return "窗口已移入目标桌面。该桌面未授权自动分屏。"
        }
        guard permitsOwner(key) else { return "窗口已移入目标桌面，未纳入自动分屏。" }
        explicitArrivals[key] = lifetime
        previous?.remove(key)
        feed.changed()
        return manager.paused || manager.blocked ? "窗口已移入目标桌面，自动分屏已暂停。" :
            "窗口已移入目标桌面，等待核对目标桌面的布局。"
    }

    func retry() { previous = nil; feed?.changed(); changed() }
    func awaitCleanDesktop(_ desktop: OrdinaryDesktopIdentity) {
        guard !ending, scope == nil, feed != nil, !manager.blocked else { return }
        waitingForDesktop = desktop
        notice = "等待核对上次允许的桌面。"
        feed?.observeManagement(true)
    }

    func prepareForExit() async -> OrdinaryDesktopIdentity? {
        let resume = manager.paused || manager.blocked ? nil : scope ?? waitingForDesktop
        ending = true
        job?.cancel()
        await job?.value
        if let scope, let feed {
            exitEvidence = await feed.readNow()
            observedSpace = DesktopTilingRoster(exitEvidence, display: scope.display)?.space
        }
        return resume
    }

    func end() {
        grant = nil; job?.cancel(); job = nil
        explicitArrivals.removeAll()
        manager.desktopScope = nil
        waitingForDesktop = nil
        previous = nil; preferences = nil; observedSpace = nil; unpresented = 0; lastPaused = false; notice = ""
        feed?.observeManagement(false)
    }

    private func changed() {
        guard !ending else { return }
        if let waiting = waitingForDesktop, !starting, grant == nil, nativeModeAvailable(), let feed,
           !manager.blocked, !manager.busy, manager.activeIDs.isEmpty, manager.liveContext?(waiting.display) != nil,
           DesktopTilingRoster(feed.snapshot, display: waiting.display)?.space == waiting {
            waitingForDesktop = nil
            job = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                job = nil
                await start(waiting)
            }
            return
        }
        guard let scope, let token = grant, let feed else { return }
        explicitArrivals = explicitArrivals.filter { feed.lifetime(of: $0.key) == $0.value }
        let roster = DesktopTilingRoster(feed.snapshot, display: scope.display)
        observedSpace = roster?.space
        unpresented = roster?.space == scope ? roster?.unpresented ?? 0 : 0
        guard !manager.paused, !manager.blocked else {
            lastPaused = true; notice = "自动分屏已暂停。"; return
        }
        guard nativeModeAvailable(), let roster, roster.space == scope else {
            notice = "等待回到获准桌面。"; previous = nil; return
        }
        guard job == nil, !manager.unavailableForUserAction, !manager.busy,
              let ctx = manager.liveContext?(scope.display) else { return }
        let presented = Set(roster.keys)
        guard presented != previous || ctx.preferences != preferences || lastPaused else { return }
        lastPaused = false
        let priorMembers = previous
        previous = presented; preferences = ctx.preferences
        let managed = Set(manager.activeIDs.map { DesktopWindowKey(pid: $0.pid, birth: $0.launch, number: $0.number) })
        let added = roster.keys.filter { permitsOwner($0) && !managed.contains($0) }
        guard !added.isEmpty else {
            notice = managed.isEmpty ? "已启用，等待本桌面出现普通窗口。" : "本桌面正在自动分屏。"; return
        }
        job = Task { [weak self] in
            guard let self else { return }
            defer { if grant == token { job = nil; feed.changed() } }
            do {
                let handles = try await resolve(added, scope, ctx.preferences)
                try Task.checkCancellation()
                guard nativeModeAvailable(), grant == token, !manager.paused, !manager.blocked, !handles.isEmpty,
                      let live = DesktopTilingRoster(await feed.readNow(), display: scope.display),
                      live.hasSamePresentedMembers(as: roster), handles.allSatisfy({ handle in
                          handle.desktopBinding == scope && added.contains(.init(pid: handle.id.pid, birth: handle.id.launch, number: handle.id.number))
                      }) else {
                    if grant == token { notice = "等待可核对身份、尺寸和桌面归属的普通窗口。" }
                    return
                }
                let requestedCreation = handles.enumerated().contains { index, handle in
                    let key = DesktopWindowKey(pid: handle.id.pid, birth: handle.id.launch, number: handle.id.number)
                    return explicitArrivals[key] == nil && priorMembers?.contains(key) == false && WorkspaceAdmissionPlanner.requestsCreation(
                        existingCount: manager.activeIDs.count + index, source: .application, preferences: ctx.preferences)
                }
                try await manager.performUserAction {
                    let review = try await manager.prepare(handles, context: ctx)
                    try Task.checkCancellation()
                    guard nativeModeAvailable(), grant == token,
                          DesktopTilingRoster(await feed.readNow(), display: scope.display)?.hasSamePresentedMembers(as: roster) == true else {
                        manager.cancelPreview(); throw OrdinaryRefusal.stale
                    }
                    try await manager.confirm(review, context: ctx)
                }
                for key in added { explicitArrivals.removeValue(forKey: key) }
                notice = requestedCreation ? "系统桌面创建尚未开放，新窗口已在本桌面分屏。" :
                    "已核对本桌面 \(manager.activeIDs.count) 扇窗口的布局。"
            } catch {
                if grant == token { notice = "本次自动分屏未完成。\(error.localizedDescription)" }
            }
        }
    }

    /// Only resolve AX for regular processes in the positively attributed catalogue.
    /// One helper per owner, retained by its admitted windows, including same-app siblings.
    static func resolveWindows(_ keys: [DesktopWindowKey], _ scope: OrdinaryDesktopIdentity,
                               _ prefs: WorkspacePreferences) async throws -> [any OrdinaryWindowObserving] {
        var handles = [DesktopWindowKey: OrdinaryWindowAX]()
        var failure: Error?
        for (pid, members) in Dictionary(grouping: keys, by: \.pid) {
            try Task.checkCancellation()
            guard let birth = members.first?.birth, members.allSatisfy({ $0.birth == birth }),
                  let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated,
                  running.activationPolicy == .regular, pid != getpid(), let bundle = running.bundleIdentifier,
                  !bundle.hasPrefix("org.nearpane."), !bundle.hasPrefix("com.holdsnow.nearpane"),
                  AdmissionBirth.read(pid)?.start == birth else { continue }
            let owner = AdmissionApplication(pid: pid, launch: birth, bundle: bundle, name: running.localizedName ?? bundle)
            do {
                let directory = try OrdinaryWindowDirectory(owner)
                let rows = try await directory.choices(initial: true)
                for key in members {
                    let choices = rows.filter { $0.number == key.number }
                    guard choices.count == 1, let choice = choices.first, let h = directory.handles[choice.id],
                          (try? prefs.excluded(h.id, bundle: bundle)) == false else { continue }
                    do {
                        try h.bindDesktop(scope)
                        _ = try await h.prepare()
                        handles[key] = h
                    } catch { failure = error }
                }
            } catch { failure = error }
        }
        if handles.isEmpty, let failure { throw failure }
        return keys.compactMap { handles[$0] }
    }
}
