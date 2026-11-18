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

    init?(_ window: WindowObservation, in snapshot: DesktopSnapshot) {
        guard let m = window.metadata, m.pid > 1, let birth = m.launchMicroseconds, birth > 0,
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
    }

    /// Ordering a stage or resizing its card doesn't change the pixels' owning window.
    /// Without a current-Space proof the original public frame binding stays strict.
    func samePicture(as other: Self) -> Bool {
        if self == other { return true }
        return overviewSpace != nil && overviewSpace == other.overviewSpace && key == other.key &&
            session == other.session && topology == other.topology && display == other.display
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
    @MainActor func isVisibleSurface() -> Bool {
        guard liveOwner() != nil,
              (NSWindow.windowNumbers(options: .allApplications) ?? []).contains(NSNumber(value: key.number)) else { return false }
        return sharedSurface(visible: true, matchFrame: true)
    }

    func sharedSurface(visible: Bool, matchFrame: Bool) -> Bool {
        guard let row = WindowSurfaceRecord(number: key.number), row.pid == key.pid, row.layer == 0,
              row.allowsContent, !visible || row.isOnscreen
        else { return false }
        return !matchFrame || row.frame == frame
    }

    func matches(_ rect: CGRect) -> Bool {
        frame == SurfaceRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}

@MainActor @Observable final class DesktopWindowGallery {
    private struct Still {
        let target: DesktopWindowTarget
        let image: CGImage
        let time: TimeInterval
    }
    private let stills = PreviewPixelCache<DesktopWindowKey, Still>()
    @ObservationIgnored private(set) var captureRequests: UInt64 = 0
    @ObservationIgnored private(set) var capturesInFlight = 0
    var cacheCount: Int { stills.count }
    var cacheBytes: Int { stills.bytes }
    private var missingPictures = [DesktopWindowKey: String]()
    private(set) var generation: UInt64 = 0
    // A per-display lease prevents cancelled or superseded captures from being published.
    @ObservationIgnored private var operations = [String: UUID]()
    @ObservationIgnored private var changes = [String: AsyncStream<Void>.Continuation]()
    private var visible = [String: Set<DesktopWindowKey>]()
    private let permitsWindow: (DesktopWindowKey) -> Bool

    init(permitsWindow: @escaping (DesktopWindowKey) -> Bool = { _ in true }) {
        self.permitsWindow = permitsWindow
    }

    func setCard(_ key: DesktopWindowKey, on display: String, visible onScreen: Bool) {
        if onScreen {
            if visible[display, default: []].insert(key).inserted { changes[display]?.yield(()) }
        }
        else {
            visible[display]?.remove(key)
            if stills.peek(key)?.target.overviewSpace == nil { stills.remove(key) }
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
        guard permitted, visible[target.display]?.contains(target.key) == true,
              let still = stills.peek(target.key), still.target.samePicture(as: target), now - still.time < 12 else { return nil }
        stills.touch(target.key)
        return still.image
    }

    /// The caller resolves this exact key from fresh membership in the requested map row.
    /// Never reuse an unscoped foreground capture or start a capture on a background desktop.
    func imageForMap(key: DesktopWindowKey, display: String, space: String, session: UUID,
                     topology: String, permitted: Bool) -> CGImage? {
        guard permitted, permitsWindow(key), WindowContentPreview.sessionAvailable(),
              CGPreflightScreenCaptureAccess(), let still = stills.peek(key),
              still.target.session == session, still.target.topology == topology, still.target.display == display,
              still.target.overviewSpace == space, ProcessInfo.processInfo.systemUptime - still.time < 60,
              still.target.liveOwner() != nil, still.target.sharedSurface(visible: false, matchFrame: false)
        else { return nil }
        stills.touch(key)
        return still.image
    }

    func lacksPicture(_ target: DesktopWindowTarget) -> Bool { missingPictures[target.key] == target.display }

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
                WindowContentPreview.sessionAvailable() && CGPreflightScreenCaptureAccess()
        }
        for await _ in stream {
            guard permitted() else { return }
            guard let sample = snapshot() else { continue }
            let members = sample.currentDesktopWindows(on: display, now: .now, uptime: ProcessInfo.processInfo.systemUptime)
            let targets = members.compactMap { DesktopWindowTarget($0, in: sample) }
                .filter { permitsWindow($0.key) && visible[display]?.contains($0.key) == true }
            let active = Dictionary(uniqueKeysWithValues: targets.map { ($0.key, $0) })
            for target in targets {
                if let old = lastTargets[target.key], old.publiclyVisible != target.publiclyVisible || old.overviewSpace != target.overviewSpace {
                    attempted.removeValue(forKey: target.key)
                    misses.removeValue(forKey: target.key)
                }
            }
            lastTargets = active
            let observed = Dictionary(grouping: sample.windows, by: { $0.metadata?.number })
            stills.remove { key, still in
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
            let due = targets.filter { target in
                // Newly mapped windows may be registered before SCK can deliver a surface.
                let firstPicture = stills.peek(target.key) == nil && (misses[target.key] ?? 0) < 4
                let interval: TimeInterval = firstPicture ? 0.20 : (target.publiclyVisible ? 1 : 2)
                return now - (attempted[target.key] ?? -.infinity) >= interval
            }
                .sorted { (attempted[$0.key] ?? 0) < (attempted[$1.key] ?? 0) }
            guard !due.isEmpty else { continue }
            // An on-screen card can verify public presentation synchronously. Only
            // off-stage members need extra membership samples around their pixels.
            let includeOffstage = due.contains { $0.overviewSpace != nil }
            guard permitted(),
                  let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: !includeOffstage)
            else { continue }
            let shared = Dictionary(grouping: content.windows, by: \.windowID)
            let viaMembership = Set(due.compactMap { target -> DesktopWindowKey? in
                guard target.overviewSpace != nil, let source = shared[target.key.number]?.first else { return nil }
                return target.publiclyVisible && source.isOnScreen && target.matches(source.frame) ? nil : target.key
            })
            let before = viaMembership.isEmpty ? sample : await recheck?()
            guard let before, permitted() else { continue }
            for start in stride(from: 0, to: due.count, by: 4) {
                guard permitted() else { return }
                let batch = due[start..<min(start + 4, due.count)]
                var jobs = [(DesktopWindowTarget, Task<CGImage?, Never>)]()
                for target in batch {
                    attempted[target.key] = now
                    if stills.peek(target.key) == nil { misses[target.key, default: 0] += 1 }
                    guard target.present(in: before), target.present(in: snapshot()), visible[display]?.contains(target.key) == true,
                          let candidates = shared[target.key.number], candidates.count == 1, let window = candidates.first,
                          target.liveOwner() != nil, window.owningApplication?.processID == target.key.pid,
                          window.windowLayer == 0 else { continue }
                    if viaMembership.contains(target.key) {
                        guard target.sharedSurface(visible: false, matchFrame: true) else { continue }
                    } else {
                        guard window.isOnScreen, target.matches(window.frame), target.isVisibleSurface() else { continue }
                    }
                    jobs.append((target, Task {
                        guard permitted(), visible[display]?.contains(target.key) == true else { return nil }
                        return await self.capture(window)
                    }))
                }
                var pictures = [(DesktopWindowTarget, CGImage)]()
                for (target, job) in jobs {
                    if let image = await job.value { pictures.append((target, image)) }
                }
                guard permitted() else { return }
                let returned = Set(pictures.map { $0.0.key })
                for target in batch where !returned.contains(target.key) && (misses[target.key] ?? 0) >= 2 &&
                    visible[display]?.contains(target.key) == true && missingPictures[target.key] == nil {
                    missingPictures[target.key] = display
                }
                guard !pictures.isEmpty, permitted() else { continue }
                // A window can be moved to another Space without the user changing desktops.
                // A fresh independent membership read protects the publication of those pixels.
                let after = pictures.contains { viaMembership.contains($0.0.key) } ? await recheck?() : snapshot()
                guard permitted() else { return }
                for (target, image) in pictures {
                    guard target.present(in: after), target.present(in: snapshot()), permitsWindow(target.key),
                          visible[display]?.contains(target.key) == true, target.liveOwner() != nil,
                          (viaMembership.contains(target.key) ? target.sharedSurface(visible: false, matchFrame: true) : target.isVisibleSurface()) else {
                        stills.remove(target.key); continue
                    }
                    guard let cost = PreviewPixelBudget.charge(image) else { continue }
                    let still = Still(target: target, image: image, time: ProcessInfo.processInfo.systemUptime)
                    stills.store(still, for: target.key, cost: cost)
                    misses.removeValue(forKey: target.key)
                    missingPictures.removeValue(forKey: target.key)
                }
            }
        }
    }

    private func capture(_ window: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let rect = filter.contentRect
        guard rect.width.isFinite, rect.height.isFinite, min(rect.width, rect.height) > 0 else { return nil }
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
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
