import AppKit
import NearpaneCore
import WindowLab

@MainActor private final class FullscreenNotifications: NSObject {
    private(set) var entered = 0, exited = 0
    @objc func didEnter(_ notification: Notification) { entered += 1 }
    @objc func didExit(_ notification: Notification) { exited += 1 }
}

extension Trial {
    /// Only the fixture's own public AppKit action is used. No global shortcut, activation
    /// request or Space writer participates. Private scope metadata is read by the frozen helper.
    func fullscreenRoundTrip() throws {
        try requireFullscreenTime(45)
        let (screen, display) = try screen()
        guard let window = windows["A"], windows.count == 1, let origin = baseline["A"],
              let focused = focus["A"], origin.frontPID == birth.pid else { throw Refusal("source enrollment absent") }
        func focusedFixture() throws {
            try checkConsentExpiry()
            try ownedAX("A")
            let (pid, ax) = try focusedWindow()
            try require(pid == birth.pid && CFEqual(focused, ax) && window.isKeyWindow && window.isMainWindow &&
                        window.isOnActiveSpace && window.isVisible && !window.isMiniaturized &&
                        UInt32(exactly: window.windowNumber) == origin.number &&
                        window.screen == screen && window.collectionBehavior.contains(.fullScreenPrimary),
                        "enrolled foreground window changed")
        }
        let source = try consoleEndpoint("A", display: display)
        let ordinary = try TrialDisplayState(source)
        func protectedDisplayMatches(_ snapshot: DesktopSnapshot) -> Bool {
            snapshot.displays.filter { $0.id != display } == source.displays.filter { $0.id != display } &&
            snapshot.scopes.filter { $0.displayID != display } == source.scopes.filter { $0.displayID != display }
        }
        let notices = FullscreenNotifications(), center = NotificationCenter.default
        center.addObserver(notices, selector: #selector(FullscreenNotifications.didEnter(_:)),
                           name: NSWindow.didEnterFullScreenNotification, object: window)
        center.addObserver(notices, selector: #selector(FullscreenNotifications.didExit(_:)),
                           name: NSWindow.didExitFullScreenNotification, object: window)
        defer { center.removeObserver(notices) }
        var enrolledFullscreen: (TrialDisplayState, SurfaceRect)?

        func toggle(enter: Bool) throws {
            try requireFullscreenTime(enter ? 35 : 14)
            if enter {
                let current = try consoleEndpoint("A", display: display)
                try require(try TrialDisplayState(current) == ordinary, "ordinary origin changed before entry")
            } else {
                guard let enrolledFullscreen, try readFullscreen() == enrolledFullscreen else {
                    throw Refusal("fullscreen target changed before return")
                }
            }
            try focusedFixture()
            let name = enter ? "enter" : "exit"
            guard window.styleMask.contains(.fullScreen) != enter, notices.exited == 0,
                  notices.entered == (enter ? 0 : 1) else { throw Refusal("unexpected AppKit phase") }
            // Persist the intended input before issuing it. An incomplete run must never be replayed.
            try writeJSON(["run": run.uuidString, "number": String(origin.number), "pid": String(birth.pid),
                           "launch": String(birth.start), "action": name], dir, "fullscreen-" + name + "-intent.json")
            try focusedFixture()
            window.toggleFullScreen(nil)
            let end = ProcessInfo.processInfo.systemUptime + 8
            var checkAt = ProcessInfo.processInfo.systemUptime + 0.25
            repeat {
                try checkConsentExpiry()
                let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
                try require(foreground == birth.pid && window.screen == screen, "fullscreen escaped its foreground display")
                if ProcessInfo.processInfo.systemUptime >= checkAt {
                    try require(try protectedDisplayMatches(consoleScopes()), "protected primary changed during transition")
                    checkAt = ProcessInfo.processInfo.systemUptime + 0.25
                }
                if enter ? notices.entered == 1 : notices.exited == 1 { break }
                pump()
            } while ProcessInfo.processInfo.systemUptime < end
            try require(notices.entered == 1 && notices.exited == (enter ? 0 : 1) &&
                        window.styleMask.contains(.fullScreen) == enter, "native transition completion not observed")
            try focusedFixture()
        }

        func readFullscreen() throws -> (TrialDisplayState, SurfaceRect) {
            try scope()
            try focusedFixture()
            let frame = SurfaceRect(x: window.frame.minX, y: CGDisplayBounds(CGMainDisplayID()).height - window.frame.maxY,
                                    width: window.frame.width, height: window.frame.height)
            revision += 1
            let request = DesktopReadRequest(session: run, revision: revision, parentPID: birth.pid,
                fixtureWindows: [origin.number], anchors: [.init(number: origin.number, displayID: display, globalFrame: frame)],
                experimentalSpaces: true)
            let file = dir.appendingPathComponent("fullscreen-snapshot-\(revision).json")
            try helper(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NearpaneDesktopReader"),
                       [enrolledRead, try JSONEncoder().encode(request).base64EncodedString()], output: file)
            let snap = try JSONDecoder().decode(DesktopSnapshot.self, from: Data(contentsOf: file))
            let state = try TrialDisplayState(snap)
            guard snap.isStructurallyValid, snap.sessionID == run, snap.revision == revision,
                  snap.native?.population == .markedFixture, snap.native?.spaces == .observed,
                  let originalScreen = source.displays.first(where: { $0.id == display }),
                  let currentScreen = snap.displays.first(where: { $0.id == display }),
                  currentScreen.frame == originalScreen.frame, currentScreen.rotationDegrees == originalScreen.rotationDegrees,
                  currentScreen.backingScale == originalScreen.backingScale,
                  protectedDisplayMatches(snap),
                  case let .native(id) = snap.fullscreenObservation(for: display, now: Date(), uptime: ProcessInfo.processInfo.systemUptime),
                  id.pid == birth.pid, id.launch == birth.start, id.number == origin.number, snap.windows.count == 1,
                  let observed = snap.windows.first, observed.metadata?.globalFrame == frame,
                  case let .known(records) = observed.membership, records.count == 1, let member = records.first,
                  ordinary.permitsFullscreen(state, secondary: display, member: member)
            else { throw Refusal("fullscreen membership, AX/CG geometry or protected display not confirmed") }
            try focusedFixture()
            return (state, frame)
        }
        _ = try stable("A", "fullscreen-before")
        try toggle(enter: true)
        let first = try readFullscreen()
        let until = ProcessInfo.processInfo.systemUptime + 0.25
        while ProcessInfo.processInfo.systemUptime < until { pump() }
        let second = try readFullscreen()
        try require(first == second, "fullscreen frames or scopes changed between reads")
        enrolledFullscreen = second
        try writeJSON(["run": run.uuidString, "source": origin.record, "fullscreenCurrent": second.0.currents[display],
                       "focusAndBothDisplays": "verified", "revision": String(revision)], dir, "fullscreen-enter-confirmed.json")
        if observeTools, let current = second.0.currents[display] {
            try holdForTools(origin: origin, display: display, fullscreen: current) {
                try require(try readFullscreen() == second, "fullscreen window, focus, geometry or display state changed during Host observation")
            }
        }
        try toggle(enter: false)
        let returned = try stable("A", "fullscreen-returned")
        try require(returned == origin && notices.entered == 1 && notices.exited == 1,
                    "original window, focus, ordinary frame or both display currents did not return")
        try writeJSON(["run": run.uuidString, "source": origin.record, "returned": returned.record,
                       "systemInputs": "2", "revision": String(revision)], dir, "fullscreen-exit-confirmed.json")
        if observeTools {
            let end = min(authorizedUntil - 3, ProcessInfo.processInfo.systemUptime + 2)
            while ProcessInfo.processInfo.systemUptime < end {
                try focusedFixture()
                pump()
            }
        }
    }
}
