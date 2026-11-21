import AppKit
import QuartzCore
import Testing
@testable import NearpaneUI

/// A disposable WindowServer session can exercise ordering and key delivery
/// without AX or screen-recording permission. The installed Host has a separate
/// end-to-end witness for input and displayed pixels.
@MainActor struct HostedWindowSwitchTests {
    nonisolated private static let hosted: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["NEARPANE_HOSTED_SWITCH"] == "1" && env["GITHUB_ACTIONS"] == "true" &&
            env["RUNNER_ENVIRONMENT"] == "github-hosted" && env["RUNNER_OS"] == "macOS"
    }()

    private func stack(_ candidates: [NSWindow]) -> [Int] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] ?? []
        let numbers = Set(candidates.map(\.windowNumber))
        return windows.compactMap { row in
            guard row[kCGWindowOwnerPID as String] as? Int32 == getpid(),
                  let n = row[kCGWindowNumber as String] as? Int, numbers.contains(n) else { return nil }
            return n
        }
    }

    private func observe(_ check: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            if check() { return true }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        return check()
    }

    private func fixture(_ frame: CGRect, _ color: NSColor) -> (NSWindow, NSTextView) {
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.backgroundColor = color
        let editor = NSTextView(frame: CGRect(x: 8, y: 8, width: 80, height: 26))
        editor.isRichText = false
        window.contentView?.addSubview(editor)
        return (window, editor)
    }

    @Test(.enabled(if: Self.hosted)) func keyDeliveryAndRealWindowOrderDuringDissolve() async throws {
        let file = try #require(ProcessInfo.processInfo.environment["NEARPANE_HOSTED_SWITCH_RECEIPT"])
        var receipt: [String: Any] = [
            "scope": "isolated hosted AppKit process, production WindowSwitchCover and real WindowServer",
            "status": "BLOCKED", "presentedPixels": "NOT_RUN", "installedHost": "NOT_RUN",
            "eventSource": "NSApplication.sendEvent to actual key window", "physicalInputs": 0
        ]
        func save(_ reason: String) throws {
            receipt["reason"] = reason
            let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            try bytes.write(to: URL(fileURLWithPath: file), options: .withoutOverwriting)
        }
        let app = NSApplication.shared
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true, let screen = NSScreen.main else {
            try save("noUnlockedHostedConsole"); return
        }
        guard app.setActivationPolicy(.regular) else { try save("fixtureActivationPolicyUnavailable"); return }
        app.finishLaunching()
        app.activate()
        let frame = CGRect(x: screen.visibleFrame.midX - 100, y: screen.visibleFrame.midY - 60, width: 200, height: 120)
        let (source, oldEditor) = fixture(frame, .red)
        let (target, editor) = fixture(frame, .blue)
        defer { source.close(); target.close() }
        target.orderFront(nil)
        source.makeKeyAndOrderFront(nil)
        let original = try await observe {
            app.isActive && app.keyWindow === source && stack([source, target]) == [source.windowNumber, target.windowNumber]
        }
        receipt["sourceKeyAndFront"] = original
        guard original else { try save("fixtureCouldNotOwnHostedForeground"); return }
        let bitmap = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let panel = WindowSwitchCover(frame: frame, image: try #require(bitmap.makeImage()))
        defer { panel.discard() }
        let fixtures = [source, target, panel]
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        CATransaction.flush()
        let covered = try await observe { stack(fixtures) == [panel.windowNumber, source.windowNumber, target.windowNumber] }
        let keptSource = app.keyWindow === source
        receipt["coverAboveSourceAndTarget"] = covered
        receipt["sourceKeptKeyWithCoverVisible"] = keptSource
        target.makeKeyAndOrderFront(nil)
        let different = try await observe {
            app.keyWindow === target && stack(fixtures) == [panel.windowNumber, target.windowNumber, source.windowNumber]
        }
        receipt["targetKeyUnderCover"] = different
        var delivered = false
        if different, target.makeFirstResponder(editor), let key = app.keyWindow,
           let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: key.windowNumber, context: nil,
                characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40) {
            panel.reveal()
            CATransaction.flush()
            let start = ContinuousClock.now
            app.sendEvent(event)
            let elapsed = ContinuousClock.now - start
            delivered = editor.string == "k" && oldEditor.string.isEmpty && app.keyWindow === target && panel.isVisible
            receipt["eventDispatchMilliseconds"] = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        }
        receipt["markerExclusivelyInTargetWhilePanelVisible"] = delivered
        try await Task.sleep(for: .seconds(WindowSwitchCover.duration))
        panel.orderOut(nil)
        let uncovered = try await observe {
            app.keyWindow === target && stack(fixtures) == [target.windowNumber, source.windowNumber]
        }
        receipt["targetRemainedKeyAndFrontAfterRemoval"] = uncovered
        let ok = covered && keptSource && different && delivered && uncovered
        receipt["status"] = ok ? "PASS" : "FAIL"
        try save(ok ? "observed" : "orderingOrEditorMismatch")
        #expect(ok)
    }
}
