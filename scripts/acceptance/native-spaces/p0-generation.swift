import AppKit

// Each actual NSWindow receives an immutable identity inside its own disposable signed app.
// Keep reading the existing fixture's strong window array even when WindowServer switches Spaces.
@MainActor func installP0Generations(folder: URL, birth: UInt64, windows: @escaping @MainActor () -> [NSWindow]) {
    guard folder.path.hasPrefix("/private/tmp/nearpane-p0-owned-"),UUID(uuidString:folder.lastPathComponent) != nil,
          ProcessInfo.processInfo.environment["NP_FIXTURE_PRESENTATION"]=="contract" else {return}
    let generations=NSMapTable<NSWindow,NSString>.weakToStrongObjects()
    let activity=ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,reason:"Read controlled document generation during an installed acceptance run")
    let timer=Timer(timeInterval:0.22,repeats:true) { _ in MainActor.assumeIsolated {
        _=activity
        let rows:[[String:Any]]=windows().map { window in
            let generation=generations.object(forKey:window) ?? UUID().uuidString as NSString
            generations.setObject(generation,forKey:window)
            return ["number":window.windowNumber,"generation":generation,"visible":window.isVisible,
                    "minimized":window.isMiniaturized,"fullscreen":window.styleMask.contains(.fullScreen)]
        }
        let record:[String:Any]=["session":folder.lastPathComponent,"pid":getpid(),"birth":birth,"uptime":ProcessInfo.processInfo.systemUptime,"windows":rows]
        if let data=try? JSONSerialization.data(withJSONObject:record,options:.sortedKeys) {
            try? data.write(to:folder.appendingPathComponent("p0-generations.json"),options:.atomic)
        }
    }}
    RunLoop.main.add(timer,forMode:.common)
}
