import AppKit
import NearpaneCore
import OSLog

/// One fast, metadata-only feed for all visible sidebar panels. The full reader
/// serves geometry and window management independently of the window switcher.
@MainActor @Observable final class CurrentDesktopWindows {
    typealias Read = NativeDesktopProvider.Read
    #if NEARPANE_P0_DIAGNOSTIC
    private let diagnosticLease = P0DiagnosticLease.installed()
    #endif
    private let read: Read
    private let sessionAvailable: @MainActor () -> Bool
    private let fingerprint: @MainActor () -> Int
    private let session = UUID()
    private var revision: UInt64 = 0
    private(set) var snapshot: DesktopSnapshot?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var lifetimes = [DesktopWindowKey: UUID]()
    @ObservationIgnored private var sidebarWindows = NativeSidebarWindowHistory()
    private let readSidebarWindows: NativeSidebarWindowHistory.Read?
    @ObservationIgnored let windowAudit = NativeSidebarWindowAudit()
    @ObservationIgnored private var pendingAudit: NativeSidebarWindowAudit.Sample?
    let groups = ExplicitWindowGroups()
    @ObservationIgnored var splitPresentationChanged: (() -> Void)?
    private(set) var pairedDisplays = Set<String>()
    @ObservationIgnored private var splitObservationAllowed = false
    @ObservationIgnored private var fullscreenHint = false
    @ObservationIgnored private var nativeFullscreenSeen = false
    @ObservationIgnored private var sampleNextSpace = false

    // A native fullscreen transition can withdraw every ordinary panel. Keep a
    // metadata-only lease long enough to recognize a pair without starting a capture.
    func configureSplitObservation(allowed: Bool, fullscreenHint: Bool) {
        guard allowed != splitObservationAllowed || fullscreenHint != self.fullscreenHint else { return }
        if allowed && !splitObservationAllowed { sampleNextSpace = true }
        splitObservationAllowed = allowed
        self.fullscreenHint = allowed && fullscreenHint
        if !allowed {
            sampleNextSpace = false
            nativeFullscreenSeen = false
            publishPairs([])
        }
        updateObservation()
    }

    private func publishPairs(_ displays: Set<String>) {
        guard displays != pairedDisplays else { return }
        pairedDisplays = displays
        Task { [weak self] in self?.splitPresentationChanged?() }
    }

    private func sampleSplitPresentation(_ snapshot: DesktopSnapshot?) {
        guard splitObservationAllowed else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let fresh = snapshot.flatMap { $0.nativeIsFresh(now: .now, uptime: uptime) ? $0 : nil }
        nativeFullscreenSeen = fresh?.scopes.contains { $0.records.contains { $0.isCurrent && $0.nativeKind == .fullscreen } } == true
        let pairs = fresh.map { value in
            Set(value.displays.compactMap { display in
                value.currentSplitView(on: display.id, now: .now, uptime: uptime) == nil ? nil : display.id
            })
        } ?? []
        publishPairs(pairs)
        sampleNextSpace = false
        if !observationRequested { updateObservation() }
    }

    func tracks(_ token: UUID, at location: NativeSidebarWindowLocation) -> Bool {
        panelRequested && sidebarWindows.tracks(token, at: location)
    }

    func join(_ a: NativeSidebarMember, _ b: NativeSidebarMember) {
        guard a.source == b.source, a.source.kind == .ordinary, let snapshot,
              let live = a.source.resolve(snapshot), live.current.id == a.source.space,
              a.resolve(snapshot)?.membership == .known(recordIDs: [a.source.space]),
              b.resolve(snapshot)?.membership == .known(recordIDs: [a.source.space]),
              snapshot.windows.contains(where: { DesktopWindowTarget($0, in: snapshot)?.key == a.key }),
              snapshot.windows.contains(where: { DesktopWindowTarget($0, in: snapshot)?.key == b.key }) else { return }
        groups.join(a.key, b.key, space: a.source.uuid, lifetimes: lifetimes)
    }

    func lifetime(of key: DesktopWindowKey) -> UUID? { lifetimes[key] }
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var pending: (UUID, Task<DesktopSnapshot?, Never>)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var events: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var reportedCounts: [Int]?
    @ObservationIgnored weak var automaticTiling: DesktopAutomaticTiling?
    @ObservationIgnored var didSample: (() -> Void)?
    private var panelRequested = false
    private var managementRequested = false

    init(read: @escaping Read, sessionAvailable: @escaping @MainActor () -> Bool = WindowContentPreview.sessionAvailable,
         fingerprint: @escaping @MainActor () -> Int = CurrentDesktopWindows.windowNumbersFingerprint,
         readSidebarWindows: NativeSidebarWindowHistory.Read? = nil) {
        self.readSidebarWindows = readSidebarWindows
        self.read = read; self.sessionAvailable = sessionAvailable; self.fingerprint = fingerprint
    }

    func changed() { events?.yield(()) }

    func cardAppeared(_ member: NativeSidebarMember) {
        guard let key = member.location?.window else { return }
        pendingAudit?.event("background-card-appeared", window: key)
    }

    func invalidate(preservingOriginalWindows: Bool = false, reason: String = "invalidate") {
        windowAudit?.sample(feed: session, epoch: epoch, revision: revision)?.event("invalidate",
            ["reason": reason, "keepsOriginals": preservingOriginalWindows, "panelRequested": panelRequested])
        if !preservingOriginalWindows { sidebarWindows = .init() }
        epoch = UUID()
        pending?.1.cancel()
        pending = nil
        snapshot = nil
        nativeFullscreenSeen = false
        publishPairs([])
        if preservingOriginalWindows && splitObservationAllowed {
            sampleNextSpace = true
            updateObservation()
        }
        lifetimes.removeAll()
        retry?.cancel(); retry = nil; failures = 0
        didSample?()
        changed()
    }

    func observe(_ enable: Bool) {
        windowAudit?.sample(feed: session, epoch: epoch, revision: revision)?.event("panel-observation", ["enabled": enable])
        panelRequested = enable
        if !enable { sidebarWindows = .init() }
        updateObservation()
    }

    func observeManagement(_ enable: Bool) {
        managementRequested = enable
        updateObservation()
    }

    private var observationRequested: Bool {
        panelRequested || managementRequested || (splitObservationAllowed && (fullscreenHint || sampleNextSpace || nativeFullscreenSeen))
    }

    private func updateObservation() {
        if !observationRequested {
            guard loop != nil || events != nil || snapshot != nil else { return }
            events?.finish(); events = nil
            loop?.cancel(); loop = nil
            invalidate()
            return
        }
        guard loop == nil else { return }
        let (stream, events) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.events = events
        let fingerprint = self.fingerprint
        loop = Task { [weak self] in
            let detector = Task {
                var previous: Int?, last = ContinuousClock.now
                var settleUntil = last
                var settledDragCount = CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDragged)
                while !Task.isCancelled {
                    let now = ContinuousClock.now, numbers = fingerprint()
                    if numbers != previous {
                        previous = numbers
                        // WindowServer's numbers can precede the settled Space membership.
                        settleUntil = now.advanced(by: .milliseconds(760))
                    }
                    // A resize or move need not change the window list. Refresh on mouse
                    // release without monitoring events or reading their coordinates.
                    var dragEnded = false
                    if !CGEventSource.buttonState(.combinedSessionState, button: .left) {
                        let count = CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDragged)
                        dragEnded = count != settledDragCount
                        settledDragCount = count
                    }
                    if dragEnded || now < settleUntil || now - last >= .seconds(3) {
                        last = now; events.yield(())
                    }
                    do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                }
            }
            defer { detector.cancel() }
            for await _ in stream {
                guard !Task.isCancelled, let self else { return }
                let expected = epoch
                let next = await readNow()
                guard !Task.isCancelled, expected == epoch else { continue }
                snapshot = next
                sampleSplitPresentation(next)
                guard !Task.isCancelled, expected == epoch else { continue }
                if let next, pendingAudit?.revision == next.revision { pendingAudit?.snapshot(next, stage: "publish") }
                retry?.cancel()
                retry = nil
                if next != nil {
                    failures = 0
                } else {
                    failures = min(4, failures + 1)
                    let delay = [180, 360, 720, 1500][failures - 1]
                    retry = Task {
                        do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                        guard expected == epoch else { return }
                        events.yield(())
                    }
                }
                didSample?()
                if let next {
                    let presented = next.windows.filter(next.isCurrentDesktopWindow)
                    let counts = [presented.count, presented.filter { $0.metadata?.onActiveDesktop == false }.count, next.windows.count]
                    if counts != reportedCounts {
                        reportedCounts = counts
                        Logger(subsystem: "com.holdsnow.nearpane.alpha", category: "WindowOverview")
                            .info("Current desktop windows: total=\(counts[0], privacy: .public) background=\(counts[1], privacy: .public) inventory=\(counts[2], privacy: .public)")
                    }
                }
            }
        }
    }

    /// Used on both sides of a background picture batch and before an explicit click.
    /// Concurrent consumers join the same in-flight read.
    private var firstObserved = [DesktopWindowKey: UInt64]()
    private var nextOrdinal: UInt64 = 0

    func ordered(_ windows: [WindowObservation]) -> [WindowObservation] {
        func ordinal(_ window: WindowObservation) -> UInt64 {
            guard let m = window.metadata, let birth = m.launchMicroseconds else { return .max }
            return firstObserved[.init(pid: m.pid, birth: birth, number: m.number)] ?? .max
        }
        return windows.sorted { (ordinal($0), $0.id) < (ordinal($1), $1.id) }
    }

    func readNow() async -> DesktopSnapshot? {
        guard events != nil, sessionAvailable() else {
            lifetimes.removeAll()
            sidebarWindows = .init()
            return nil
        }
        let expected = epoch
        if let pending {
            let result = await pending.1.value
            return expected == epoch ? result : nil
        }
        revision &+= 1
        let audit = windowAudit?.sample(feed: session, epoch: epoch, revision: revision)
        let request = DesktopReadRequest(session: session, revision: revision, parentPID: getpid(),
            fixtureWindows: nil, anchors: [], experimentalSpaces: false, sidebarAuditWindows: audit?.targets)
        let task = Task { [read, weak self] () -> DesktopSnapshot? in
            let readback = try? await read(request)
            guard let self, !Task.isCancelled, expected == self.epoch else { audit?.event("reader-cancelled"); return nil }
            guard var result = readback, self.sessionAvailable(),
                  result.sessionID == request.session, result.revision == request.revision, result.isStructurallyValid,
                  result.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime) else {
                audit?.event("reader-rejected", ["reply": readback != nil, "sessionAvailable": self.sessionAvailable(),
                    "structurallyValid": readback?.isStructurallyValid == true])
                self.lifetimes.removeAll()
                if !self.sessionAvailable() { self.sidebarWindows = .init() }
                return nil
            }
            audit?.snapshot(result, stage: "reader")
            self.pendingAudit = audit
            let ordinaryObservation = NativeSidebarNavigation.shared.canSwitch || self.readSidebarWindows != nil
            var diagnosticTargets: Set<NativeSidebarWindowLocation>?
            #if NEARPANE_P0_DIAGNOSTIC
            if self.panelRequested, !ordinaryObservation {
                diagnosticTargets = self.diagnosticLease?.observationTargets(host:getpid())
            }
            #endif
            if self.panelRequested && (ordinaryObservation || diagnosticTargets?.isEmpty == false) {
                var history = self.sidebarWindows
                let sampleWindows = self.readSidebarWindows ?? { await NativeSpaceActionClient.shared.observe($0, audit: audit) }
                await history.update(&result, audit: audit, eligible: diagnosticTargets, read: sampleWindows)
                guard !Task.isCancelled, expected == self.epoch, self.sessionAvailable(), self.panelRequested,
                      result.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime) else { return nil }
                self.sidebarWindows = history
            } else { audit?.event("panel-observation-disabled") }
            var next = [DesktopWindowKey: UUID]()
            for window in result.windows {
                guard let meta = window.metadata, let birth = meta.launchMicroseconds, birth > 0 else { continue }
                let key = DesktopWindowKey(pid: meta.pid, birth: birth, number: meta.number)
                next[key] = self.lifetimes[key] ?? UUID()
            }
            self.firstObserved = self.firstObserved.filter { next[$0.key] != nil }
            // IDs order the initial batch only. A later window cannot overtake an older one.
            for key in next.keys.sorted(by: { $0.number < $1.number }) where self.firstObserved[key] == nil {
                self.nextOrdinal += 1
                self.firstObserved[key] = self.nextOrdinal
            }
            if !self.groups.records.isEmpty {
                let spaces = Dictionary(grouping: result.scopes.flatMap(\.records), by: \.id)
                var known = [DesktopWindowKey: Set<UUID>]()
                for window in result.windows {
                    guard let m = window.metadata, let birth = m.launchMicroseconds,
                          case .known(let ids) = window.membership else { continue }
                    let uuids = ids.compactMap { spaces[$0].flatMap { $0.count == 1 ? $0[0].nativeUUID : nil } }
                    if uuids.count == ids.count { known[.init(pid: m.pid, birth: birth, number: m.number)] = Set(uuids) }
                }
                self.groups.reconcile(lifetimes: next) { key, space in known[key].map { $0 != [space] } ?? false }
            }
            self.lifetimes = next
            return result
        }
        let token = UUID()
        pending = (token, task)
        let result = await task.value
        if pending?.0 == token { pending = nil }
        return expected == epoch ? result : nil
    }

    /// The cheap wake-up check reads only raw WindowServer numbers. Even while
    /// another app is frontmost a newly opened or closed sibling changes the list.
    private static func windowNumbersFingerprint() -> Int {
        var hash = Hasher()
        for options: NSWindow.NumberListOptions in [.allApplications, [.allApplications, .allSpaces]] {
            let ids = NSWindow.windowNumbers(options: options) ?? []
            hash.combine(ids.count)
            for id in ids { hash.combine(id.uint32Value) }
        }
        return hash.finalize()
    }
}
