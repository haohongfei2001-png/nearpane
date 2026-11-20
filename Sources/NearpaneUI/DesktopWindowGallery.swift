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

    /// For the tiler's separately authorized AX resolver. No gallery or input target escapes.
    static func tilingCandidate(_ window: WindowObservation, in snapshot: DesktopSnapshot) -> (key: DesktopWindowKey, visible: Bool)? {
        guard let target = Self(surface: window, in: snapshot), let current = target.overviewSpace,
              target.membership == .known(recordIDs: [current]) else { return nil }
        return (target.key, target.publiclyVisible)
    }

    private init?(surface window: WindowObservation, in snapshot: DesktopSnapshot) {
        guard snapshot.isCurrentDesktopSurface(window), let m = window.metadata, m.pid > 1, let birth = m.launchMicroseconds, birth > 0,
              m.number > 0, m.fullScreen != true, m.globalFrame.geometry.isValid,
              window.confidence != .synthetic,
              window.confidence != .ambiguous || (m.element == nil && m.axFrame == nil && m.axStandardWindowNumber == nil),
              m.axFrame == nil || m.presentation == .confirmed,
              m.axStandardWindowNumber == nil || m.axStandardWindowNumber == m.number else { return nil }
        let active = snapshot.scopes.filter { $0.displayID == window.displayID }.flatMap(\.records).filter(\.isCurrent)
        guard active.count <= 1 else { return nil }
        publiclyVisible = m.isOnscreen == true && m.onActiveDesktop == true && m.minimized != true
        if let space = m.overviewSpaceID {
            guard active.first?.id == space, active.first?.ordinaryUUID != nil,
                  case .known(let members) = window.membership, members.contains(space) else { return nil }
        } else if !publiclyVisible { return nil }
        overviewSpace = m.overviewSpaceID
        key = .init(pid: m.pid, birth: birth, number: m.number)
        session = snapshot.sessionID; topology = snapshot.topologyFingerprint
        display = window.displayID; current = active.first?.id
        membership = window.membership; frame = m.globalFrame
        desktopUUID = active.first?.ordinaryUUID
        stageEnabled = snapshot.native?.stageManagerEnabled == true
        catalogSize = m.catalogLogicalFrame.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Reordering the stage can leave the same window at a new origin. Resizing the
    /// real window invalidates the cached pixels regardless of its Space membership.
    func samePicture(as other: Self) -> Bool {
        if self == other { return true }
        return overviewSpace != nil && overviewSpace == other.overviewSpace && key == other.key &&
            session == other.session && topology == other.topology && display == other.display && desktopUUID == other.desktopUUID &&
            frame.width == other.frame.width && frame.height == other.frame.height && catalogSize == other.catalogSize
    }

    func present(in snapshot: DesktopSnapshot?, now: Date = .now, uptime: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let snapshot, snapshot.sessionID == session, snapshot.topologyFingerprint == topology else { return false }
        let matched = snapshot.currentDesktopWindows(on: display, now: now, uptime: uptime)
            .filter { $0.metadata?.number == key.number }
        return matched.count == 1 && matched.first.flatMap { DesktopWindowTarget($0, in: snapshot) }.map(samePicture(as:)) == true
    }

    func liveOwner() -> NSRunningApplication? {
        var info = proc_bsdinfo()
        let n = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(key.pid, PROC_PIDTBSDINFO, 0, &info, n) == n,
              info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec == key.birth,
              let app = NSRunningApplication(processIdentifier: key.pid), !app.isTerminated,
              app.activationPolicy == .regular, let bundle = app.bundleIdentifier,
              !bundle.isEmpty, !bundle.hasPrefix("com.holdsnow.nearpane"), !bundle.hasPrefix("org.nearpane.")
        else { return nil }
        return app
    }

    /// Never read window titles. Require the same shared layer-zero surface, its on-screen
    /// frame and the public current-desktop list on both sides of an asynchronous capture.
    @MainActor func isVisibleSurface(for purpose: SurfacePurpose = .picture) -> Bool {
        guard liveOwner() != nil,
              (NSWindow.windowNumbers(options: .allApplications) ?? []).contains(NSNumber(value: key.number)) else { return false }
        return sharedSurface(visible: true, matchFrame: true, for: purpose)
    }

    enum SurfacePurpose {
        case picture, windowSelection

        func accepts(drawn: Bool, allowsContent: Bool) -> Bool {
            drawn && (self == .windowSelection || allowsContent)
        }
    }

    func sharedSurface(visible: Bool, matchFrame: Bool, for purpose: SurfacePurpose = .picture) -> Bool {
        guard let row = WindowSurfaceRecord(number: key.number), row.pid == key.pid, row.layer == 0,
              purpose.accepts(drawn: row.isDrawn, allowsContent: row.allowsContent), !visible || row.isOnscreen
        else { return false }
        return !matchFrame || row.frame == frame
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
        enum Use { case current, previous, mapOnly }
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
            canRetainPrevious(candidate, lifetime: current, now: now) && candidate.catalogSize == capture.logicalSize &&
                (use == .previous || candidate.presentedSize != capture.logicalSize)
        }

        func matches(_ candidate: DesktopWindowTarget, lifetime current: UUID?, now: TimeInterval) -> Bool {
            use == .current && current == lifetime && target.samePicture(as: candidate) && now >= time && now - time < 12
        }
    }
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
    private let permitsWindow: (DesktopWindowKey) -> Bool
    private let lifetime: (DesktopWindowKey) -> UUID?

    init(permitsWindow: @escaping (DesktopWindowKey) -> Bool, lifetime: @escaping (DesktopWindowKey) -> UUID?) {
        self.permitsWindow = permitsWindow
        self.lifetime = lifetime
    }

    func setCard(_ key: DesktopWindowKey, on display: String, visible onScreen: Bool) {
        if onScreen {
            if visible[display, default: []].insert(key).inserted { changes[display]?.yield(()) }
        }
        else {
            visible[display]?.remove(key)
            if var still = stills.peek(key) {
                if still.use == .previous || still.target.overviewSpace == nil { stills.remove(key) }
                else if let cost = PreviewPixelBudget.charge(still.capture.image) {
                    still.use = .mapOnly
                    stills.store(still, for: key, cost: cost)
                }
            }
            missingPictures.removeValue(forKey: key)
        }
    }

    func clear(display: String? = nil) {
        if let display {
            operations.removeValue(forKey: display)
            changes.removeValue(forKey: display)?.finish()
            stills.remove { _, still in still.target.display == display }
            missingPictures = missingPictures.filter { $0.value != display }
        } else {
            generation &+= 1
            operations.removeAll(); stills.removeAll(); missingPictures.removeAll()
            for events in changes.values { events.finish() }
            changes.removeAll()
        }
    }

    func image(for target: DesktopWindowTarget, permitted: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CGImage? {
        guard permitted, permitsWindow(target.key), visible[target.display]?.contains(target.key) == true,
              let still = stills.peek(target.key), still.matches(target, lifetime: lifetime(target.key), now: now),
              WindowContentPreview.sessionAvailable(), WindowPermissionProbe.screen.allowed() else { return nil }
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
              var still = stills.peek(key),
              still.canRetainPrevious(target, lifetime: lifetime(key), now: ProcessInfo.processInfo.systemUptime),
              target.liveOwner() != nil, target.sharedSurface(visible: false, matchFrame: false),
              let cost = PreviewPixelBudget.charge(still.capture.image) else {
            stills.remove(key)
            return
        }
        if still.use != .previous {
            still.use = .previous
            stills.store(still, for: key, cost: cost)
        }
    }

    /// Pixel dimensions are downsampled. Keep the independent window filter's point
    /// dimensions with the same identity, lifetime and membership as its captured image.
    func capturedSizes(for windows: [WindowObservation], in snapshot: DesktopSnapshot, permitted: Bool) -> [UInt32: CGSize] {
        guard permitted else { return [:] }
        let now = ProcessInfo.processInfo.systemUptime
        var sizes = [UInt32: CGSize]()
        for window in windows {
            guard let target = DesktopWindowTarget(window, in: snapshot), permitsWindow(target.key),
                  let still = stills.peek(target.key), still.matches(target, lifetime: lifetime(target.key), now: now) else { continue }
            sizes[target.key.number] = still.capture.logicalSize
        }
        return sizes
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

    /// Scope checks are batched. Each image uses a filter for exactly one shared window.
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
        var attempted = [DesktopWindowKey: TimeInterval]()
        var misses = [DesktopWindowKey: Int]()
        var lastTargets = [DesktopWindowKey: DesktopWindowTarget]()
        func permitted() -> Bool {
            !Task.isCancelled && operations[display] == token && allowed() &&
                WindowContentPreview.sessionAvailable() && WindowPermissionProbe.screen.allowed()
        }
        for await _ in stream {
            guard permitted() else { return }
            guard let sample = snapshot() else { continue }
            let members = sample.currentDesktopWindows(on: display, now: .now, uptime: ProcessInfo.processInfo.systemUptime)
            let targets = members.compactMap { DesktopWindowTarget($0, in: sample) }
                .filter { permitsWindow($0.key) && visible[display]?.contains($0.key) == true }
            let active = Dictionary(uniqueKeysWithValues: targets.map { ($0.key, $0) })
            for target in targets {
                if let old = lastTargets[target.key], old.publiclyVisible != target.publiclyVisible || !old.samePicture(as: target) {
                    attempted.removeValue(forKey: target.key)
                    misses.removeValue(forKey: target.key)
                    if !old.samePicture(as: target) {
                        keepPreviousIfEligible(for: target.key, as: target)
                        missingPictures.removeValue(forKey: target.key)
                    }
                }
            }
            lastTargets = active
            let observed = Dictionary(grouping: sample.windows, by: { $0.metadata?.number })
            stills.remove { key, still in
                if still.lifetime != lifetime(key) { return true }
                if still.use == .previous && still.target.display == display {
                    guard let member = active[key],
                          still.canRetainPrevious(member, lifetime: lifetime(key), now: ProcessInfo.processInfo.systemUptime),
                          member.sharedSurface(visible: false, matchFrame: false) else { return true }
                    return false
                }
                let old = still.target
                guard old.display == display, active[key]?.samePicture(as: old) != true else { return false }
                guard let space = old.overviewSpace, old.session == sample.sessionID, old.topology == sample.topologyFingerprint,
                      ProcessInfo.processInfo.systemUptime - still.time < 60, let matches = observed[key.number], matches.count == 1,
                      let row = matches.first, row.displayID == display, row.metadata?.pid == key.pid,
                      row.metadata?.launchMicroseconds == key.birth, case .known(let members) = row.membership,
                      members.contains(space) else { return true }
                return false
            }
            attempted = attempted.filter { active[$0.key] != nil }
            misses = misses.filter { active[$0.key] != nil }
            let now = ProcessInfo.processInfo.systemUptime
            func hasFreshPicture(_ target: DesktopWindowTarget) -> Bool {
                stills.peek(target.key)?.matches(target, lifetime: lifetime(target.key), now: now) == true
            }
            let due = targets.filter { target in
                // Newly mapped windows may be registered before SCK can deliver a surface.
                let firstPicture = !hasFreshPicture(target) && (misses[target.key] ?? 0) < 4
                let interval: TimeInterval = firstPicture ? 0.20 : (target.publiclyVisible ? 1 : 2)
                return now - (attempted[target.key] ?? -.infinity) >= interval
            }
                .sorted { (attempted[$0.key] ?? 0) < (attempted[$1.key] ?? 0) }
            guard !due.isEmpty else { continue }
            // Freeze the observed generation before awaiting ScreenCaptureKit's catalogue.
            // Window numbers can be reused by a still-running owner.
            let issued = Dictionary(uniqueKeysWithValues: due.compactMap { target in
                lifetime(target.key).map { (target.key, $0) }
            })
            guard !issued.isEmpty else { continue }
            // An on-screen card can verify public presentation synchronously. Only
            // off-stage members need extra membership samples around their pixels.
            let includeOffstage = due.contains { $0.overviewSpace != nil }
            guard permitted() else { return }
            for target in due {
                attempted[target.key] = now
                if !hasFreshPicture(target) { misses[target.key, default: 0] += 1 }
            }
            // Enumeration itself can fail even after a positive TCC preflight.
            // Apply the same bounded retry and feedback as a per-surface failure.
            func noteUnavailable(_ targets: [DesktopWindowTarget]) {
                for target in targets where (misses[target.key] ?? 0) >= 2 &&
                    visible[display]?.contains(target.key) == true && missingPictures[target.key] == nil {
                    missingPictures[target.key] = display
                }
            }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: !includeOffstage)
            else {
                if permitted() { noteUnavailable(due) }
                continue
            }
            let shared = Dictionary(grouping: content.windows, by: \.windowID)
            let viaMembership = Set(due.compactMap { target -> DesktopWindowKey? in
                guard target.overviewSpace != nil, let source = shared[target.key.number]?.first else { return nil }
                return target.publiclyVisible && source.isOnScreen && target.matches(source.frame) ? nil : target.key
            })
            for batch in Self.captureBatches(due, membership: viaMembership) {
                guard permitted() else { return }
                let requiresMembership = viaMembership.contains(batch[0].key)
                let before = requiresMembership ? await recheck?() : snapshot()
                guard permitted() else { return }
                guard let before else { noteUnavailable(batch); continue }
                var jobs = [(DesktopWindowTarget, Task<Capture?, Never>)]()
                for target in batch {
                    guard let generation = issued[target.key], generation == lifetime(target.key),
                          target.present(in: before), target.present(in: snapshot()), visible[display]?.contains(target.key) == true,
                          let candidates = shared[target.key.number], candidates.count == 1, let window = candidates.first,
                          target.liveOwner() != nil, window.owningApplication?.processID == target.key.pid,
                          window.windowLayer == 0 else { continue }
                    if requiresMembership {
                        guard target.sharedSurface(visible: false, matchFrame: true) else { continue }
                    } else {
                        guard window.isOnScreen, target.matches(window.frame), target.isVisibleSurface() else { continue }
                    }
                    jobs.append((target, Task {
                        guard permitted(), generation == lifetime(target.key), visible[display]?.contains(target.key) == true else { return nil }
                        return await self.capture(window, target: target)
                    }))
                }
                var pictures = [(DesktopWindowTarget, Capture)]()
                for (target, job) in jobs {
                    if let capture = await job.value { pictures.append((target, capture)) }
                }
                guard permitted() else { return }
                let returned = Set(pictures.map { $0.0.key })
                noteUnavailable(batch.filter { !returned.contains($0.key) })
                guard !pictures.isEmpty, permitted() else { continue }
                // A window can be moved to another Space without the user changing desktops.
                // A fresh independent membership read protects the publication of those pixels.
                let after = requiresMembership ? await recheck?() : snapshot()
                guard permitted() else { return }
                for (target, capture) in pictures {
                    guard let generation = issued[target.key], generation == lifetime(target.key),
                          target.present(in: after), target.present(in: snapshot()), permitsWindow(target.key),
                          visible[display]?.contains(target.key) == true, target.liveOwner() != nil,
                          (requiresMembership ? target.sharedSurface(visible: false, matchFrame: true) : target.isVisibleSurface()) else {
                        func member(in latest: DesktopSnapshot?) -> DesktopWindowTarget? {
                            guard let latest else { return nil }
                            let rows = latest.currentDesktopWindows(on: display, now: .now, uptime: ProcessInfo.processInfo.systemUptime)
                                .filter { $0.metadata?.number == target.key.number }
                            return rows.count == 1 ? rows.first.flatMap { DesktopWindowTarget($0, in: latest) } : nil
                        }
                        if let independent = member(in: after), let still = stills.peek(target.key),
                           still.canRetainPrevious(independent, lifetime: lifetime(target.key), now: ProcessInfo.processInfo.systemUptime) {
                            keepPreviousIfEligible(for: target.key, as: member(in: snapshot()))
                        } else { stills.remove(target.key) }
                        noteUnavailable([target])
                        continue
                    }
                    guard let cost = PreviewPixelBudget.charge(capture.image) else { continue }
                    let still = Still(target: target, lifetime: generation, capture: capture, time: ProcessInfo.processInfo.systemUptime)
                    stills.store(still, for: target.key, cost: cost)
                    misses.removeValue(forKey: target.key)
                    missingPictures.removeValue(forKey: target.key)
                }
            }
        }
    }

    private func capture(_ window: SCWindow, target: DesktopWindowTarget) async -> Capture? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let rect = filter.contentRect
        guard target.acceptsContentSize(rect.size) else { return nil }
        let scale = min(1, 420 / max(rect.width, rect.height))
        let config = SCStreamConfiguration()
        config.width = max(1, Int((rect.width * scale).rounded()))
        config.height = max(1, Int((rect.height * scale).rounded()))
        config.showsCursor = false; config.capturesAudio = false; config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true; config.preservesAspectRatio = true
        if #available(macOS 14.2, *) { config.includeChildWindows = false }
        captureRequests &+= 1
        capturesInFlight += 1
        defer { capturesInFlight -= 1 }
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return Capture(image: image, logicalSize: rect.size)
    }
}
