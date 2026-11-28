import AppKit
import Foundation
import SwiftUI
import CryptoKit
import NearpaneLyricsModule
import LyricUI
import LyricPlayback

@MainActor final class FilmPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@main struct FilmV2Capture {
    @MainActor static func main() {
        let app=NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate=FilmDelegate()
        app.delegate=delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class FilmDelegate: NSObject, NSApplicationDelegate {
    var module: NearpaneLyricsModule!
    var panel: FilmPanel!
    var destination: URL!
    var records: [[String: Any]]=[]
    var ready=false
    var imported=false
    var start=ProcessInfo.processInfo.systemUptime
    let environment=ProcessInfo.processInfo.environment

    func write(_ name: String,_ object: [String: Any]) {
        guard let bytes=try? JSONSerialization.data(withJSONObject: object,options:[.prettyPrinted,.sortedKeys]) else { return }
        try? bytes.write(to:destination.appendingPathComponent(name),options:.atomic)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await run() }
    }
    func run() async {
        guard environment["GITHUB_ACTIONS"] == "true",
              let out=environment["FILM_V2_OUTPUT"],
              let input=environment["FILM_V2_LRC"],
              let display=UInt32(environment["FILM_V2_DISPLAY_ID"] ?? "") else { exit(2) }
        destination=URL(fileURLWithPath:out,isDirectory:true)
        try? FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        guard let screen=NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }), screen.backingScaleFactor >= 2 else {
            write("failure.json",["error":"The requested real HiDPI display was not available"]); exit(3)
        }
        if let wallpaper=environment["FILM_V2_WALLPAPER"] {
            do { try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath:wallpaper),for:screen,options:[.imageScaling:NSImageScaling.scaleProportionallyUpOrDown.rawValue]) }
            catch { write("wallpaper-error.json",["error":String(describing:error)]) }
        }
        let defaults=UserDefaults(suiteName:"com.holdsnow.film.v2."+UUID().uuidString)!
        module=NearpaneLyricsModule(storageURL:destination.appendingPathComponent("lyric-storage"),defaults:defaults)
        module.model.settings.onlineLyrics=false
        module.model.settings.appearance = .light
        module.model.settings.completedWelcome=true
        module.model.selectPlayer(.appleMusic)
        // This is the same native product view at its canonical layout, enlarged
        // only as a photography composition on a real 2x WindowServer display.
        let scale: CGFloat=280.0/208.0
        let size=NSSize(width:280,height:192*scale)
        let root=module.view.frame(width:208,height:192)
            .scaleEffect(scale,anchor:.topLeading)
            .frame(width:size.width,height:size.height,alignment:.topLeading)
            .environment(\.colorScheme,.light)
        let hosting=NSHostingView(rootView:root)
        panel=FilmPanel(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=true
        panel.level = .floating; panel.hidesOnDeactivate=false; panel.acceptsMouseMovedEvents=true
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.contentView=hosting
        panel.setFrame(NSRect(x:screen.frame.maxX-size.width-28,y:screen.frame.maxY-size.height-52,width:size.width,height:size.height),display:true)
        panel.orderFrontRegardless()
        let acquired=await module.activate(takingOverStandalone:false)
        module.model.isVisible=true
        write("camera-host.json",[
            "sourceCommit":"d5767d87bc45245b31d0980e91e43778c5f424ed",
            "module":"NearpaneLyricsModule","realPlayerRequired":true,"fixtureSnapshots":false,
            "sourceViewLogicalSize":[208,192],"photographicScale":scale,
            "screenFrame":[screen.frame.minX,screen.frame.minY,screen.frame.width,screen.frame.height],
            "screenBackingScale":screen.backingScaleFactor,"displayID":display,
            "panelFrame":[panel.frame.minX,panel.frame.minY,panel.frame.width,panel.frame.height],
            "systemReduceMotion":NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "acquiredSession":acquired,"audioSource":"Actual Apple Music playing the licensed song",
            "scope":"Isolated native camera host of the currently embedded product module; not the full release Host."
        ])
        guard acquired else { write("failure.json",["error":"Lyrics session acquisition failed"]); exit(4) }
        for frame in 0..<9000 {
            let model=module.model
            let command=destination.appendingPathComponent("pointer-command.json")
            if let bytes=try? Data(contentsOf:command),let request=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:String],let action=request["action"] {
                try? FileManager.default.removeItem(at:command)
                let primaryHeight=NSScreen.screens.first?.frame.height ?? screen.frame.height
                let end=action == "enter" ? NSPoint(x:panel.frame.midX,y:panel.frame.midY) : NSPoint(x:panel.frame.minX-90,y:panel.frame.midY-20)
                let begin=NSEvent.mouseLocation
                for tick in 1...24 {
                    let t=Double(tick)/24;let smooth=t*t*(3-2*t)
                    let location=CGPoint(x:begin.x+(end.x-begin.x)*smooth,y:primaryHeight-(begin.y+(end.y-begin.y)*smooth))
                    CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:location,mouseButton:.left)?.post(tap:.cghidEventTap)
                    try? await Task.sleep(for:.milliseconds(16))
                }
                write("pointer-"+action+".json",["action":action,"uptime":ProcessInfo.processInfo.systemUptime,"actualCGEventPosted":true,"controlsVisible":model.controlsVisible])
            }
            if !imported, model.snapshot.selection != nil {
                imported=model.filmImportLocalLyrics(URL(fileURLWithPath:input))
            }
            let now=ProcessInfo.processInfo.systemUptime
            let pointer=NSEvent.mouseLocation
            let row: [String:Any]=[
                "frame":frame,"uptime":now,"elapsed":now-start,"unixTime":Date().timeIntervalSince1970,
                "title":model.title,"artist":model.artist,"player":model.snapshot.player?.rawValue ?? "none",
                "state":String(describing:model.snapshot.state),"positionMS":model.playbackPositionMS as Any? ?? NSNull(),
                "currentCueIndex":model.currentCueIndex as Any? ?? NSNull(),
                "cueText":model.currentCue?.text ?? "", "lyricCount":model.leadCues.count,
                "artworkBytes":model.snapshot.artwork?.count ?? 0,"artworkDecoded":model.artwork != nil,
                "controlsVisible":model.controlsVisible,"windowVisible":panel.isVisible,
                "frontmostBundleID":NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none",
                "mouse":[pointer.x,pointer.y]
            ]
            records.append(row)
            if !ready, model.title == "Good To Go", model.leadCues.count > 0, model.snapshot.state == .playing,
               (environment["FILM_V2_REQUIRE_ARTWORK"] != "1" || model.artwork != nil) {
                ready=true
                var receipt=row
                if let art=model.snapshot.artwork {
                    receipt["artworkSHA256"]=SHA256.hash(data:art).map{String(format:"%02x",$0)}.joined()
                    try? art.write(to:destination.appendingPathComponent("actual-track-artwork.bin"))
                }
                write("ready.json",receipt)
            }
            if frame % 15 == 0 { write("state.json",row) }
            if frame % 150 == 0 { write("native-state-timeline.json",["samples":records]) }
            if FileManager.default.fileExists(atPath:destination.appendingPathComponent("stop").path) { break }
            try? await Task.sleep(for:.milliseconds(33))
        }
        write("native-state-timeline.json",["samples":records])
        _=await module.deactivate()
        NSApplication.shared.terminate(nil)
    }
}
