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
    private let physicalScreen: DisplayObservation?
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
        physicalScreen = snapshot.displays.first { $0.id == window.displayID }
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

    /// A card may rescale its last accepted frame while its window is being resized.
    /// A transformed Stage Manager surface still needs the separate full-size proof.
    func sameCard(as other: Self) -> Bool {
        if stageEnabled || other.stageEnabled { return samePicture(as: other) }
        return key == other.key && session == other.session && matchesScreen(other.physicalScreen) &&
            display == other.display && current == other.current && desktopUUID == other.desktopUUID &&
            overviewSpace == other.overviewSpace && membership == other.membership
    }

    fileprivate func matchesScreen(_ screen: DisplayObservation?) -> Bool {
        guard let screen, let physicalScreen else { return false }
        return screen.id == physicalScreen.id && screen.frame == physicalScreen.frame &&
            screen.backingScale == physicalScreen.backingScale && screen.rotationDegrees == physicalScreen.rotationDegrees
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

    /// WindowServer can set alpha to zero or animate the bounds while switching
    /// desktops. Neither changes the owner's permission to show an existing frame.
    func lastFrameAccess() -> PreviewPipelineAudit.Reason {
        guard let row = WindowSurfaceRecord(number: key.number) else { return .metadataMissing }
        guard row.pid == key.pid, row.layer == 0 else { return .surfaceMismatch }
        return row.allowsSharing ? .allowed : .sharingDenied
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
        var signedOwner: DesktopPreviewOwner? = nil
        var original: StagePictureOriginal? = nil
        var departure: StageGroupDeparture.Stamp? = nil

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

        func matches(_ candidate: DesktopWindowTarget, lifetime current: UUID?, now: TimeInterval, confirmedAt: TimeInterval? = nil) -> Bool {
            let confirmation = confirmedAt ?? time
            return use == .current && current == lifetime && target.samePicture(as: candidate) &&
                confirmation >= time && now >= confirmation && now - confirmation < 12
        }

        func canDisplayLastFrame(_ candidate: DesktopWindowTarget, appearance: UUID?, originalMatches: (UUID) -> Bool) -> Bool {
            guard let appearance, use == .current || use == .recent, target.sameCard(as: candidate) else { return false }
            return lifetime == appearance || originalMatches(appearance)
        }

        func matchesDeparture(_ member: StageGroupDeparture.Member, _ group: StageGroupDeparture,
                              now: TimeInterval, appearance: UUID?) -> Bool {
            departure == group.stamp(for:member) && group.members.contains(member) && lifetime == member.appearance &&
                (appearance == nil || appearance == lifetime) && now >= time &&
                target.key == member.key && target.session == group.session && target.topology == group.topology &&
                UUID(uuidString:target.display) == group.scope.display && target.desktopUUID == group.scope.nativeSpace &&
                target.overviewSpace == String(group.nativeID) && target.membership == .known(recordIDs:[String(group.nativeID)]) &&
                target.frame == member.before.frame
        }
    }
    @MainActor private final class Live {
        var target: DesktopWindowTarget
        let incarnation: UUID, run: UUID, stream: WindowFrameStream
        let window: SCWindow
        let screen: SCDisplay?
        let needsMembership: Bool
        let owner: DesktopPreviewOwner?
        lazy var original = StagePictureOriginal(target.key, forCard: true)
        var task: Task<Void, Never>?
        let acquired = ProcessInfo.processInfo.systemUptime
        var sequence: UInt64 = 0
        weak var lastShown: CGImage?
        var publishedEpoch: UInt64?
        var confirmedAt: TimeInterval?
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
        guard stills.peek(.current(target.key)) != nil, let live = streams[target.key], !live.cancelled, live.target.samePicture(as: target),
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
    enum StillSlot: Hashable { case current(DesktopWindowKey), held(DesktopWindowKey), observed(DesktopWindowKey) }
    private let stills: PreviewPixelCache<StillSlot, Still>
    private(set) var observedGroups = [UUID:StageGroupDeparture]()
    private struct PictureInventory {
        let snapshot: DesktopSnapshot
        let lifetimes, appearances: [DesktopWindowKey: UUID]
    }
    @ObservationIgnored private var recentInventory = [String:PictureInventory]()
    @ObservationIgnored private var lastObservation = [String:TimeInterval]()
    @ObservationIgnored private(set) var captureRequests: UInt64 = 0
    @ObservationIgnored private(set) var capturesInFlight = 0
    var cacheCount: Int { stills.count }
    var activeCaptureLoops: Int { operations.count }
    var cacheBytes: Int { stills.bytes }
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
    private let pictureAppearance: (DesktopWindowKey) -> UUID?

    init(permitsWindow: @escaping (DesktopWindowKey) -> Bool, audit: PreviewPipelineAudit? = nil,
         cache: PreviewPixelCache<StillSlot, Still> = .init(),
         pictureAppearance: ((DesktopWindowKey) -> UUID?)? = nil, lifetime: @escaping (DesktopWindowKey) -> UUID?) {
        self.stills = cache
        self.permitsWindow = permitsWindow
        self.lifetime = lifetime
        self.pictureAppearance = pictureAppearance ?? lifetime
        self.audit = audit
        if let audit {
            stills.onRemoval = { [weak self] slot in
                guard case let .current(key) = slot else { return }
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
            // SwiftUI may replace the card during this update. Reconcile the final mounted
            // set in the capture loop instead of tearing down a still-visible surface here.
            changes[display]?.yield(())
        }
    }

    func clear(display: String? = nil, keepingCardFrames: Bool = false) {
        for live in streams.values where display == nil || display == live.target.display {
            audit?.record(live.target.key, .lifecycle, .cleared, epoch: live.stream.epoch, sequence: live.sequence)
            live.cancel()
        }
        if let display {
            recentInventory[display] = nil; lastObservation[display] = nil
            operations.removeValue(forKey: display)
            changes.removeValue(forKey: display)?.finish()
            if !keepingCardFrames {
                observedGroups = observedGroups.filter { $0.value.scope.display.uuidString.caseInsensitiveCompare(display) != .orderedSame }
                stills.remove { _, still in still.target.display == display }
                sizes = sizes.filter { $0.value.target.display != display }
            }
        } else {
            observedGroups.removeAll(); recentInventory.removeAll(); lastObservation.removeAll()
            generation &+= 1
            operations.removeAll(); stills.removeAll(); sizes.removeAll(); lastService.removeAll()
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
        guard let still = stills.peek(.current(target.key)) else { return rejected(.noFrame) }
        guard let live = streams[target.key], !live.cancelled, live.sequence > 0 else { return rejected(.streamInactive) }
        guard live.publishedEpoch == live.stream.epoch else { return rejected(.streamEpochChanged) }
        guard still.matches(target, lifetime: lifetime(target.key), now: now, confirmedAt: live.confirmedAt) else { return rejected(.stillMismatch) }
        guard WindowContentPreview.sessionAvailable() else { return rejected(.sessionUnavailable) }
        guard WindowPermissionProbe.screen.allowed() else { return rejected(.screenDenied) }
        let check = target.pictureEligibility(needsMembership: live.needsMembership, owner: live.owner, audit: audit)
        guard check == .allowed else { return rejected(check) }
        audit?.record(target.key, .lookup, .allowed, epoch: live.stream.epoch, sequence: live.sequence)
        live.lastShown = still.capture.image
        stills.touch(.current(target.key))
        return still.capture.image
    }

    /// Read-only presentation, including the very first draw of a returning card.
    /// This never starts capture, publishes a live sequence or grants a click.
    func previousImage(for target: DesktopWindowTarget, permitted: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CGImage? {
        let key = target.key
        guard permitted, permitsWindow(key),
              WindowContentPreview.sessionAvailable(), WindowPermissionProbe.screen.allowed() else { return nil }
        return Self.lastCardPixels(target, in: stills, appearance: pictureAppearance(key), now: now, allows: { still in
            let owner = DesktopPreviewOwner.read(key, find: NSRunningApplication.init(processIdentifier:))
            let checked = DesktopPreviewOwner.resolve(owner, key: key, bound: still.signedOwner)
            let access = target.lastFrameAccess()
            if checked.evidence == .ownerChanged || access == .surfaceMismatch || access == .sharingDenied {
                discardRevokedPictures(key)
            }
            return checked.allowed && access == .allowed
        }, originalMatches: { still, appearance in
            still.original?.matches(key, appearance: appearance) { still.signedOwner?.stillSigned(as: key) == true } == true
        })
    }

    static func lastCardPixels(_ target: DesktopWindowTarget, in cache: PreviewPixelCache<StillSlot, Still>,
                               appearance: UUID?, now: TimeInterval, allows: (Still) -> Bool,
                               originalMatches: (Still, UUID) -> Bool) -> CGImage? {
        let slot = StillSlot.current(target.key)
        guard let still = cache.peek(slot) else { return nil }
        let last = still.canDisplayLastFrame(target, appearance: appearance) { newAppearance in
            originalMatches(still, newAppearance)
        }
        guard last || still.canShowPrevious(target, lifetime: appearance, now: now), allows(still) else { return nil }
        cache.touch(slot)
        return still.capture.image
    }

    private func discardRevokedPictures(_ key: DesktopWindowKey) {
        // SwiftUI may be drawing the card. Withdraw these exact images without erasing
        // a newer authorized frame that arrives before the end of the view update.
        let revoked = [StillSlot.current(key), .observed(key), .held(key)].compactMap { slot in
            stills.peek(slot).map { (slot, $0.capture.image) }
        }
        guard !revoked.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            for (slot, pixels) in revoked where stills.peek(slot)?.capture.image === pixels { stills.remove(slot) }
        }
    }

    /// Revalidate only an image already in the cache. A completed asynchronous capture
    /// with a changed target must never supply pixels for this fallback.
    private func keepPreviousIfEligible(for key: DesktopWindowKey, as target: DesktopWindowTarget?) {
        guard let target, permitsWindow(key), visible[target.display]?.contains(key) == true,
              streams[key].map({ $0.publishedEpoch == $0.stream.epoch }) != false, var still = stills.peek(.current(key)),
              still.canRetainPrevious(target, lifetime: lifetime(key), now: ProcessInfo.processInfo.systemUptime),
              target.liveOwner() != nil, target.sharedSurface(visible: false, matchFrame: false),
              let cost = PreviewPixelBudget.charge(still.capture.image) else {
            return
        }
        if still.use != .previous {
            audit?.record(key, .cache, .previous)
            still.use = .previous
            stills.store(still, for: .current(key), cost: cost)
        }
    }

    /// Pixel dimensions are downsampled. Keep the independent window filter's point
    /// dimensions with the same identity, lifetime and membership as its captured image.
    func capturedSizes(for windows: [WindowObservation], in snapshot: DesktopSnapshot, permitted: Bool) -> [UInt32: CGSize] {
        guard permitted else { return [:] }
        var result = [UInt32: CGSize]()
        for window in windows {
            guard let target = DesktopWindowTarget.preview(window, in: snapshot), permitsWindow(target.key),
                  let known = sizes[target.key], stills.contains(.current(target.key)), known.incarnation == lifetime(target.key),
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
              WindowPermissionProbe.screen.allowed(), let still = stills.peek(.current(key)), still.use != .previous, still.lifetime == lifetime(key),
              still.target.session == session, still.target.topology == topology, still.target.display == display,
              still.target.overviewSpace == space, ProcessInfo.processInfo.systemUptime - still.time < 60,
              still.target.liveOwner() != nil, still.target.sharedSurface(visible: false, matchFrame: false)
        else { return nil }
        stills.touch(.current(key))
        return still.capture.image
    }

    /// Remember only a frame that the normal visible card already displayed.
    /// This reuses the gallery's bounded LRU without mounting a card or starting a stream.
    @discardableResult func remember(_ departure: StageGroupDeparture, in snapshot: DesktopSnapshot, observed: Bool = false) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard departure.matches(snapshot), snapshot.nativeIsFresh(now:.now,uptime:now),
              WindowContentPreview.sessionAvailable(), WindowPermissionProbe.screen.allowed() else { return false }
        var saved = false
        for member in departure.members {
            let key = member.key
            let slot = observed ? StillSlot.observed(key) : .held(key)
            let previous = stills.peek(slot)
            guard permitsWindow(key), lifetime(key) == member.appearance, let row = snapshot.windows.first(where: { DesktopWindowKey($0) == key }),
                  let target = DesktopWindowTarget.preview(row, in:snapshot), target.publiclyVisible, target.frame == member.before.frame,
                  visible[target.display]?.contains(key) == true,
                  var still = stills.peek(.current(key)),
                  let live = streams[key], !live.cancelled, live.sequence > 0, live.publishedEpoch == live.stream.epoch,
                  still.matches(target,lifetime:member.appearance,now:now,confirmedAt:live.confirmedAt),
                  live.lastShown === still.capture.image, viewport[target.display]?[key] == true,
                  still.signedOwner?.stillSigned(as:key) == true,
                  target.pictureEligibility(needsMembership:live.needsMembership,owner:live.owner,audit:audit) == .allowed,
                  let cost = PreviewPixelBudget.charge(still.capture.image) else { continue }
            if observed {
                if previous?.departure == departure.stamp(for:member), let original = previous?.original {
                    guard original.matches(key) else { stills.remove(slot); continue }
                    still.original = original
                } else {
                    guard let original = StagePictureOriginal(key) else { continue }
                    still.original = original
                }
            }
            still.departure = departure.stamp(for:member)
            stills.store(still, for:slot,cost:cost)
            saved = saved || stills.contains(slot)
        }
        return saved
    }

    func clearHeldPictures() {
        stills.remove { slot, _ in if case .held = slot { return true }; return false }
    }

    func retains(_ departure: StageGroupDeparture) -> Bool {
        departure.members.contains { stills.peek(.held($0.key))?.departure == departure.stamp(for:$0) }
    }

    func heldImage(_ member: StageGroupDeparture.Member, departure: StageGroupDeparture,
                   snapshot: DesktopSnapshot, permitted: Bool, confirmOwner: () -> Bool) -> CGImage? {
        let key = member.key, now = ProcessInfo.processInfo.systemUptime
        guard permitted, permitsWindow(key), snapshot.nativeIsFresh(now:.now,uptime:now),
              WindowContentPreview.sessionAvailable(), WindowPermissionProbe.screen.allowed() else { return nil }
        return Self.heldPixels(member, departure:departure, snapshot:snapshot, cache:stills, appearance:lifetime(key), now:now) { still in
            guard still.signedOwner?.stillSigned(as:key) == true && confirmOwner() else { return false }
            let access = still.target.lastFrameAccess()
            if access == .surfaceMismatch || access == .sharingDenied { discardRevokedPictures(key) }
            return access == .allowed
        }
    }

    static func heldPixels(_ member: StageGroupDeparture.Member, departure: StageGroupDeparture, snapshot: DesktopSnapshot,
                           cache: PreviewPixelCache<StillSlot, Still>, appearance: UUID?, now: TimeInterval, observed: Bool = false,
                           allows: (Still) -> Bool) -> CGImage? {
        let slot = observed ? StillSlot.observed(member.key) : .held(member.key)
        guard departure.matches(snapshot), let still = cache.peek(slot),
              still.matchesDeparture(member,departure,now:now,appearance:appearance), allows(still) else { return nil }
        cache.touch(slot)
        return still.capture.image
    }

    func observedImage(_ key: DesktopWindowKey, group id: UUID, snapshot:DesktopSnapshot, permitted:Bool) -> CGImage? {
        let now = ProcessInfo.processInfo.systemUptime
        guard permitted, permitsWindow(key), let group = observedGroups[id], let member = group.members.first(where:{ $0.key == key }),
              snapshot.nativeIsFresh(now:.now,uptime:now), snapshot.native?.catalogComplete == true,
              WindowContentPreview.sessionAvailable(), WindowPermissionProbe.screen.allowed() else { return nil }
        guard group.matches(snapshot), let saved = stills.peek(.observed(key)), saved.departure == group.stamp(for:member) else { return nil }
        let appearance = observedAppearance(for: member, in: saved)
        guard group.containsOriginal(member,in:snapshot,appearance:appearance) else { return nil }
        return Self.heldPixels(member,departure:group,snapshot:snapshot,cache:stills,appearance:appearance,now:now,observed:true) { still in
            let access = still.target.lastFrameAccess()
            if access == .surfaceMismatch || access == .sharingDenied { discardRevokedPictures(key) }
            return access == .allowed && still.signedOwner?.stillSigned(as:key) == true && still.original?.matches(key) == true
        }
    }

    // The roster gives a returning window a new appearance. Only the retained AX
    // object and the same signed process can link it to this historical picture.
    private func observedAppearance(for member: StageGroupDeparture.Member, in still: Still) -> UUID? {
        let current = lifetime(member.key)
        guard let current, current != member.appearance,
              still.original?.matches(member.key, appearance: current, ownerUnchanged: {
                  still.signedOwner?.stillSigned(as:member.key) == true
              }) == true else { return current }
        return member.appearance
    }

    private func observePictures(on display: String, snapshot: DesktopSnapshot?, now: TimeInterval,
                                 groups: (DesktopSnapshot) -> ObservedPictureGroups?) {
        let existing = observedGroups.filter { $0.value.scope.display.uuidString.caseInsensitiveCompare(display) == .orderedSame }
        guard !existing.isEmpty || streams.values.contains(where: {
            $0.target.display == display && !$0.cancelled && $0.lastShown != nil && viewport[display]?[$0.target.key] == true
        }) else {
            recentInventory[display] = nil
            return
        }
        let old = recentInventory[display]
        if let snapshot, let old, old.snapshot.sessionID == snapshot.sessionID, old.snapshot.revision == snapshot.revision,
           snapshot.nativeIsFresh(now:.now,uptime:now) { return }
        guard let snapshot, snapshot.nativeIsFresh(now:.now,uptime:now), snapshot.native?.catalogComplete == true,
              snapshot.topologyConsistent, let directory = groups(snapshot) else {
            recentInventory[display] = nil
            return
        }
        var currentAppearances = [DesktopWindowKey: UUID]()
        for key in directory.lifetimes.keys { currentAppearances[key] = lifetime(key) }
        recentInventory[display] = .init(snapshot:snapshot,lifetimes:directory.lifetimes,appearances:currentAppearances)
        for (id, group) in existing {
            if group.scope != directory.scope {
                if !group.members.contains(where: { stills.peek(.observed($0.key))?.departure == group.stamp(for:$0) }) {
                    observedGroups[id] = nil
                }
                continue
            }
            let entry = directory.groups.first { $0.id == id }
            let current = entry.map { $0.needsReorganization != true &&
                Set($0.members.map(\.id)) == Set(group.members.map(\.id)) } == true
            var remaining = false
            for member in group.members {
                let slot = StillSlot.observed(member.key)
                guard let still = stills.peek(slot), still.departure == group.stamp(for:member) else { continue }
                // A returning original may not answer AX during this inventory.
                // Retain on matching membership. Drawing still requires the original AX object.
                if current, group.containsOriginal(member,in:snapshot,appearance:nil),
                   now >= still.time { remaining = true }
                else { stills.remove(slot) }
            }
            if !remaining { observedGroups[id] = nil }
        }
        guard let old, old.snapshot.revision < snapshot.revision, old.snapshot.nativeIsFresh(now:.now,uptime:now),
              now - (lastObservation[display] ?? -.infinity) >= 1 else { return }
        lastObservation[display] = now
        for group in directory.groups where directory.visible.contains(group.id) {
            guard let next = StageGroupDeparture.observed(group,scope:directory.scope,area:directory.area,
                opening:old.snapshot,closing:snapshot,earlierLifetimes:old.lifetimes,lifetimes:directory.lifetimes,
                earlierAppearances:old.appearances,appearances:currentAppearances) else { continue }
            let prior = observedGroups[group.id]
            let held = prior.flatMap { $0.sameLayout(as:next) ? $0 : nil } ?? next
            let saved = remember(held,in:snapshot,observed:true)
            if saved, prior != held { observedGroups[group.id] = held }
        }
    }

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
             recheck: (() async -> DesktopSnapshot?)? = nil, groups: ((DesktopSnapshot) -> ObservedPictureGroups?)? = nil) async {
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
            if operations[display] == token {
                clear(display: display, keepingCardFrames: allowed() && WindowContentPreview.sessionAvailable() && WindowPermissionProbe.screen.allowed())
            }
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
                      live.target.samePicture(as: target), live.target.publiclyVisible == target.publiclyVisible else {
                    audit?.record(key, .lifecycle, .targetChanged, epoch: live.stream.epoch, sequence: live.sequence)
                    live.cancel()
                    keepPreviousIfEligible(for: key, as: active[key])
                    retry.removeValue(forKey: key)
                    continue
                }
                live.target = target
            }
            let now = ProcessInfo.processInfo.systemUptime
            if let groups { observePictures(on:display,snapshot:sample,now:now,groups:groups) }
            for live in streams.values where live.target.display == display && !live.cancelled && live.sequence == 0 && now - live.acquired > 5 {
                live.cancel()
                retry[live.target.key] = now + 2
            }
            let screen = sample?.displays.first { $0.id == display }
            let owners = Dictionary(grouping: sample?.windows.compactMap(DesktopWindowKey.init) ?? [], by: \.number)
            stills.remove { slot, still in
                guard still.target.display == display else { return false }
                let key = still.target.key
                guard permitsWindow(key) else { return true }
                guard let sample else { return false }
                guard sample.sessionID == still.target.session, still.target.matchesScreen(screen) else { return true }
                if owners[key.number]?.contains(where: { $0 != key }) == true { return true }
                if case .current = slot, still.use == .previous, let target = active[key] {
                    return !still.canRetainPrevious(target, lifetime: lifetime(key), now: now)
                }
                // The owner remains on its home desktop while the user visits
                // another. Every history lookup separately verifies that home scope.
                return false
            }
            for (key, measurement) in sizes where measurement.target.display == display && !stills.contains(.current(key)) {
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
                    if victim.publishedEpoch == victim.stream.epoch, var still = stills.peek(.current(victim.target.key)), still.use == .current,
                       let cost = PreviewPixelBudget.charge(still.capture.image) {
                        audit?.record(victim.target.key, .cache, .recent)
                        still.use = .recent; stills.store(still, for: .current(victim.target.key), cost: cost)
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
                let target = live.target
                if case .unavailable = update {
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
                    let previous = live.publishedEpoch != epoch ? stills.peek(.current(key)) : nil
                    let priorImage = previous.flatMap { still in
                        target.sameCard(as: still.target) && still.capture.logicalSize == pipe.logicalSize ? still.capture.image : nil
                    }
                    guard let image = frame.image(reusing: priorImage) else {
                        audit?.record(key, .membership, .conversionFailed, epoch: epoch, sequence: live.sequence)
                        continue
                    }
                    capture = Capture(image: image, logicalSize: pipe.logicalSize)
                case .idle:
                    // Refresh live evidence without assigning the same bitmap to an observable card.
                    guard live.sequence > 0, live.publishedEpoch == epoch, let last = stills.peek(.current(key)), last.use == .current,
                          last.lifetime == live.incarnation, last.target.samePicture(as: target),
                          pipe.epoch == epoch, !publicMembership || target.inPublicActiveList() else { continue }
                    live.confirmedAt = received
                    continue
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
                live.sequence &+= 1
                live.publishedEpoch = epoch
                deliveredFrameCount &+= 1
                let published = ProcessInfo.processInfo.systemUptime
                live.confirmedAt = published
                stills.store(Still(target: target, lifetime: live.incarnation, capture: capture,
                                  time: published, signedOwner: live.owner, original: live.original), for: .current(key), cost: cost)
                if case let .frame(frame) = update { pipe.published(frame) }
                if let audit {
                    let stored = stills.peek(.current(key))
                    let accepted = stored?.use == .current && stored?.capture.image === capture.image
                    audit.record(key, .cache, accepted ? .current : .notStored, epoch: epoch, sequence: live.sequence)
                }
                let measurement = MeasuredSize(target: target, incarnation: live.incarnation, size: capture.logicalSize)
                if sizes[key] != measurement { sizes[key] = measurement }
            }
        }
        audit?.record(key, .lifecycle, .ended, epoch: pipe.epoch, sequence: live.sequence)
        live.cancelled = true
        pipe.finishOutput()
        if started { await pipe.stop() }
        if streams[key] === live {
            streams.removeValue(forKey: key)
            changes[target.display]?.yield(())
        }
        live.task = nil
    }
}
