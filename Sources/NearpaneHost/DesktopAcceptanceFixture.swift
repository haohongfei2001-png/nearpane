#if canImport(SaytileKit)
import AppKit
import NearpaneCore

private final class PassiveWorkWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Exists only for the explicit secondary-display acceptance command. Every exported row is an owned fixture window.
@MainActor final class DesktopAcceptanceFixture {
    private(set) var windows: [NSWindow] = []
    private let directory: URL
    private let run: String
    private let displayID: String
    private var timer: Timer?
    private var saved = Set<UInt64>()
    private var optInScheduled = false

    init(session: NativeAcceptanceSession, displayID: String) throws {
        guard let run = ProcessInfo.processInfo.environment["NEARPANE_ACCEPTANCE_RUN"],
              UUID(uuidString: run)?.uuidString.lowercased() == run else { throw CocoaError(.validationMissingMandatoryProperty) }
        self.run = run; directory = session.directory; self.displayID = displayID
        guard let screen = approvedScreen else { throw CocoaError(.featureUnsupported) }
        let safe = screen.visibleFrame
        let specs = [(0.08,0.34,0.52,0.28), (0.34,0.46,0.42,0.23)]
        for (index, s) in specs.enumerated() {
            let r = NSRect(x: safe.minX + safe.width*s.0, y: safe.minY + safe.height*s.1,
                           width: safe.width*s.2, height: safe.height*s.3).integral
            let w = PassiveWorkWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            w.title = "Nearpane geometry fixture " + String(index + 1)
            w.isReleasedWhenClosed = false; w.isMovable = false; w.hasShadow = false; w.ignoresMouseEvents = true
            w.backgroundColor = index == 0 ? .systemTeal : .systemOrange
            w.collectionBehavior = [.managed, .ignoresCycle]
            w.setFrame(r, display: false)
            guard NSContainsRect(safe, w.frame) else { throw CocoaError(.featureUnsupported) }
            windows.append(w)
        }
        guard approvedScreen != nil else { throw CocoaError(.featureUnsupported) }
        for w in windows { w.orderFrontRegardless() }
    }

    func captureWindow() throws -> UInt32 {
        guard let screen = approvedScreen, let window = windows.first, window.isVisible,
              window.screen === screen, window.isOnActiveSpace, window.isOpaque,
              let number = UInt32(exactly: window.windowNumber), number > 0,
              let row = (CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]])?.first,
              row[kCGWindowOwnerPID as String] as? Int32 == getpid(), row[kCGWindowIsOnscreen as String] as? Bool == true,
              row[kCGWindowNumber as String] as? UInt32 == number,
              let bits = row[kCGWindowBounds as String] as? NSDictionary, let cg = CGRect(dictionaryRepresentation: bits),
              let display = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
              CGDisplayBounds(display.uint32Value).contains(cg), !cg.intersects(CGDisplayBounds(CGMainDisplayID()))
        else { throw CocoaError(.featureUnsupported) }
        return number
    }

    private var approvedScreen: NSScreen? {
        guard NSScreen.screens.count == 2, let primary = NSScreen.screens.first, let screen = NSScreen.screens.last,
              primary.frame.intersection(screen.frame).isEmpty,
              let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              n.uint32Value != CGMainDisplayID(), CGDisplayIsInMirrorSet(n.uint32Value) == 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue(),
              CFUUIDCreateString(nil, uuid) as String == displayID else { return nil }
        return screen
    }

    func observe(_ host: HostSession) {
        host.setExperimentalSpaceObservation(false)
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self, weak host] _ in
            MainActor.assumeIsolated { if let self, let host { self.record(host) } }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    private func record(_ host: HostSession) {
        guard let screen = approvedScreen, windows.allSatisfy({ NSContainsRect(screen.frame,$0.frame) }) else {
            stop(); NSApp.terminate(nil); return
        }
        guard let snapshot = host.bus.desktop, let native = snapshot.native, native.population == .markedFixture,
              saved.insert(snapshot.revision).inserted else { return }
        struct Frame: Encodable { let number: Int; let expectedCG: SurfaceRect; let activeSpace, key: Bool }
        struct Receipt: Encodable { let snapshot: DesktopSnapshot; let fixtures: [Frame]; let hostActive: Bool }
        guard let menu = NSScreen.screens.first else { return }
        // Independent reference in global logical points, derived from the actual owning NSWindow.
        let frames = windows.map { Frame(number: $0.windowNumber, expectedCG: .init(x: $0.frame.minX, y: menu.frame.maxY - $0.frame.maxY,
                              width: $0.frame.width, height: $0.frame.height), activeSpace: $0.isOnActiveSpace, key: $0.isKeyWindow) }
        let out = directory.appendingPathComponent("desktop-" + run + "-" + String(snapshot.revision) + ".json")
        do {
            try JSONEncoder().encode(Receipt(snapshot: snapshot, fixtures: frames, hostActive: NSApp.isActive))
                .write(to: out, options: .withoutOverwriting)
        } catch { stop(); NSApp.terminate(nil); return }
        if !optInScheduled && native.spaces == .disabled && snapshot.freshness == .fresh && snapshot.windows.count == windows.count {
            optInScheduled = true
            // Allow the public-only panel to be captured before the separately authorized read starts.
            Task { [weak self, weak host] in
                try? await Task.sleep(for: .seconds(4))
                guard self?.timer != nil, self?.approvedScreen != nil else { return }
                host?.setExperimentalSpaceObservation(true)
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll()
    }
}
#endif
