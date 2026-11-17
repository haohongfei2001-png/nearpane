// Compile once as a disposable, regular two-window app, once as its isolated controller.
// Only the test app publishes its numbers. The controller calls the product's signed helper.
import AppKit
import Darwin
import NearpaneCore
@testable import NearpaneUI

private struct Rejected: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
private let work = Bundle.main.bundleURL.deletingLastPathComponent()
private let ready = work.appendingPathComponent("owned.json")
private struct Witness: Codable {
    let pid: Int32, numbers: [UInt32], key: UInt32?, main: UInt32?
}

#if TARGET_WINDOWS
@main private struct Target {
    @MainActor static func main() {
        let app = NSApplication.shared
        guard Bundle.main.bundleIdentifier == "net.example.nearpane-window-selection", app.activationPolicy() == .regular,
              !app.isActive, NSScreen.screens.count == 1, let screen = NSScreen.screens.first else { exit(3) }
        _ = app.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        var windows = [NSWindow]()
        // Wait for the ordinary app to finish registration in the GUI login session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            for n in 0..<2 {
                let rect = NSRect(x:screen.visibleFrame.midX + CGFloat(n*12), y:screen.visibleFrame.midY + CGFloat(n*9), width:268, height:146)
                let w = NSWindow(contentRect: rect, styleMask: [.titled,.resizable,.closable,.miniaturizable],
                                 backing:.buffered,defer:true,screen:screen)
                w.isReleasedWhenClosed = false
                w.title = n == 0 ? "设计草图" : "项目笔记"
                w.setFrame(rect, display:false)
                w.tabbingMode = .disallowed
                w.collectionBehavior = [.canJoinAllApplications]
                w.contentView = NSTextField(labelWithString:w.title)
                if app.isHidden { app.unhideWithoutActivation() }
                w.orderFrontRegardless()
                windows.append(w)
            }
        }
        let start = Date()
        let timer = Timer(timeInterval:0.035,repeats:true) { _ in MainActor.assumeIsolated {
            if FileManager.default.fileExists(atPath:work.appendingPathComponent("done").path) || Date().timeIntervalSince(start) > 18 {
                for w in windows { w.orderOut(nil); w.close() }
                app.terminate(nil)
                return
            }
            guard windows.count == 2 else { return }
            let value = Witness(pid:getpid(), numbers:windows.map { UInt32($0.windowNumber) },
                key:app.keyWindow.map { UInt32($0.windowNumber) }, main:app.mainWindow.map { UInt32($0.windowNumber) })
            if let data = try? JSONEncoder().encode(value) { try? data.write(to:ready,options:.atomic) }
        }}
        RunLoop.main.add(timer,forMode:.common)
        app.run()
    }
}
#else
@main private struct SelectionTrial {
    @MainActor static func main() async {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.prohibited)
        let origin = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var result = [String: Any]()
        var owned: NSRunningApplication?
        do {
            guard let origin, NSScreen.screens.count == 1, AXIsProcessTrusted(),
                  CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.keyDown) > 15,
                  CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.leftMouseDown) > 15 else {
                throw Rejected("No quiet single-display session with an existing AX permission")
            }
            // An ordinary fixture launched from a native full-screen Space may be sent to a
            // different desktop. Do not open it or attempt to borrow focus in that case.
            let original = AXUIElementCreateApplication(origin)
            var focusedValue: CFTypeRef?, full: CFTypeRef?
            guard AXUIElementCopyAttributeValue(original,kAXFocusedWindowAttribute as CFString,&focusedValue) == .success,
                  let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID(),
                  AXUIElementCopyAttributeValue(focusedValue as! AXUIElement,"AXFullScreen" as CFString,&full) == .success,
                  full as? Bool == false else { throw Rejected("ordinary desktop not confirmed; no fixture opened") }
            let targetURL = work.appendingPathComponent("Design Notes.app")
            let fixture = Process()
            fixture.executableURL = targetURL.appendingPathComponent("Contents/MacOS/Notes")
            // Inherit this GUI login directly; LaunchServices may start a background regular app in another stage.
            try fixture.run()
            defer { try? Data().write(to:work.appendingPathComponent("done"),options:.atomic) }
            for _ in 0..<50 where !FileManager.default.fileExists(atPath: ready.path) {
                try await Task.sleep(for:.milliseconds(45))
            }
            guard let target = NSRunningApplication(processIdentifier: fixture.processIdentifier) else { throw Rejected("fixture registration") }
            owned = target
            guard target.bundleURL?.standardizedFileURL == targetURL.standardizedFileURL,
                  target.bundleIdentifier == "net.example.nearpane-window-selection" else { throw Rejected("fixture identity") }
            let pid = target.processIdentifier
            func state() -> Witness? { (try? Data(contentsOf:ready)).flatMap { try? JSONDecoder().decode(Witness.self,from:$0) } }
            for _ in 0..<60 where state() == nil { try await Task.sleep(for:.milliseconds(45)) }
            guard let w = state(), w.pid == pid, w.numbers.count == 2, Set(w.numbers).count == 2,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == origin else { throw Rejected("initial focus or owned windows") }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue:info))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,size) == size else { throw Rejected("no process birth") }
            let launch = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
            try await Task.sleep(for:.milliseconds(350))
            result["phase"] = "bind signed helper"
            // Independent accessibility read from the test controller; only our child PID is queried.
            let activeIDs = Set((NSWindow.windowNumbers(options:.allApplications) ?? []).map(\.uint32Value))
            result["ownedActiveNumbers"] = w.numbers.map(activeIDs.contains)
            let geometry = w.numbers.map { n -> [Double] in
                guard let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow,n) as? [[String:Any]],
                      let row = rows.first, row[kCGWindowIsOnscreen as String] as? Bool == true,
                      let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                      let r = CGRect(dictionaryRepresentation:bounds) else { return [] }
                return [r.minX,r.minY,r.width,r.height]
            }
            result["visibleFrames"] = geometry
            guard geometry.allSatisfy({ $0.count == 4 }), w.numbers.allSatisfy(activeIDs.contains) else {
                throw Rejected("WindowServer did not expose both owned windows on the active desktop")
            }
            let ax = AXUIElementCreateApplication(pid)
            _ = AXUIElementSetMessagingTimeout(ax, 1)
            var initial: CFArray?
            let status = AXUIElementCopyAttributeValues(ax, kAXWindowsAttribute as CFString, 0, 65, &initial)
            result["independentAXStatus"] = Int(status.rawValue)
            result["independentAXCount"] = (initial as? [AXUIElement])?.count ?? 0
            var count = 0
            result["countAPI"] = AXUIElementGetAttributeValueCount(ax,kAXWindowsAttribute as CFString,&count).rawValue
            result["count"] = count
            var value: CFTypeRef?
            result["valueAPI"] = AXUIElementCopyAttributeValue(ax,kAXWindowsAttribute as CFString,&value).rawValue
            result["fullCount"] = (value as? [AXUIElement])?.count ?? 0
            let directory = try OrdinaryWindowDirectory(.init(pid:pid,launch:launch,bundle:target.bundleIdentifier!,name:"Design Notes"))
            let choices = try await directory.choices(initial:true)
            var confirmed = [UInt32]()
            for n in [w.numbers[0], w.numbers[1], w.numbers[0]] {
                let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard foreground == (confirmed.isEmpty ? origin : pid),
                      CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.keyDown) > 12,
                      CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.leftMouseDown) > 12,
                      let choice = choices.first(where: { $0.number == n }), let handle = directory.handles[choice.id],
                      let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow,n) as? [[String:Any]], rows.count == 1,
                      rows[0][kCGWindowOwnerPID as String] as? Int32 == pid,
                      let bounds = rows[0][kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation:bounds),
                      let d = SystemScreens.geometry().first else { throw Rejected("scope or focus changed") }
                let frame = SurfaceRect(x:r.minX,y:r.minY,width:r.width,height:r.height)
                result["phase"] = "select " + String(confirmed.count + 1)
                try await handle.focusCurrent(frame:frame,display:d.id,deadline:ProcessInfo.processInfo.systemUptime+5)
                for _ in 0..<12 where state()?.key != n { try await Task.sleep(for:.milliseconds(35)) }
                guard state()?.key == n, state()?.main == n, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    throw Rejected("owner did not independently confirm key and main")
                }
                confirmed.append(n)
                result["confirmedKeyAndMain"] = confirmed
            }
        } catch { result["failure"] = (error as? Rejected)?.reason ?? error.localizedDescription }
        // Only the owned process closes its own windows. Never send an activation or restore event to a user's app.
        if let owned {
            try? Data().write(to:work.appendingPathComponent("done"),options:.atomic)
            for _ in 0..<40 where !owned.isTerminated { try? await Task.sleep(for:.milliseconds(60)) }
            result["ownedProcessExited"] = owned.isTerminated
        }
        try? await Task.sleep(for:.milliseconds(300))
        result["originalForegroundRestored"] = origin != nil && origin == NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ok = result["failure"] == nil && result["ownedProcessExited"] as? Bool == true && result["originalForegroundRestored"] as? Bool == true
        result["pass"] = ok
        if let data = try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]) { FileHandle.standardOutput.write(data) }
        exit(ok ? 0 : 3)
    }
}
#endif
