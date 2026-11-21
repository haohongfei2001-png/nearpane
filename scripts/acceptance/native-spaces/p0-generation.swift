import AppKit
import QuartzCore

enum P0MarkerPaper: String, CaseIterable {
    case field = "net.example.spaces-document"
    case route = "net.example.spaces-route-witness"

    var base: NSColor {
        switch self {
        case .field: return NSColor(srgbRed: 0.10, green: 0.54, blue: 0.85, alpha: 1)
        case .route: return NSColor(srgbRed: 0.98, green: 0.49, blue: 0.12, alpha: 1)
        }
    }

    func alternatingColors(flag: String?, documentCount: String?) -> [NSColor] {
        guard flag == "1", documentCount == "1" else { return [] }
        let paper = base
        return [-8, 8].map { offset in
            NSColor(srgbRed: paper.redComponent, green: paper.greenComponent + CGFloat(offset) / 255,
                    blue: paper.blueComponent, alpha: 1)
        }
    }
}

@MainActor private final class P0FixtureObserver: NSObject {
    private let folder:URL, birth:UInt64, windows:@MainActor ()->[NSWindow], color:NSColor
    private let markerColors: [NSColor]
    private weak var markerEditor: NSTextView?
    private var cancelMarker: (() -> Void)?
    private var markerCallbacks = 0
    private let generations=NSMapTable<NSWindow,NSString>.weakToStrongObjects()
    private let activity=ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,
        reason:"Expose the live identity of an owned document during the installed application test")

    init?(folder:URL,birth:UInt64,windows:@escaping @MainActor ()->[NSWindow]) {
        guard folder.path.hasPrefix("/private/tmp/nearpane-p0-owned-"),UUID(uuidString:folder.lastPathComponent) != nil,
              ProcessInfo.processInfo.environment["NP_FIXTURE_PRESENTATION"]=="contract" else {return nil}
        guard let paper = P0MarkerPaper(rawValue: Bundle.main.bundleIdentifier ?? "") else { return nil }
        color = paper.base
        markerColors = paper.alternatingColors(flag: ProcessInfo.processInfo.environment["NP_P0_DYNAMIC_MARKER"],
                                               documentCount: CommandLine.arguments.last)
        self.folder=folder;self.birth=birth;self.windows=windows
    }

    @available(macOS 14.0, *)
    private func startMarker(in editor: NSTextView, window: NSWindow) {
        guard !markerColors.isEmpty, markerEditor == nil, window.contentView === editor else { return }
        markerEditor = editor
        let link = editor.displayLink(target: self, selector: #selector(displayFrame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        cancelMarker = { [weak link] in link?.invalidate() }
        NotificationCenter.default.addObserver(self, selector: #selector(closingMarker(_:)),
                                               name: NSWindow.willCloseNotification, object: window)
        link.add(to: .main, forMode: .common)
    }

    @available(macOS 14.0, *)
    @objc private func displayFrame(_ link: CADisplayLink) {
        guard let editor = markerEditor, editor.window?.contentView === editor else {
            stopMarker()
            return
        }
        editor.backgroundColor = markerColors[markerCallbacks % markerColors.count]
        editor.needsDisplay = true
        markerCallbacks += 1
    }

    @objc private func closingMarker(_ notification: Notification) { stopMarker() }

    private func stopMarker() {
        cancelMarker?()
        cancelMarker = nil
        markerEditor = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
    }

    func publish() {
        let rows:[[String:Any]]=windows().map { window in
            let generation:NSString
            if let retained=generations.object(forKey:window) {
                generation=retained
            } else {
                generation=UUID().uuidString as NSString
                generations.setObject(generation,forKey:window)
                // Only these synthetic documents acquire colored paper, before independent display calibration.
                if let editor=window.contentView as? NSTextView {
                    editor.drawsBackground=true
                    editor.backgroundColor=color
                    editor.needsDisplay=true
                    if #available(macOS 14.0, *) { startMarker(in: editor, window: window) }
                }
            }
            return ["number":window.windowNumber,"generation":generation,"visible":window.isVisible,
                    "minimized":window.isMiniaturized,"fullscreen":window.styleMask.contains(.fullScreen)]
        }
        var record:[String:Any]=["session":folder.lastPathComponent,"pid":getpid(),"birth":birth,"uptime":ProcessInfo.processInfo.systemUptime,"windows":rows]
        if !markerColors.isEmpty {
            record["markerDisplayLink"] = ["active": markerEditor != nil, "callbacks": markerCallbacks]
        }
        if let data=try? JSONSerialization.data(withJSONObject:record,options:.sortedKeys) {
            try? data.write(to:folder.appendingPathComponent("p0-generations.json"),options:.atomic)
        }
    }
}

@MainActor func installP0Generations(folder:URL,birth:UInt64,windows:@escaping @MainActor ()->[NSWindow]) {
    guard let observer=P0FixtureObserver(folder:folder,birth:birth,windows:windows) else {return}
    let timer=Timer(timeInterval:0.22,repeats:true) { _ in MainActor.assumeIsolated {observer.publish()} }
    RunLoop.main.add(timer,forMode:.common)
}
