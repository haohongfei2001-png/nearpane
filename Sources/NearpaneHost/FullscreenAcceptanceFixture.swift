#if canImport(SaytileKit)
import AppKit
import NearpaneCore

private final class FullscreenBackdrop: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Injects a classification only in an executable-bound, supervised secondary-display session.
/// The actual panel controller and tool actions are the same ones used by the product.
@MainActor final class FullscreenAcceptanceFixture {
    private let directory: URL
    private let run: String
    private let displayID: String
    private let originalFront: pid_t
    private let ownedWindow: @MainActor () throws -> UInt32
    private let identity: ManagedWindowID
    private let refresh: @MainActor () -> Void
    private var timer: Timer?
    private(set) var native = false
    private var sequence = 0
    private var previous: Data?
    private var backdrop: NSWindow?
    private var sampleIndex = 0

    init(session: NativeAcceptanceSession, displayID: String,
         ownedWindow: @escaping @MainActor () throws -> UInt32,
         refresh: @escaping @MainActor () -> Void) throws {
        let env = ProcessInfo.processInfo.environment
        guard env["NEARPANE_FULLSCREEN_ACCEPTANCE"] == session.directory.lastPathComponent,
              Bundle.main.bundleIdentifier == "com.holdsnow.nearpane.candidate.p51",
              let run = env["NEARPANE_ACCEPTANCE_RUN"], UUID(uuidString: run)?.uuidString.lowercased() == run,
              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != getpid() else {
            throw CocoaError(.fileReadNoPermission)
        }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_start_tvsec > 0 else {
            throw CocoaError(.featureUnsupported)
        }
        self.directory = session.directory
        self.run = run
        self.displayID = displayID
        self.ownedWindow = ownedWindow
        self.refresh = refresh
        originalFront = front
        identity = .init(pid: getpid(), launch: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
                         number: try ownedWindow(), element: UUID())
        guard safe else { throw CocoaError(.featureUnsupported) }
        // Provide a uniform opaque surface behind the small glass panel. Limit the
        // backdrop to the area occupied by the strip, tool, and its one 16 pt move.
        guard let screen = NSScreen.screens.last, NSScreen.screens.count == 2,
              let n = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
              let u = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue(),
              CFUUIDCreateString(nil,u) as String == displayID, n.uint32Value != CGMainDisplayID(),
              screen.visibleFrame.width >= 300, screen.visibleFrame.height >= 100 else { throw CocoaError(.featureUnsupported) }
        let r = NSRect(x: screen.visibleFrame.maxX - 300, y: screen.visibleFrame.maxY - 100, width: 300, height: 100)
        let bg = FullscreenBackdrop(contentRect: r, styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: true)
        bg.isReleasedWhenClosed = false
        bg.hasShadow = false
        bg.isOpaque = true
        bg.ignoresMouseEvents = true
        bg.hidesOnDeactivate = false
        bg.backgroundColor = .init(srgbRed: 0.23, green: 0.40, blue: 0.45, alpha: 1)
        bg.level = .floating
        bg.collectionBehavior = [.managed,.ignoresCycle]
        bg.setFrame(r, display: false)
        guard bg.frame == r else { throw CocoaError(.featureUnsupported) }
        bg.orderFrontRegardless()
        backdrop = bg
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var witness: ManagedWindowID? {
        guard safe else { return nil }
        return identity
    }

    var safe: Bool {
        let state = CGSessionCopyCurrentDictionary() as? [String: Any]
        return state?["kCGSSessionOnConsoleKey"] as? Bool == true
            && state?["CGSSessionScreenIsLocked"] as? Bool != true
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFront
            && !NSApp.isActive && NSApp.keyWindow == nil && NSApp.mainWindow == nil
            && (try? ownedWindow()) == identity.number
    }

    private func tick() {
        guard safe else { stop(); NSApp.terminate(nil); return }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("fullscreen-finish-" + run).path) {
            stop()
            NSApp.terminate(nil)
            return
        }
        // The two commands are single-use, per-launch flags. Neither carries a PID, Space ID or target.
        let next = sequence + 1
        let file = directory.appendingPathComponent("fullscreen-step-\(run)-\(next)")
        if FileManager.default.fileExists(atPath: file.path) {
            guard next <= 6, file.resolvingSymlinksInPath().path == file.path,
                  let command = try? String(contentsOf: file, encoding: .utf8),
                  command == (native ? "ordinary" : "native") else { stop(); NSApp.terminate(nil); return }
            sequence = next
            native.toggle()
            refresh()
        }
        let tools = NSApp.windows.filter { $0.identifier?.rawValue == "np.fullscreen.panel" && $0.isVisible }
        guard tools.count <= 1 else { stop(); NSApp.terminate(nil); return }
        var row: [String: Any] = ["source":"synthetic native classification; actual AppKit windows",
                                  "pid":getpid(),"step":sequence,"native":native,"frontPID":originalFront,
                                  "key":NSApp.keyWindow != nil,"main":NSApp.mainWindow != nil,"active":NSApp.isActive,
                                  "display":displayID,"tool":0]
        if let w = tools.first {
            guard let n = w.screen?.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
                  let id = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue(),
                  CFUUIDCreateString(nil,id) as String == displayID, n.uint32Value != CGMainDisplayID(),
                  w.screen?.frame.contains(w.frame) == true, backdrop?.isVisible == true,
                  backdrop?.frame.contains(w.frame) == true else { stop(); NSApp.terminate(nil); return }
            row["tool"] = w.windowNumber
            row["frame"] = [w.frame.minX,w.frame.minY,w.frame.width,w.frame.height]
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("fullscreen-render-" + run).path) {
                do { try captureOwnView(w) } catch { stop(); NSApp.terminate(nil); return }
            }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
            if previous != data {
                try data.write(to: directory.appendingPathComponent("fullscreen-\(run).json"), options: .atomic)
                previous = data
            }
        } catch { stop(); NSApp.terminate(nil) }
    }

    /// Capture the content of the actually presented test window even when macOS protects
    /// it from window capture. No other window, system compositor, desktop, or audio is read.
    private func captureOwnView(_ panel: NSWindow) throws {
        guard sampleIndex < 640, let view = panel.contentView, view.window === panel,
              view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.featureUnsupported) }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        let frameName = String(format:"tool-frame-%@-%04d", run, sampleIndex)
        sampleIndex += 1
        try data.write(to: directory.appendingPathComponent(frameName + ".png"), options: .withoutOverwriting)
        let meta: [String:Any] = ["uptime":ProcessInfo.processInfo.systemUptime, "id":panel.windowNumber,
            "x":panel.frame.minX,"y":panel.frame.minY,"width":panel.frame.width,"height":panel.frame.height,
            "source":"AppKit content-view cache of displayed test window; excludes compositor backdrop"]
        try JSONSerialization.data(withJSONObject: meta).write(to: directory.appendingPathComponent(frameName + ".json"),options:.atomic)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        backdrop?.orderOut(nil); backdrop?.close(); backdrop = nil
    }
}
#endif
