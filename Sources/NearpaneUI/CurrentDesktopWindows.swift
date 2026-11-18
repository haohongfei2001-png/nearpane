import AppKit
import NearpaneCore
import OSLog

/// One fast, metadata-only feed for all visible sidebar panels. The full reader
/// serves geometry and window management independently of the window switcher.
@MainActor @Observable final class CurrentDesktopWindows {
    typealias Read = NativeDesktopProvider.Read
    private let read: Read
    private let sessionAvailable: @MainActor () -> Bool
    private let fingerprint: @MainActor () -> Int
    private let session = UUID()
    private var revision: UInt64 = 0
    private(set) var snapshot: DesktopSnapshot?
    /// Presentation can bridge a short transient. Management and actions only consume
    /// snapshot/readNow, which lose authority on the first failed observation.
    private(set) var lastPresentation: DesktopSnapshot?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var lifetimes = [DesktopWindowKey: UUID]()
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
         fingerprint: @escaping @MainActor () -> Int = CurrentDesktopWindows.windowNumbersFingerprint) {
        self.read = read; self.sessionAvailable = sessionAvailable; self.fingerprint = fingerprint
    }

    func changed() { events?.yield(()) }

    func invalidate() {
        epoch = UUID()
        pending?.1.cancel()
        pending = nil
        snapshot = nil
        lastPresentation = nil
        lifetimes.removeAll()
        retry?.cancel(); retry = nil; failures = 0
        didSample?()
        changed()
    }

    func observe(_ enable: Bool) {
        panelRequested = enable
        updateObservation()
    }

    func observeManagement(_ enable: Bool) {
        managementRequested = enable
        updateObservation()
    }

    private func updateObservation() {
        let enable = panelRequested || managementRequested
        if !enable {
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
                while !Task.isCancelled {
                    let now = ContinuousClock.now, numbers = fingerprint()
                    if numbers != previous {
                        previous = numbers
                        // WindowServer's numbers can precede the settled Space membership.
                        settleUntil = now.advanced(by: .milliseconds(760))
                    }
                    if now < settleUntil || now - last >= .seconds(3) {
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
                retry?.cancel()
                retry = nil
                if let next {
                    lastPresentation = next
                    failures = 0
                } else {
                    failures = min(4, failures + 1)
                    if failures >= 3 || !sessionAvailable() { lastPresentation = nil }
                    let delay = [180, 360, 720, 1500][failures - 1]
                    retry = Task {
                        do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                        guard expected == epoch else { return }
                        events.yield(())
                    }
                }
                didSample?()
                if let next {
                    let counts = [next.windows.count, next.windows.filter { $0.metadata?.onActiveDesktop == false }.count]
                    if counts != reportedCounts {
                        reportedCounts = counts
                        Logger(subsystem: "com.holdsnow.nearpane.alpha", category: "WindowOverview")
                            .info("Current desktop windows: total=\(counts[0], privacy: .public) background=\(counts[1], privacy: .public)")
                    }
                }
            }
        }
    }

    /// Used on both sides of a background picture batch and before an explicit click.
    /// Concurrent consumers join the same in-flight read.
    func readNow() async -> DesktopSnapshot? {
        guard events != nil, sessionAvailable() else { lifetimes.removeAll(); return nil }
        let expected = epoch
        if let pending {
            let result = await pending.1.value
            return expected == epoch ? result : nil
        }
        revision &+= 1
        let request = DesktopReadRequest(session: session, revision: revision, parentPID: getpid(),
            fixtureWindows: nil, anchors: [], experimentalSpaces: false)
        let task = Task { [read, weak self] () -> DesktopSnapshot? in
            let readback = try? await read(request)
            guard let self, !Task.isCancelled, expected == self.epoch else { return nil }
            guard let result = readback, self.sessionAvailable(),
                  result.sessionID == request.session, result.revision == request.revision, result.isStructurallyValid,
                  result.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime) else {
                self.lifetimes.removeAll()
                return nil
            }
            var next = [DesktopWindowKey: UUID]()
            for window in result.windows {
                guard let meta = window.metadata, let birth = meta.launchMicroseconds, birth > 0 else { continue }
                let key = DesktopWindowKey(pid: meta.pid, birth: birth, number: meta.number)
                next[key] = self.lifetimes[key] ?? UUID()
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
