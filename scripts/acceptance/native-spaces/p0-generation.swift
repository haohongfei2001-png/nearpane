import AppKit

@MainActor private final class P0FixtureObserver {
    private let folder:URL, birth:UInt64, windows:@MainActor ()->[NSWindow], color:NSColor
    private let generations=NSMapTable<NSWindow,NSString>.weakToStrongObjects()
    private let activity=ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,
        reason:"Expose the live identity of an owned document during the installed application test")

    init?(folder:URL,birth:UInt64,windows:@escaping @MainActor ()->[NSWindow]) {
        guard folder.path.hasPrefix("/private/tmp/nearpane-p0-owned-"),UUID(uuidString:folder.lastPathComponent) != nil,
              ProcessInfo.processInfo.environment["NP_FIXTURE_PRESENTATION"]=="contract" else {return nil}
        switch Bundle.main.bundleIdentifier {
        case "net.example.spaces-document":color=NSColor(srgbRed:0.10,green:0.54,blue:0.85,alpha:1)
        case "net.example.spaces-route-witness":color=NSColor(srgbRed:0.98,green:0.49,blue:0.12,alpha:1)
        default:return nil
        }
        self.folder=folder;self.birth=birth;self.windows=windows
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
                }
            }
            return ["number":window.windowNumber,"generation":generation,"visible":window.isVisible,
                    "minimized":window.isMiniaturized,"fullscreen":window.styleMask.contains(.fullScreen)]
        }
        let record:[String:Any]=["session":folder.lastPathComponent,"pid":getpid(),"birth":birth,"uptime":ProcessInfo.processInfo.systemUptime,"windows":rows]
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
