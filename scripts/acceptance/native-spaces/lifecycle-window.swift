import AppKit

// A disposable document application. Its controls change only its own two windows.
let app = NSApplication.shared
guard CommandLine.arguments.count == 2,
      Bundle.main.bundleIdentifier == "org.nearpane.acceptance.LifecycleWindow" else { exit(2) }
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard UUID(uuidString: folder.lastPathComponent) != nil else { exit(2) }
app.setActivationPolicy(.regular)
NSWindow.allowsAutomaticWindowTabbing = false
let mainMenu = NSMenu()
let application = NSMenuItem()
let appMenu = NSMenu(); application.submenu = appMenu
appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
mainMenu.addItem(application)
let windowsItem = NSMenuItem()
let windowMenu = NSMenu(title: "Window"); windowsItem.submenu = windowMenu
windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
mainMenu.addItem(windowsItem); app.mainMenu = mainMenu; app.windowsMenu = windowMenu

var windows = [NSWindow]()
var captions = [NSTextField]()
var lastCommand = ""
var lastState = Data()
let start = ProcessInfo.processInfo.systemUptime
DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) {
    guard let screen = NSScreen.main else { app.terminate(nil); return }
    for index in 0..<2 {
        let rect = NSRect(x: screen.visibleFrame.midX - 330 + CGFloat(index * 180),
                          y: screen.visibleFrame.midY - 146 + CGFloat(index * 64), width: 540, height: 300)
        let w = NSWindow(contentRect: rect, styleMask: [.titled,.closable,.resizable,.miniaturizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.tabbingMode = .disallowed
        w.collectionBehavior = [.fullScreenPrimary,.fullScreenAllowsTiling]
        w.title = index == 0 ? "Nearpane Test Document A" : "Nearpane Test Document B"
        w.backgroundColor = index == 0 ? .systemTeal : .systemIndigo
        let label = NSTextField(wrappingLabelWithString: w.title)
        label.font = .systemFont(ofSize: 28, weight: .medium)
        label.textColor = .white
        label.frame = NSRect(x: 30, y: 75, width: 480, height: 110)
        w.contentView?.addSubview(label)
        windows.append(w); captions.append(label)
        w.orderFrontRegardless()
    }
}
let timer = Timer(timeInterval: 0.08, repeats: true) { _ in
    guard windows.count == 2 else { return }
    if FileManager.default.fileExists(atPath: folder.appendingPathComponent("close").path)
        || ProcessInfo.processInfo.systemUptime - start > 360 {
        windows.forEach { $0.close() }; app.terminate(nil); return
    }
    if let data = try? Data(contentsOf: folder.appendingPathComponent("request.json")),
       let r = try? JSONSerialization.jsonObject(with: data) as? [String:Any],
       let nonce = r["nonce"] as? String, UUID(uuidString: nonce) != nil, nonce != lastCommand,
       let action = r["action"] as? String, let index = r["index"] as? Int, windows.indices.contains(index) {
        lastCommand = nonce
        let w = windows[index]
        switch action {
        case "activate":
            app.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
        case "fullscreen" where !w.styleMask.contains(.fullScreen),
             "ordinary" where w.styleMask.contains(.fullScreen):
            w.toggleFullScreen(nil)
        case "zoom" where !w.isZoomed, "unzoom" where w.isZoomed:
            w.performZoom(nil)
        default: break
        }
    }
    for (i, w) in windows.enumerated() {
        captions[i].stringValue = "\(w.title)\n\(w.styleMask.contains(.fullScreen) ? "Full screen" : "Ordinary window")  ·  \(Int(ProcessInfo.processInfo.systemUptime - start)) s"
    }
    let state: [String:Any] = ["session": folder.lastPathComponent, "pid": getpid(), "lastCommand": lastCommand,
        "numbers": windows.map(\.windowNumber), "fullscreen": windows.map { $0.styleMask.contains(.fullScreen) },
        "zoomed": windows.map(\.isZoomed), "key": app.keyWindow?.windowNumber ?? 0,
        "frames": windows.map { [$0.frame.minX,$0.frame.minY,$0.frame.width,$0.frame.height] }]
    if let data = try? JSONSerialization.data(withJSONObject: state, options: .sortedKeys), lastState != data {
        try? data.write(to: folder.appendingPathComponent("windows.json"), options: .atomic); lastState = data
    }
}
RunLoop.main.add(timer, forMode: .common)
app.run()
