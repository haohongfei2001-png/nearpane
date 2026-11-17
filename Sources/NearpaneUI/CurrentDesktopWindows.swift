import AppKit
import NearpaneCore
import OSLog

/// One fast, metadata-only feed for all visible sidebar panels. The full reader
/// serves geometry and window management independently of the window switcher.
@MainActor @Observable final class CurrentDesktopWindows {
    typealias Read = NativeDesktopProvider.Read
    private let read: Read
    private let sessionAvailable: @MainActor () -> Bool
    private let session = UUID()
    private var revision: UInt64 = 0
    private(set) var snapshot: DesktopSnapshot?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var pending: (UUID, Task<DesktopSnapshot?, Never>)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var events: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var reportedCounts: [Int]?

    init(read: @escaping Read, sessionAvailable: @escaping @MainActor () -> Bool = WindowContentPreview.sessionAvailable) {
        self.read = read; self.sessionAvailable = sessionAvailable
    }

    func changed() { events?.yield(()) }

    func invalidate() {
        epoch = UUID()
        pending?.1.cancel()
        pending = nil
        snapshot = nil
        changed()
    }

    func observe(_ enable: Bool) {
        if !enable {
            events?.finish(); events = nil
            loop?.cancel(); loop = nil
            invalidate()
            return
        }
        guard loop == nil else { return }
        let (stream, events) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.events = events
        loop = Task { [weak self] in
            let detector = Task {
                var previous: Int?, last = ContinuousClock.now
                var settleUntil = last
                while !Task.isCancelled {
                    let now = ContinuousClock.now, fingerprint = Self.windowNumbersFingerprint()
                    if fingerprint != previous {
                        previous = fingerprint
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
        guard events != nil, sessionAvailable() else { return nil }
        let expected = epoch
        if let pending {
            let result = await pending.1.value
            return expected == epoch ? result : nil
        }
        revision &+= 1
        let request = DesktopReadRequest(session: session, revision: revision, parentPID: getpid(),
            fixtureWindows: nil, anchors: [], experimentalSpaces: false)
        let task = Task { [read, weak self] () -> DesktopSnapshot? in
            guard let result = try? await read(request), let self, !Task.isCancelled,
                  expected == self.epoch, self.sessionAvailable(),
                  result.sessionID == request.session, result.revision == request.revision, result.isStructurallyValid,
                  result.nativeIsFresh(now: .now, uptime: ProcessInfo.processInfo.systemUptime) else { return nil }
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
