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
guard Bundle.main.bundleIdentifier == "net.example.spaces-document",
      app.activationPolicy() == .regular, NSScreen.screens.count == 1, let screen = NSScreen.screens.first else { exit(3) }
var windows = [NSWindow]()
var editors = [NSTextView]()
var lastState = Data()
NSWindow.allowsAutomaticWindowTabbing = false
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    for i in 0..<expected {
        let frame = screen.visibleFrame
        let w = NSWindow(contentRect: NSRect(x: frame.midX - 180 + Double(30*i), y: frame.midY - 90 + Double(25*i),
                                             width: 320, height: 160),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = i == 0 ? "Field Notes – A" : "Field Notes – B"
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        let editor = NSTextView(frame: w.contentView!.bounds)
        editor.autoresizingMask = [.width,.height]
        editor.font = .systemFont(ofSize: 16)
        w.contentView = editor
        w.initialFirstResponder = editor
        _ = w.makeFirstResponder(editor)
        windows.append(w); editors.append(editor)
        w.orderFrontRegardless()
    }
}
let start = ProcessInfo.processInfo.systemUptime
let timer = Timer(timeInterval: 0.045, repeats: true) { _ in
    if FileManager.default.fileExists(atPath: run.appendingPathComponent("close").path) ||
       ProcessInfo.processInfo.systemUptime - start > 150 {
        for w in windows { w.orderOut(nil); w.close() }
        app.terminate(nil); return
    }
    guard windows.count == expected else { return }
    let payload: [String: Any] = [
        "session": session, "pid": getpid(), "birth": birth, "numbers": windows.map { $0.windowNumber },
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
