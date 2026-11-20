import AppKit
import CryptoKit

// Disposable ordinary document fixture. No product linkage, action API or focus shim.
let app = NSApplication.shared
guard CommandLine.arguments.count == 3, let expected = Int(CommandLine.arguments[2]), (1...2).contains(expected) else { exit(2) }
let run = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
var processInfo = proc_bsdinfo()
let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &processInfo, infoSize) == infoSize, processInfo.pbi_start_tvsec > 0 else { exit(3) }
let birth = processInfo.pbi_start_tvsec * 1_000_000 + processInfo.pbi_start_tvusec
let session = run.lastPathComponent
guard UUID(uuidString: session) != nil else { exit(2) }
let policy = app.activationPolicy()
if policy != .regular { _ = app.setActivationPolicy(.regular) }
let startup: [String: Any] = ["bundle": Bundle.main.bundleIdentifier ?? "", "displayCount": NSScreen.screens.count,
                              "policy": app.activationPolicy().rawValue]
try JSONSerialization.data(withJSONObject: startup).write(to: run.appendingPathComponent("startup.json"), options: .atomic)
guard ["net.example.spaces-document", "net.example.spaces-route-witness"].contains(Bundle.main.bundleIdentifier ?? ""),
      app.activationPolicy() == .regular, NSScreen.screens.count == 1, let screen = NSScreen.screens.first else { exit(3) }
var windows = [NSWindow]()
var editors = [NSTextView]()
var lastState = Data()
var withdrew = false, minimized = false
NSWindow.allowsAutomaticWindowTabbing = false
let presentation = ProcessInfo.processInfo.environment["NP_FIXTURE_PRESENTATION"]
final class SharedFixtureWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
@MainActor func addDocument(_ i: Int) {
        let frame = screen.visibleFrame
        let roster = presentation == "roster" || presentation == "public-visible"
        let size: CGSize = roster ? (i == 0 ? CGSize(width: 540, height: 180) : CGSize(width: 240, height: 350)) : CGSize(width: 320, height: 160)
        let rect = NSRect(x: frame.midX - 180 + Double(30*i), y: frame.midY - 90 + Double(25*i), width: size.width, height: size.height)
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let w: NSWindow
        if presentation == "public-visible" {
            let panel = SharedFixtureWindow(contentRect: rect, styleMask: style.union(.nonactivatingPanel), backing: .buffered, defer: false)
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
            panel.level = .normal
            w = panel
        } else {
            w = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        }
        w.title = i == 0 ? "Field Notes – A" : "Field Notes – B"
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        let editor = NSTextView(frame: w.contentView!.bounds)
        if roster { editor.backgroundColor = i == 0 ? NSColor.systemGreen : NSColor.systemPurple }
        editor.autoresizingMask = [.width,.height]
        editor.font = .systemFont(ofSize: 16)
        w.contentView = editor
        w.initialFirstResponder = editor
        _ = w.makeFirstResponder(editor)
        windows.append(w); editors.append(editor)
        if presentation == "contract" || presentation == "contract-split" {
            w.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps:true)
        } else { w.orderFrontRegardless() }
}
DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
    for i in 0..<(presentation == "contract-split" ? 1 : expected) { addDocument(i) }
}
let start = ProcessInfo.processInfo.systemUptime
let timer = Timer(timeInterval: 0.045, repeats: true) { _ in
    if FileManager.default.fileExists(atPath: run.appendingPathComponent("close").path) ||
       ProcessInfo.processInfo.systemUptime - start > (presentation?.hasPrefix("contract") == true ? 900 : 150) {
        for w in windows { w.orderOut(nil); w.close() }
        app.terminate(nil); return
    }
    if presentation == "contract-split", windows.count==1, expected==2,
       FileManager.default.fileExists(atPath:run.appendingPathComponent("open-second").path) { MainActor.assumeIsolated { addDocument(1) } }
    guard !windows.isEmpty else { return }
    if presentation == "contract", windows.count == 2, windows.filter({ !$0.isVisible }).count == 1 {
        let recreate = run.appendingPathComponent("recreate-closed")
        if (try? FileManager.default.removeItem(at:recreate)) != nil {
            MainActor.assumeIsolated { addDocument(2) }
        }
    }
    if presentation?.hasPrefix("contract") == true {
        let activation = run.appendingPathComponent("activate-first")
        if (try? FileManager.default.removeItem(at:activation)) != nil {
            app.activate(ignoringOtherApps:true)
            windows[0].makeKeyAndOrderFront(nil)
        }
    }
    if presentation == "roster", windows.count == 2 {
        if !withdrew, FileManager.default.fileExists(atPath: run.appendingPathComponent("withdraw-first").path) {
            withdrew = true
            windows[0].orderOut(nil)
        }
        if !minimized, FileManager.default.fileExists(atPath: run.appendingPathComponent("minimize-second").path) {
            minimized = true
            windows[1].miniaturize(nil)
        }
    }
    let payload: [String: Any] = [
        "session": session, "pid": getpid(), "birth": birth, "numbers": windows.map { $0.windowNumber },
        "presentation": presentation ?? "ordinary", "bundle": Bundle.main.bundleIdentifier ?? "",
        "visible": windows.map(\.isVisible), "minimized": windows.map(\.isMiniaturized),
        "sizes": windows.map { [$0.frame.width, $0.frame.height] },
        "key": app.keyWindow?.windowNumber ?? 0, "main": app.mainWindow?.windowNumber ?? 0,
        "editorsFocused": zip(windows, editors).map { $0.firstResponder === $1 },
        "sha256": editors.map { SHA256.hash(data: Data($0.string.utf8)).map { String(format: "%02x", $0) }.joined() }
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys), data != lastState {
        try? data.write(to: run.appendingPathComponent("windows.json"), options: .atomic); lastState = data
    }
}
RunLoop.main.add(timer, forMode: .common)
app.run()
