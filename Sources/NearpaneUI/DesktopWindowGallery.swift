import AppKit
import NearpaneCore
@preconcurrency import ScreenCaptureKit

/// One WindowServer surface on the observed desktop. Observation IDs include a revision and
/// cannot be used to carry a click or an image across routine reader refreshes.
struct DesktopWindowKey: Hashable {
    let pid: pid_t
    let birth: UInt64
    let number: CGWindowID
}

struct DesktopWindowTarget: Equatable {
    let key: DesktopWindowKey
    let session: UUID
    let topology, display: String
    let current: String?
    let overviewSpace: String?
    private let focusSpaceOrder: [SpaceRecord]?
    private let focusPhysicalDisplay: DisplayObservation?
    private let focusSeparateSpaces: Bool?
    var currentFocusScope: OrdinaryFocusScope? {
        focusSpaceOrder.flatMap { OrdinaryFocusScope(display: display, topology: topology, order: $0,
                                                    physicalDisplay: focusPhysicalDisplay, separateSpaces: focusSeparateSpaces) }
    }
    let publiclyVisible: Bool
    let membership: WindowMembership
    let frame: SurfaceRect
    fileprivate let catalogSize: CGSize?
    fileprivate let desktopUUID: UUID?
    fileprivate let stageEnabled: Bool
    fileprivate var presentedSize: CGSize { CGSize(width: frame.width, height: frame.height) }

    init?(_ window: WindowObservation, in snapshot: DesktopSnapshot) {
        guard snapshot.isCurrentDesktopWindow(window) else { return nil }
        self.init(surface: window, in: snapshot)
    }

    /// This constructor admits read-only pictures of native fullscreen surfaces. Input callers use the ordinary initializer.
    static func preview(_ window: WindowObservation, in snapshot: DesktopSnapshot, now: Date = .now,
                        uptime: Double = ProcessInfo.processInfo.systemUptime) -> Self? {
        let active = snapshot.scopes.first { $0.displayID == window.displayID }?.records.first(where: \.isCurrent)
        if active?.fullscreenUUID == nil { return Self(window, in: snapshot) }
        guard window.metadata?.activeFullscreenSpaceID == active?.id,
              snapshot.activeSpaceWindows(on: window.displayID, now: now, uptime: uptime).contains(window) else { return nil }
        return Self(surface: window, in: snapshot, fullscreenPicture: true)
    }

    /// For the tiler's separately authorized AX resolver. No gallery or input target escapes.
    static func tilingCandidate(_ window: WindowObservation, in snapshot: DesktopSnapshot) -> (key: DesktopWindowKey, visible: Bool)? {
        guard let target = Self(surface: window, in: snapshot), let current = target.overviewSpace,
              target.membership == .known(recordIDs: [current]) else { return nil }
        return (target.key, target.publiclyVisible)
    }

    private init?(surface window: WindowObservation, in snapshot: DesktopSnapshot, fullscreenPicture: Bool = false) {
        guard fullscreenPicture || snapshot.isCurrentDesktopSurface(window), let m = window.metadata, m.pid > 1, let birth = m.launchMicroseconds, birth > 0,
              m.number > 0, fullscreenPicture || m.fullScreen != true, m.globalFrame.geometry.isValid,
              window.confidence != .synthetic,
              window.confidence != .ambiguous || (m.element == nil && m.axFrame == nil && m.axStandardWindowNumber == nil),
              m.axFrame == nil || m.presentation == .confirmed,
              m.axStandardWindowNumber == nil || m.axStandardWindowNumber == m.number else { return nil }
        let active = snapshot.scopes.filter { $0.displayID == window.displayID }.flatMap(\.records).filter(\.isCurrent)
        guard active.count <= 1, fullscreenPicture || active.first?.fullscreenUUID == nil else { return nil }
        publiclyVisible = m.isOnscreen == true && (fullscreenPicture || m.onActiveDesktop == true) && m.minimized != true
        if fullscreenPicture {
            guard let space = m.activeFullscreenSpaceID, active.first?.id == space, active.first?.fullscreenUUID != nil,
                  window.membership == .known(recordIDs: [space]), publiclyVisible else { return nil }
        } else if let space = m.overviewSpaceID {
            guard active.first?.id == space, active.first?.ordinaryUUID != nil,
                  case .known(let members) = window.membership, members.contains(space) else { return nil }
        } else if !publiclyVisible { return nil }
        overviewSpace = fullscreenPicture ? m.activeFullscreenSpaceID : m.overviewSpaceID
        key = .init(pid: m.pid, birth: birth, number: m.number)
        session = snapshot.sessionID; topology = snapshot.topologyFingerprint
        display = window.displayID; current = active.first?.id
        membership = window.membership; frame = m.globalFrame
        desktopUUID = fullscreenPicture ? active.first?.fullscreenUUID : active.first?.ordinaryUUID
        stageEnabled = snapshot.native?.stageManagerEnabled == true
        if !fullscreenPicture, publiclyVisible, m.overviewIsPresented == true, m.overviewOrdinaryRole == true, m.minimized == false,
           snapshot.native?.population == .workWindows, snapshot.native?.spaces == .observed, snapshot.native?.accessibility != .denied,
           snapshot.native?.stageManagerEnabled == false, snapshot.native?.windowLimitReached == false,
           snapshot.topologyConsistent, snapshot.displays.count == 1, snapshot.scopes.count == 1,
           let scope = snapshot.scopes.first, scope.displayID == display, let record = current, m.overviewSpaceID == record,
           membership == .known(recordIDs: [record]) {
            focusSpaceOrder = scope.records
            focusPhysicalDisplay = snapshot.displays.first
            focusSeparateSpaces = snapshot.separateSpaces
        } else {
            focusSpaceOrder = nil
            focusPhysicalDisplay = nil
            focusSeparateSpaces = nil
        }
        catalogSize = m.catalogLogicalFrame.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Reordering the stage can leave the same window at a new origin. Resizing the
    /// real window invalidates the cached pixels regardless of its Space membership.
    func samePicture(as other: Self) -> Bool {
        if self == other { return true }
        return overviewSpace != nil && overviewSpace == other.overviewSpace && key == other.key &&
            session == other.session && topology == other.topology && display == other.display && desktopUUID == other.desktopUUID &&
            current == other.current && membership == other.membership && stageEnabled == other.stageEnabled &&
            frame.width == other.frame.width && frame.height == other.frame.height && catalogSize == other.catalogSize
    }

    func present(in snapshot: DesktopSnapshot?, now: Date = .now, uptime: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let snapshot, snapshot.sessionID == session, snapshot.topologyFingerprint == topology else { return false }
        let matched = snapshot.activeSpaceWindows(on: display, now: now, uptime: uptime)
            .filter { $0.metadata?.number == key.number }
        return matched.count == 1 && matched.first.flatMap { DesktopWindowTarget.preview($0, in: snapshot, now: now, uptime: uptime) }.map(samePicture(as:)) == true
    }

    func liveOwner() -> NSRunningApplication? {
        if case let .found(app, _) = DesktopPreviewOwner.read(key, find: NSRunningApplication.init(processIdentifier:)) { return app }
        return nil
    }

    /// Never read window titles. Require the same shared layer-zero surface, its on-screen
    /// frame and the public current-desktop list on both sides of an asynchronous capture.
    @MainActor func isVisibleSurface(for purpose: SurfacePurpose = .picture) -> Bool {
        guard inPublicActiveList(for: purpose) else { return false }
        return sharedSurface(visible: true, matchFrame: true, for: purpose)
    }

    @MainActor func inPublicActiveList(for purpose: SurfacePurpose = .picture) -> Bool {
        let owner = purpose == .windowSelection ? selectionOwner().app : liveOwner()
        return owner != nil && (NSWindow.windowNumbers(options: .allApplications) ?? []).contains(NSNumber(value: key.number))
    }

    enum SurfacePurpose {
        case picture, windowSelection

        func accepts(drawn: Bool, allowsContent: Bool) -> Bool {
            drawn && (self == .windowSelection || allowsContent)
        }
    }

    @MainActor func pictureEligibility(needsMembership: Bool, owner: DesktopPreviewOwner?, audit: PreviewPipelineAudit?) -> PreviewPipelineAudit.Reason {
        let observed = DesktopPreviewOwner.read(key, find: NSRunningApplication.init(processIdentifier:))
        let checked = DesktopPreviewOwner.resolve(observed, key: key, bound: owner)
        audit?.record(key, .owner, checked.evidence)
        guard checked.allowed else { return .ownerUnavailable }
        if !needsMembership, !(NSWindow.windowNumbers(options: .allApplications) ?? []).contains(NSNumber(value: key.number)) {
            return .publicListMissing
        }
        return surfaceReason(visible: !needsMembership, matchFrame: true, for: .picture)
    }

    func sharedSurface(visible: Bool, matchFrame: Bool, for purpose: SurfacePurpose = .picture) -> Bool {
        surfaceReason(visible: visible, matchFrame: matchFrame, for: purpose) == .allowed
    }

    private func surfaceReason(visible: Bool, matchFrame: Bool, for purpose: SurfacePurpose) -> PreviewPipelineAudit.Reason {
        guard let row = WindowSurfaceRecord(number: key.number) else { return .metadataMissing }
        guard row.pid == key.pid, row.layer == 0 else { return .surfaceMismatch }
        guard row.isDrawn else { return .notDrawn }
        guard purpose.accepts(drawn: true, allowsContent: row.allowsContent) else { return .sharingDenied }
        guard !visible || row.isOnscreen else { return .offscreen }
        guard !matchFrame || row.frame == frame else { return .frameChanged }
        return .allowed
    }

    func matches(_ rect: CGRect) -> Bool {
        frame == SurfaceRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    /// When the catalogue proves the logical window is larger than its transformed
    /// WindowServer presentation, do not publish that presentation as the full picture.
    func acceptsContentSize(_ size: CGSize) -> Bool {
        guard size.width.isFinite, size.height.isFinite, min(size.width, size.height) > 0 else { return false }
        let presentation = CGSize(width: frame.width, height: frame.height)
        guard let catalogSize, catalogSize != presentation else { return true }
        return size == catalogSize
    }
}

@MainActor @Observable final class DesktopWindowGallery {
    struct Capture {
        let image: CGImage
        let logicalSize: CGSize
    }
    struct Still {
        let target: DesktopWindowTarget
        let lifetime: UUID
        let capture: Capture
        let time: TimeInterval
        enum Use { case current, previous, recent, mapOnly }
        var use: Use = .current

        /// Only reuse a full-size original. The transformed presentation alone
        /// cannot establish either the actual window size or the current Space.
        func canRetainPrevious(_ candidate: DesktopWindowTarget, lifetime current: UUID?, now: TimeInterval) -> Bool {
            guard use != .mapOnly, lifetime == current, now >= time, now - time < 60, candidate.stageEnabled,
                  target.key == candidate.key, target.session == candidate.session,
                  target.topology == candidate.topology, target.display == candidate.display,
                  target.desktopUUID != nil, target.desktopUUID == candidate.desktopUUID,
                  target.overviewSpace != nil, target.overviewSpace == candidate.overviewSpace,
                  target.membership == candidate.membership, target.catalogSize == capture.logicalSize,
                  target.presentedSize == capture.logicalSize else { return false }
            // A moving presentation can temporarily prevent two independent size reads
            // from agreeing. Keep the original in RAM briefly without publishing it.
            guard let logicalSize = candidate.catalogSize else { return now - time < 3 }
            return logicalSize == capture.logicalSize
        }

        func canShowPrevious(_ candidate: DesktopWindowTarget, lifetime current: UUID?, now: TimeInterval) -> Bool {
            if use == .recent {
                return lifetime == current && target.samePicture(as: candidate) && now >= time && now - time < 60
            }
            return canRetainPrevious(candidate, lifetime: current, now: now) && candidate.catalogSize == capture.logicalSize &&
                (use == .previous || candidate.presentedSize != capture.logicalSize)
        }

        func matches(_ candidate: DesktopWindowTarget, lifetime current: UUID?, now: TimeInterval) -> Bool {
            use == .current && current == lifetime && target.samePicture(as: candidate) && now >= time && now - time < 12
        }
    }
    @MainActor private final class Live {
        let target: DesktopWindowTarget, incarnation: UUID, run: UUID, stream: WindowFrameStream
        let window: SCWindow
        let screen: SCDisplay?
        let needsMembership: Bool
        let owner: DesktopPreviewOwner?
        var task: Task<Void, Never>?
        let acquired = ProcessInfo.processInfo.systemUptime
        var sequence: UInt64 = 0
        var publishedEpoch: UInt64?
        var checkedRevision: UInt64?
        var cancelled = false
        init(_ target: DesktopWindowTarget, incarnation: UUID, run: UUID, stream: WindowFrameStream, needsMembership: Bool,
             app: NSRunningApplication, window: SCWindow, screen: SCDisplay?) {
            self.target = target; self.incarnation = incarnation; self.run = run; self.stream = stream
            self.window = window; self.screen = screen
            self.needsMembership = needsMembership
            owner = DesktopPreviewOwner(key: target.key, app: app)
        }
        func cancel() {
            cancelled = true
            stream.finishOutput()
            task?.cancel()
        }
    }
    @ObservationIgnored private var streams = [DesktopWindowKey: Live]()
    @ObservationIgnored private(set) var deliveredFrameCount: UInt64 = 0
    // Includes asynchronously stopping streams until ScreenCaptureKit acknowledges teardown.
    var activeStreamCount: Int { streams.count }
    func frameSequence(for target: DesktopWindowTarget) -> UInt64 {
        guard stills.peek(target.key) != nil, let live = streams[target.key], !live.cancelled, live.target.samePicture(as: target),
              live.incarnation == lifetime(target.key), live.publishedEpoch == live.stream.epoch else { return 0 }
        return live.sequence
    }

    func allowsSwitchPicture(_ target: DesktopWindowTarget) -> Bool {
        permitsWindow(target.key) && lifetime(target.key) != nil
    }

    func switchCaptureSource(_ target: DesktopWindowTarget, display: CGDirectDisplayID) -> (SCWindow, SCDisplay)? {
        guard let live = streams[target.key], !live.cancelled, live.target == target,
              live.incarnation == lifetime(target.key), let screen = live.screen, screen.displayID == display else { return nil }
        return (live.window, screen)
    }
    private struct MeasuredSize: Equatable {
        let target: DesktopWindowTarget
        let incarnation: UUID
        let size: CGSize
    }
    // Parent layout observes sizes only. Each card observes its own cached image.
    private var sizes = [DesktopWindowKey: MeasuredSize]()
    private let stills = PreviewPixelCache<DesktopWindowKey, Still>()
    @ObservationIgnored private(set) var captureRequests: UInt64 = 0
    @ObservationIgnored private(set) var capturesInFlight = 0
    var cacheCount: Int { stills.count }
    var activeCaptureLoops: Int { operations.count }
    var cacheBytes: Int { stills.bytes }
    private var missingPictures = [DesktopWindowKey: String]()
    private(set) var generation: UInt64 = 0
    // A per-display lease prevents cancelled or superseded captures from being published.
    @ObservationIgnored private var operations = [String: UUID]()
    @ObservationIgnored private var changes = [String: AsyncStream<Void>.Continuation]()
    private var visible = [String: Set<DesktopWindowKey>]()
    @ObservationIgnored private var viewport = [String: [DesktopWindowKey: Bool]]()
    @ObservationIgnored private var lastService = [DesktopWindowKey: TimeInterval]()

    func setViewport(_ key: DesktopWindowKey, on display: String, visible: Bool) {
        if viewport[display]?[key] != visible {
            viewport[display, default: [:]][key] = visible
            changes[display]?.yield(())
        }
    }
    private func priority(_ target: DesktopWindowTarget) -> Int {
        switch viewport[target.display]?[target.key] { case true: return 2; case false: return 0; case nil: return 1 }
    }

    @ObservationIgnored let audit: PreviewPipelineAudit?
    private let permitsWindow: (DesktopWindowKey) -> Bool
    private let lifetime: (DesktopWindowKey) -> UUID?

    init(permitsWindow: @escaping (DesktopWindowKey) -> Bool, audit: PreviewPipelineAudit? = nil, lifetime: @escaping (DesktopWindowKey) -> UUID?) {
        self.permitsWindow = permitsWindow
        self.lifetime = lifetime
        self.audit = audit
        if let audit {
            stills.onRemoval = { [weak self] key in
                let live = self?.streams[key]
                audit.record(key, .cache, .removed, epoch: live?.stream.epoch, sequence: live?.sequence)
            }
        }
    }

    func recordCardSource(_ key: DesktopWindowKey, _ reason: PreviewPipelineAudit.Reason) {
        guard let audit else { return }
        let live = streams[key]
        audit.record(key, .card, reason, epoch: live?.stream.epoch, sequence: live?.sequence)
    }

    func setCard(_ key: DesktopWindowKey, on display: String, visible onScreen: Bool) {
        audit?.record(key, .lifecycle, onScreen ? .mounted : .unmounted)
        if onScreen {
            if visible[display, default: []].insert(key).inserted { changes[display]?.yield(()) }
        }
        else {
            visible[display]?.remove(key)
            viewport[display]?.removeValue(forKey: key)
            lastService.removeValue(forKey: key)
            let live = streams[key]
            if live?.target.display == display { live?.cancel() }
            if var still = stills.peek(key) {
                if (live != nil && live?.publishedEpoch != live?.stream.epoch) || still.use == .previous || still.target.overviewSpace == nil { stills.remove(key) }
                else if let cost = PreviewPixelBudget.charge(still.capture.image) {
                    audit?.record(key, .cache, .mapOnly)
                    still.use = .mapOnly
                    stills.store(still, for: key, cost: cost)
                }
            }
            missingPictures.removeValue(forKey: key)
        }
    }

    func clear(display: String? = nil) {
        for live in streams.values where display == nil || display == live.target.display {
            audit?.record(live.target.key, .lifecycle, .cleared, epoch: live.stream.epoch, sequence: live.sequence)
            live.cancel()
        }
        if let display {
            operations.removeValue(forKey: display)
            changes.removeValue(forKey: display)?.finish()
            stills.remove { _, still in still.target.display == display }
            sizes = sizes.filter { $0.value.target.display != display }
            missingPictures = missingPictures.filter { $0.value != display }
        } else {
            generation &+= 1
            operations.removeAll(); stills.removeAll(); sizes.removeAll(); missingPictures.removeAll(); lastService.removeAll()
            for events in changes.values { events.finish() }
            changes.removeAll()
        }
    }

    func image(for target: DesktopWindowTarget, permitted: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CGImage? {
        func rejected(_ reason: PreviewPipelineAudit.Reason) -> CGImage? {
            if let audit {
                let live = streams[target.key]
                audit.record(target.key, .lookup, reason, epoch: live?.stream.epoch, sequence: live?.sequence)
            }
            return nil
        }
        guard permitted, permitsWindow(target.key) else { return rejected(.notPermitted) }
        guard visible[target.display]?.contains(target.key) == true else { return rejected(.notVisible) }
        guard let still = stills.peek(target.key) else { return rejected(.noFrame) }
        guard let live = streams[target.key], !live.cancelled, live.sequence > 0 else { return rejected(.streamInactive) }
        guard live.publishedEpoch == live.stream.epoch else { return rejected(.streamEpochChanged) }
        guard still.matches(target, lifetime: lifetime(target.key), now: now) else { return rejected(.stillMismatch) }
        guard WindowContentPreview.sessionAvailable() else { return rejected(.sessionUnavailable) }
        guard WindowPermissionProbe.screen.allowed() else { return rejected(.screenDenied) }
        let check = target.pictureEligibility(needsMembership: live.needsMembership, owner: live.owner, audit: audit)
        guard check == .allowed else { return rejected(check) }
        audit?.record(target.key, .lookup, .allowed, epoch: live.stream.epoch, sequence: live.sequence)
        stills.touch(target.key)
        return still.capture.image
    }

    /// A separately labelled previous image may only be drawn while the same
    /// current window is still shareable. The caller also checks the live roster.
    func previousImage(for target: DesktopWindowTarget, permitted: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CGImage? {
        guard permitted, permitsWindow(target.key), visible[target.display]?.contains(target.key) == true,
              let still = stills.peek(target.key), still.canShowPrevious(target, lifetime: lifetime(target.key), now: now),
              WindowContentPreview.sessionAvailable(), WindowPermissionProbe.screen.allowed(),
              target.liveOwner() != nil, target.sharedSurface(visible: false, matchFrame: true) else { return nil }
        stills.touch(target.key)
        return still.capture.image
    }

    /// Revalidate only an image already in the cache. A completed asynchronous capture
    /// with a changed target must never supply pixels for this fallback.
    private func keepPreviousIfEligible(for key: DesktopWindowKey, as target: DesktopWindowTarget?) {
        guard let target, permitsWindow(key), visible[target.display]?.contains(key) == true,
              streams[key].map({ $0.publishedEpoch == $0.stream.epoch }) != false, var still = stills.peek(key),
              still.canRetainPrevious(target, lifetime: lifetime(key), now: ProcessInfo.processInfo.systemUptime),
              target.liveOwner() != nil, target.sharedSurface(visible: false, matchFrame: false),
              let cost = PreviewPixelBudget.charge(still.capture.image) else {
            stills.remove(key)
            return
        }
        if still.use != .previous {
            audit?.record(key, .cache, .previous)
            still.use = .previous
            stills.store(still, for: key, cost: cost)
        }
    }

    /// Pixel dimensions are downsampled. Keep the independent window filter's point
    /// dimensions with the same identity, lifetime and membership as its captured image.
    func capturedSizes(for windows: [WindowObservation], in snapshot: DesktopSnapshot, permitted: Bool) -> [UInt32: CGSize] {
        guard permitted else { return [:] }
        var result = [UInt32: CGSize]()
        for window in windows {
            guard let target = DesktopWindowTarget.preview(window, in: snapshot), permitsWindow(target.key),
                  let known = sizes[target.key], stills.contains(target.key), known.incarnation == lifetime(target.key),
                  known.target.samePicture(as: target) else { continue }
            result[target.key.number] = known.size
        }
        return result
    }

    /// The caller resolves this exact key from fresh membership in the requested map row.
    /// Never reuse an unscoped foreground capture or start a capture on a background desktop.
    func imageForMap(key: DesktopWindowKey, display: String, space: String, session: UUID,
                     topology: String, permitted: Bool) -> CGImage? {
        guard permitted, permitsWindow(key), WindowContentPreview.sessionAvailable(),
              WindowPermissionProbe.screen.allowed(), let still = stills.peek(key), still.use != .previous, still.lifetime == lifetime(key),
              still.target.session == session, still.target.topology == topology, still.target.display == display,
              still.target.overviewSpace == space, ProcessInfo.processInfo.systemUptime - still.time < 60,
              still.target.liveOwner() != nil, still.target.sharedSurface(visible: false, matchFrame: false)
        else { return nil }
        stills.touch(key)
        return still.capture.image
    }

    func lacksPicture(_ target: DesktopWindowTarget) -> Bool { missingPictures[target.key] == target.display }

    /// A visible surface has an independent public identity check. Keep these batches
    /// separate so an unavailable Space inventory cannot stall foreground thumbnails.
    static func captureBatches(_ targets: [DesktopWindowTarget], membership: Set<DesktopWindowKey>) -> [[DesktopWindowTarget]] {
        let ordered = [targets.filter { !membership.contains($0.key) }, targets.filter { membership.contains($0.key) }]
        return ordered.flatMap { group in
            stride(from: 0, to: group.count, by: 4).map { start in Array(group[start..<min(start + 4, group.count)]) }
        }
    }

    static func shouldYieldStream(serving: Int, waiting: Int, servingSince: TimeInterval, delivered: Bool,
                                  lastServedWaiting: TimeInterval?, now: TimeInterval) -> Bool {
        if serving != waiting { return serving < waiting }
        let minimum = delivered ? (lastServedWaiting == nil ? 0.35 : 2.0) : 3.0
        return now - servingSince >= minimum && (lastServedWaiting ?? -.infinity) < servingSince
    }

    /// The timer reconciles the roster and retries unavailable windows. The compositor drives picture updates.
    func run(on display: String, snapshot: @escaping () -> DesktopSnapshot?, allowed: @escaping () -> Bool,
             recheck: (() async -> DesktopSnapshot?)? = nil) async {
        let token = UUID(), (stream, events) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changes[display]?.finish()
        operations[display] = token
        changes[display] = events
        let timer = Task {
            while !Task.isCancelled {
                events.yield(())
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        defer {
            timer.cancel()
            if operations[display] == token { clear(display: display) }
        }
        var retry = [DesktopWindowKey: TimeInterval]()
        func permitted() -> Bool {
            !Task.isCancelled && operations[display] == token && allowed() &&
                WindowContentPreview.sessionAvailable() && WindowPermissionProbe.screen.allowed()
        }
        for await _ in stream {
            guard permitted() else { return }
            let sample = snapshot()
            let targets = sample.map { sample in
                sample.activeSpaceWindows(on: display, now: .now, uptime: ProcessInfo.processInfo.systemUptime)
                    .compactMap { DesktopWindowTarget.preview($0, in: sample) }
                    .filter { permitsWindow($0.key) && visible[display]?.contains($0.key) == true }
            } ?? []
            let active = Dictionary(grouping: targets, by: \.key).compactMapValues { $0.count == 1 ? $0.first : nil }
            for (key, live) in streams where live.target.display == display && !live.cancelled {
                guard live.run == token, live.incarnation == lifetime(key), let target = active[key],
                      live.target == target else {
                    audit?.record(key, .lifecycle, .targetChanged, epoch: live.stream.epoch, sequence: live.sequence)
                    live.cancel()
                    keepPreviousIfEligible(for: key, as: active[key])
                    retry.removeValue(forKey: key)
                    continue
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            for live in streams.values where live.target.display == display && !live.cancelled && live.sequence == 0 && now - live.acquired > 2 {
                if missingPictures[live.target.key] == nil { missingPictures[live.target.key] = display }
                if now - live.acquired > 5 { live.cancel(); retry[live.target.key] = now + 2 }
            }
            stills.remove { key, still in
                guard still.target.display == display else { return false }
                guard let sample, still.lifetime == lifetime(key) else { return true }
                if let target = active[key] {
                    if still.use == .previous {
                        return !still.canRetainPrevious(target, lifetime: lifetime(key), now: now)
                            || !target.sharedSurface(visible: false, matchFrame: false)
                    }
                    if still.target.samePicture(as: target) { return false }
                }
                let old = still.target
                guard let space = old.overviewSpace, old.session == sample.sessionID, old.topology == sample.topologyFingerprint,
                      now - still.time < 60 else { return true }
                let matches = sample.windows.filter { $0.metadata?.number == key.number }
                guard matches.count == 1, let row = matches.first, row.displayID == display, row.metadata?.pid == key.pid,
                      row.metadata?.launchMicroseconds == key.birth, case .known(let membership) = row.membership,
                      membership.contains(space), old.membership == row.membership else { return true }
                return false
            }
            for (key, measurement) in sizes where measurement.target.display == display && !stills.contains(key) {
                sizes.removeValue(forKey: key)
            }
            retry = retry.filter { active[$0.key] != nil }
            let due = targets.filter { active[$0.key] != nil && streams[$0.key] == nil && now >= (retry[$0.key] ?? 0) }
                .sorted { a, b in
                    if priority(a) != priority(b) { return priority(a) > priority(b) }
                    let left = lastService[a.key] ?? -.infinity, right = lastService[b.key] ?? -.infinity
                    return left == right ? a.key.number < b.key.number : left < right
                }
            guard let next = due.first else { continue }
            if streams.count >= WindowFrameStream.limit {
                for target in due where stills.peek(target.key) == nil && missingPictures[target.key] == nil { missingPictures[target.key] = display }
                // Give newly visible cards an exact first frame. Retire at most one lease until its OS stop completes.
                if !streams.values.contains(where: { $0.cancelled }),
                   let victim = streams.values.filter({ live in
                       Self.shouldYieldStream(serving: priority(live.target), waiting: priority(next),
                           servingSince: live.acquired, delivered: live.sequence > 0,
                           lastServedWaiting: lastService[next.key], now: now)
                   }).min(by: { a, b in
                       let left = priority(a.target), right = priority(b.target)
                       return left == right ? a.acquired < b.acquired : left < right
                   }) {
                    if victim.publishedEpoch == victim.stream.epoch, var still = stills.peek(victim.target.key), still.use == .current,
                       let cost = PreviewPixelBudget.charge(still.capture.image) {
                        audit?.record(victim.target.key, .cache, .recent)
                        still.use = .recent; stills.store(still, for: victim.target.key, cost: cost)
                    }
                    victim.cancel()
                }
                continue
            }
            let issued = Dictionary(uniqueKeysWithValues: due.compactMap { target in lifetime(target.key).map { (target.key, $0) } })
            guard !issued.isEmpty else { continue }
            for target in due { retry[target.key] = now + 1 }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true,
                    onScreenWindowsOnly: !due.contains(where: { $0.overviewSpace != nil })) else {
                if permitted() { for target in due { missingPictures[target.key] = display } }
                continue
            }
            guard permitted() else { return }
            let shared = Dictionary(grouping: content.windows, by: \.windowID)
            // Admit immediately verifiable public surfaces first. Off-stage membership checks can take a reader round-trip.
            let membership = Set(due.compactMap { target -> DesktopWindowKey? in
                guard target.overviewSpace != nil, let window = shared[target.key.number]?.first else { return nil }
                return target.publiclyVisible && window.isOnScreen && target.matches(window.frame) && target.isVisibleSurface() ? nil : target.key
            })
            for batch in Self.captureBatches(due, membership: membership) {
                let offstage = membership.contains(batch[0].key)
                let before = offstage ? await recheck?() : snapshot()
                guard permitted() else { return }
                for target in batch {
                    let key = target.key
                    guard streams.count < WindowFrameStream.limit, streams[key] == nil,
                          let incarnation = issued[key], lifetime(key) == incarnation, permitsWindow(key),
                          visible[display]?.contains(key) == true, target.present(in: before), target.present(in: snapshot()),
                          let windows = shared[key.number], windows.count == 1, let window = windows.first,
                          let app = target.liveOwner(), (offstage ? target.sharedSurface(visible: false, matchFrame: true) : target.isVisibleSurface()),
                          let pipe = WindowFrameStream(window: window, target: target, audit: audit) else {
                        if streams[key] == nil && visible[display]?.contains(key) == true { missingPictures[key] = display }
                        continue
                    }
                    let screen = content.displays.first { $0.frame.contains(window.frame) }
                    let live = Live(target, incarnation: incarnation, run: token, stream: pipe, needsMembership: offstage,
                                    app: app, window: window, screen: screen)
                    audit?.record(key, .lifecycle, .created, epoch: pipe.epoch, sequence: 0)
                    streams[key] = live
                    lastService[key] = live.acquired
                    captureRequests &+= 1
                    live.task = Task { await self.consume(live, snapshot: snapshot, allowed: allowed, recheck: recheck) }
                }
            }
        }
    }

    private func admissionReason(_ live: Live, snapshot: DesktopSnapshot?, allowed: () -> Bool) -> PreviewPipelineAudit.Reason {
        let target = live.target
        guard !live.cancelled, !Task.isCancelled, streams[target.key] === live, operations[target.display] == live.run else { return .leaseChanged }
        guard allowed() else { return .notPermitted }
        guard visible[target.display]?.contains(target.key) == true else { return .notVisible }
        guard permitsWindow(target.key) else { return .notPermitted }
        guard lifetime(target.key) == live.incarnation else { return .incarnationChanged }
        guard WindowContentPreview.sessionAvailable() else { return .sessionUnavailable }
        guard WindowPermissionProbe.screen.allowed() else { return .screenDenied }
        guard let snapshot, snapshot.sessionID == target.session, snapshot.topologyFingerprint == target.topology else { return .snapshotChanged }
        guard snapshot.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime) else { return .staleSnapshot }
        if live.checkedRevision != snapshot.revision {
            guard target.present(in: snapshot) else { return .rosterMismatch }
            live.checkedRevision = snapshot.revision
        }
        return target.pictureEligibility(needsMembership: live.needsMembership, owner: live.owner, audit: audit)
    }

    private func admitted(_ live: Live, snapshot: DesktopSnapshot?, allowed: () -> Bool) -> Bool {
        let result = admissionReason(live, snapshot: snapshot, allowed: allowed)
        audit?.record(live.target.key, .admission, result, epoch: live.stream.epoch, sequence: live.sequence)
        return result == .allowed
    }

    private func consume(_ live: Live, snapshot: @escaping () -> DesktopSnapshot?, allowed: @escaping () -> Bool,
                         recheck: (() async -> DesktopSnapshot?)?) async {
        let target = live.target, key = target.key, pipe = live.stream
        capturesInFlight += 1
        var started = false
        if admitted(live, snapshot: snapshot(), allowed: allowed) {
            do { try await pipe.start(); started = true } catch {}
        }
        capturesInFlight -= 1
        if started {
            for await update in pipe.updates {
                guard admitted(live, snapshot: snapshot(), allowed: allowed) else { break }
                if case .unavailable = update {
                    stills.remove(key)
                    if missingPictures[key] != target.display { missingPictures[key] = target.display }
                    continue
                }
                let received: TimeInterval, epoch: UInt64
                switch update {
                case let .frame(frame): received = frame.received; epoch = frame.epoch
                case let .idle(value): received = ProcessInfo.processInfo.systemUptime; epoch = value
                case .unavailable: continue
                }
                guard pipe.epoch == epoch else {
                    audit?.record(key, .membership, .streamEpochChanged, epoch: pipe.epoch, sequence: live.sequence); continue
                }
                let publicMembership = live.needsMembership && target.inPublicActiveList()
                if live.needsMembership && !publicMembership {
                    // A covered or staged window can be absent from AppKit's public current-only list.
                    // A coalesced read may already have begun before this delivery. Join a fresh one then.
                    var after = await recheck?()
                    if let began = after?.native?.beganUptime, began < received, !live.cancelled { after = await recheck?() }
                    guard let after, let began = after.native?.beganUptime, began >= received,
                          target.present(in: after), admitted(live, snapshot: snapshot(), allowed: allowed) else {
                        audit?.record(key, .membership, .membershipUnconfirmed, epoch: epoch, sequence: live.sequence); continue
                    }
                    audit?.record(key, .membership, .freshMembership, epoch: epoch, sequence: live.sequence)
                } else { audit?.record(key, .membership, .publicMembership, epoch: epoch, sequence: live.sequence) }
                let capture: Capture
                switch update {
                case let .frame(frame):
                    guard let image = frame.image() else {
                        audit?.record(key, .membership, .conversionFailed, epoch: epoch, sequence: live.sequence)
                        stills.remove(key); missingPictures[key] = target.display
                        continue
                    }
                    capture = Capture(image: image, logicalSize: pipe.logicalSize)
                case .idle:
                    // An idle notification can only extend the time of this same stream's last image.
                    guard live.sequence > 0, live.publishedEpoch == epoch, let last = stills.peek(key), last.use == .current,
                          last.lifetime == live.incarnation, last.target == target else { continue }
                    capture = last.capture
                case .unavailable: continue
                }
                guard admitted(live, snapshot: snapshot(), allowed: allowed) else { break }
                guard let cost = PreviewPixelBudget.charge(capture.image) else {
                    audit?.record(key, .cache, .invalidPixelCost, epoch: epoch, sequence: live.sequence)
                    break
                }
                guard pipe.epoch == epoch else {
                    audit?.record(key, .membership, .streamEpochChanged, epoch: pipe.epoch, sequence: live.sequence); continue
                }
                guard !publicMembership || target.inPublicActiveList() else {
                    audit?.record(key, .membership, .publicListMissing, epoch: epoch, sequence: live.sequence); continue
                }
                if case .frame = update { live.sequence &+= 1; live.publishedEpoch = epoch; deliveredFrameCount &+= 1 }
                stills.store(Still(target: target, lifetime: live.incarnation, capture: capture,
                                  time: ProcessInfo.processInfo.systemUptime), for: key, cost: cost)
                if let audit {
                    let stored = stills.peek(key)
                    let accepted = stored?.use == .current && stored?.capture.image === capture.image
                    audit.record(key, .cache, accepted ? .current : .notStored, epoch: epoch, sequence: live.sequence)
                }
                let measurement = MeasuredSize(target: target, incarnation: live.incarnation, size: capture.logicalSize)
                if sizes[key] != measurement { sizes[key] = measurement }
                if missingPictures[key] != nil { missingPictures.removeValue(forKey: key) }
            }
        }
        audit?.record(key, .lifecycle, .ended, epoch: pipe.epoch, sequence: live.sequence)
        let failedWhileCurrent = !live.cancelled && operations[target.display] == live.run
        live.cancelled = true
        pipe.finishOutput()
        if started { await pipe.stop() }
        if streams[key] === live {
            streams.removeValue(forKey: key)
            if failedWhileCurrent, operations[target.display] == live.run, lifetime(key) == live.incarnation,
               visible[target.display]?.contains(key) == true {
                stills.remove(key); missingPictures[key] = target.display
            }
            changes[target.display]?.yield(())
        }
        live.task = nil
    }
}
