// Compile once as a disposable, regular two-window app, once as its isolated controller.
// Only the test app publishes its numbers. The controller calls the product's signed helper.
import AppKit
import Darwin
import CReadOnlySpaces
import NearpaneCore
import SwiftUI
@preconcurrency import ScreenCaptureKit
@testable import NearpaneUI

private struct Rejected: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
private let work = Bundle.main.bundleURL.deletingLastPathComponent()
private let ready = work.appendingPathComponent("owned.json")
struct Witness: Codable {
    let pid: Int32, numbers: [UInt32], key: UInt32?, main: UInt32?
}

#if TARGET_WINDOWS
@main private struct Target {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--roster") { RosterTrial.owner(); return }
        let app = NSApplication.shared
        guard Bundle.main.bundleIdentifier == "net.example.nearpane-window-selection", app.activationPolicy() == .regular,
              !app.isActive, NSScreen.screens.count == 1, let screen = NSScreen.screens.first else { exit(3) }
        _ = app.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        let count = CommandLine.arguments.contains("--single-app") ? 1 : 2
        var windows = [NSWindow]()
        // Wait for the ordinary app to finish registration in the GUI login session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            for n in 0..<count {
                let rect = NSRect(x:screen.visibleFrame.midX + CGFloat(n*12), y:screen.visibleFrame.midY + CGFloat(n*9), width:268, height:146)
                let style: NSWindow.StyleMask = [.titled,.resizable,.closable,.miniaturizable]
                let w: NSWindow
                if CommandLine.arguments.contains("--gallery") {
                    let panel = NSPanel(contentRect:rect,styleMask:style.union(.nonactivatingPanel),backing:.buffered,defer:true,screen:screen)
                    panel.hidesOnDeactivate = false; panel.level = .normal
                    w = panel
                } else {
                    w = NSWindow(contentRect:rect,styleMask:style,backing:.buffered,defer:true,screen:screen)
                }
                w.isReleasedWhenClosed = false
                w.title = n == 0 ? "设计草图" : "项目笔记"
                w.setFrame(rect, display:false)
                w.tabbingMode = .disallowed
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
                let card = NSView()
                card.wantsLayer = true
                card.layer?.backgroundColor = (n == 0 ? NSColor(srgbRed: 0.11, green: 0.52, blue: 0.32, alpha: 1) :
                    NSColor(srgbRed: 0.18, green: 0.26, blue: 0.69, alpha: 1)).cgColor
                let label = NSTextField(labelWithString: w.title)
                label.font = .systemFont(ofSize: 20, weight: .semibold); label.textColor = .white
                label.frame = NSRect(x: 17, y: 40, width: 200, height: 30)
                card.addSubview(label); w.contentView = card
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
            guard windows.count == count else { return }
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
    @MainActor private static func ordinarySource(_ pid: Int32, sharedWindow: Bool = false) -> UInt64? {
        guard NSScreen.screens.count == 1, NPReadOnlySpacesOpen() == 1,
              let rows = NPReadInventory() as? [[String:Any]], rows.count == 1, let row = rows.first,
              let current = (row["Current Space"] as? [String:Any])?["id64"] as? UInt64,
              let records = row["Spaces"] as? [[String:Any]],
              records.filter({ $0["id64"] as? UInt64 == current }).count == 1,
              records.first(where:{ $0["id64"] as? UInt64 == current })?["type"] as? Int == 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?, full: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let win = focused as! AXUIElement
        let fullStatus = AXUIElementCopyAttributeValue(win,"AXFullScreen" as CFString,&full)
        guard fullStatus == .attributeUnsupported || full as? Bool == false else { return nil }
        let n = NPReadAXWindowNumber(win)
        guard n > 0, (NSWindow.windowNumbers(options:.allApplications) ?? []).contains(NSNumber(value:n)),
              let cg = CGWindowListCopyWindowInfo(.optionIncludingWindow,n) as? [[String:Any]], cg.count == 1,
              cg[0][kCGWindowOwnerPID as String] as? Int32 == pid,
              cg[0][kCGWindowIsOnscreen as String] as? Bool == true,
              let membership = NPReadWindowSpaces(n) as? [UInt64], (sharedWindow ? membership.contains(current) : membership == [current]) else { return nil }
        return current
    }

    @MainActor static func main() async {
        if CommandLine.arguments.contains("--roster") { await RosterTrial.run(); return }
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.prohibited)
        let origin = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var result = [String: Any]()
        var owned: NSRunningApplication?
        do {
            let galleryOnly = CommandLine.arguments.contains("--gallery")
            let singleApp = CommandLine.arguments.contains("--single-app")
            let expectedWindowCount = singleApp ? 1 : 2
            let hasAX = AXIsProcessTrusted()
            let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.keyDown) > 15 &&
                CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.leftMouseDown) > 15
            result["controllerScreenPermission"] = CGPreflightScreenCaptureAccess()
            result["controllerAXPermission"] = hasAX
            result["screens"] = NSScreen.screens.count
            result["quiet"] = quiet
            guard let origin, NSScreen.screens.count == 1, galleryOnly || (hasAX && quiet) else {
                throw Rejected("focus trial needs one idle screen and Accessibility")
            }
            // Reading our own fixture content does not require a keyboard lease or
            // Accessibility. Focus actions separately require an ordinary desktop.
            let baselineSpace = Self.ordinarySource(origin)
            if !galleryOnly {
                result["ordinarySpaceWitness"] = baselineSpace != nil
                guard baselineSpace != nil else { throw Rejected("no current ordinary desktop with a visible source window; no focus action") }
            }
            let targetURL = work.appendingPathComponent("Design Notes.app")
            let fixture = Process()
            fixture.executableURL = targetURL.appendingPathComponent("Contents/MacOS/Notes")
            // Inherit this GUI login directly; LaunchServices may start a background regular app in another stage.
            if galleryOnly { fixture.arguments = ["--gallery"] }
            if singleApp { fixture.arguments = ["--single-app"] }
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
            guard let w = state(), w.pid == pid, w.numbers.count == expectedWindowCount, Set(w.numbers).count == expectedWindowCount,
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
            if galleryOnly {
                do { result["independentCapturedCards"] = try await GalleryTrial.capturedCards(owner:w,destination:work) }
                catch { result["independentCaptureIssue"] = error.localizedDescription }
            }
            guard geometry.allSatisfy({ $0.count == 4 }), w.numbers.allSatisfy(activeIDs.contains) else {
                throw Rejected("WindowServer did not expose both owned windows on the active desktop")
            }
            if galleryOnly {
                let receipt = try await GalleryTrial.run(owner: w, launch: launch, frames: geometry, destination: work, originalFront: origin)
                result["gallery"] = receipt
                guard receipt["pass"] as? Bool == true else { throw Rejected("real window thumbnails did not render independently") }
            }
            if singleApp {
                guard let original = baselineSpace, Self.ordinarySource(origin) == original,
                      (NPReadWindowSpaces(w.numbers[0]) as? [UInt64])?.contains(original) == true else {
                    throw Rejected("source or target desktop changed")
                }
                let d = SystemScreens.geometry()[0], r = geometry[0]
                let frame = SurfaceRect(x:r[0],y:r[1],width:r[2],height:r[3])
                let observed = WindowObservation(id:"fixture",displayID:d.id,bounds:frame,membership:.unknown,confidence:.unknown,
                    metadata:.init(number:w.numbers[0],pid:pid,launchMicroseconds:launch,element:nil,globalFrame:frame,
                        frontToBack:0,minimized:nil,fullScreen:nil,isOnscreen:true,onActiveDesktop:true))
                let sampleTime = Date(), u = ProcessInfo.processInfo.systemUptime
                let sample = DesktopSnapshot.observed(.init(session:UUID(),revision:1,parentPID:getpid(),fixtureWindows:w.numbers,
                    anchors:[],experimentalSpaces:false),from:sampleTime,to:sampleTime,build:"fixture",topology:d.id,consistent:true,
                    separateSpaces:NSScreen.screensHaveSeparateSpaces,displays:[.init(id:d.id,frame:d.frame,rotationDegrees:Int(d.rotationDegrees),
                    backingScale:d.backingScale,usable:d.visibleFrame)],scopes:[],windows:[observed],evidence:.init(population:.markedFixture,
                    accessibility:.denied,spaces:.disabled,rows:[],windowLimitReached:false,beganUptime:u,endedUptime:u))
                guard let target = DesktopWindowTarget(observed,in:sample), DesktopWindowSelection.soleWindow(target) else {
                    throw Rejected("one and only one WindowServer window required")
                }
                try await DesktopWindowSelection.select(target,deadline:u+6,hasAX:false,stillCurrent:{
                    state()?.numbers == w.numbers && target.present(in:sample) && target.isVisibleSurface()
                })
                for _ in 0..<12 where state()?.key != w.numbers.first { try await Task.sleep(for:.milliseconds(35)) }
                guard state()?.key == w.numbers.first, state()?.main == w.numbers.first,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw Rejected("single window failed independent key/main") }
                result["singleWindowPublicActivation"] = true
            } else if CommandLine.arguments.contains("--click-cards") && !galleryOnly {
                guard Self.ordinarySource(origin) == baselineSpace, let original = baselineSpace,
                      w.numbers.allSatisfy({ (NPReadWindowSpaces($0) as? [UInt64])?.contains(original) == true }) else {
                    throw Rejected("fixture or source desktop changed before card selection")
                }
                let receipt = try await GalleryTrial.run(owner:w,launch:launch,frames:geometry,destination:work,originalFront:origin,
                    choose: { n in
                        guard let now = state(), now.pid == pid, now.numbers == w.numbers,
                              CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.keyDown) > 15,
                              CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.leftMouseDown) > 15,
                              let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                              [origin,pid].contains(front), Self.ordinarySource(front, sharedWindow:front == pid) == original else { return false }
                        return now.key == n && now.main == n && front == pid
                    },
                    safeToPress: {
                        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, [origin,pid].contains(front),
                              CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.keyDown) > 15,
                              CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:.leftMouseDown) > 15 else { return false }
                        return Self.ordinarySource(front, sharedWindow:front == pid) == original
                    })
                result["interaction"] = receipt
                if let final = state() {
                    result["lastOwnerKey"] = final.key
                    result["lastOwnerMain"] = final.main
                    result["lastOwnerFront"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                }
                guard receipt["pass"] as? Bool == true else { throw Rejected("window choice did not obtain exact focus") }
            } else if !galleryOnly {
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
                    do { try await handle.focusCurrent(frame:frame,display:d.id,deadline:ProcessInfo.processInfo.systemUptime+5) }
                    catch {
                        let actual = state()
                        result["ownerKeyIsSelected"] = actual?.key == n
                        result["ownerMainIsSelected"] = actual?.main == n
                        result["ownerIsForeground"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                        var focus: CFTypeRef?
                        if AXUIElementCopyAttributeValue(ax,kAXFocusedWindowAttribute as CFString,&focus) == .success,
                           let focus { result["axFocusIsSelected"] = NPReadAXWindowNumber(focus) == n }
                        throw error
                    }
                    for _ in 0..<12 where state()?.key != n { try await Task.sleep(for:.milliseconds(35)) }
                    guard state()?.key == n, state()?.main == n, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                        throw Rejected("owner did not independently confirm key and main")
                    }
                    confirmed.append(n)
                    result["confirmedKeyAndMain"] = confirmed
                }
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
