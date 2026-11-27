import AppKit
import Foundation
import QuartzCore
import LyricCore
import LyricPlayback
import LyricServices
import SwiftUI
import Testing
@testable import LyricUI

@Suite("Film authored native views", .serialized)
@MainActor
struct FilmCaptureTests {
    @Test func captureAuthoredNativeStates() async throws {
        guard let output = ProcessInfo.processInfo.environment["LYRICTILE_FILM_OUTPUT"] else { return }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output, isDirectory: true).appendingPathComponent("authored-native")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = ProcessInfo.processInfo.environment["LYRICTILE_FILM_PROBE"] == "1"
        for language in (probe ? ["zh"] : ["zh", "en"]) {
            let suite = "FilmCapture." + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            let storage = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            var settings = LyricSettings()
            settings.onlineLyrics = false; settings.appearance = .light
            settings.save(to: defaults)
            let model = LyricAppModel(repository: LyricRepository(storageURL: storage, onlineEnabled: false), defaults: defaults)
            let lines = language == "zh" ? ["把微光留在纸上", "窗外的风经过长街", "让这一刻慢下来", "脚步跟着雨停下来", "灯在街角慢慢亮起", "喜欢的旋律还在身边", "把这一刻轻轻留下", "让下一句自然到来"] : ["A light upon the paper", "The wind along the street", "Every quiet moment", "Has a place to stay", "The corner fills with light", "A melody stays close", "Let this moment linger", "Let the next line arrive"]
            let selection = LyricDomain.Selection(playerBundleID: "test.lyrictile.film", sessionID: UUID(), generation: 1,
                recording: .init(fingerprint: "authored-film-"+language, platformIDs: [], isrc: nil,
                title: language == "zh" ? "留在此刻" : "Here, for a while", artists: ["HOLDSNOW"], album:"Original film study", durationMS:40_000, versionTags:[]))
            func update(_ milliseconds: Int64, state: LyricDomain.PlaybackState = .playing) {
                model.receive(.init(player:.appleMusic, selection:selection,
                    anchor:.init(selection:selection, positionMS:milliseconds, observedAt:PlaybackClock.now(), playbackRate:state == .playing ? 1 : 0, state:state, quality:.coarseSourceAnchor, expectedErrorMS:nil),
                    state:state, capabilities:.init(canPlay:true,canPause:true,canNext:true,canPrevious:true,canSeek:true)))
            }
            update(0)
            if let task = model.lyricTask { await task.value }
            let lrc = directory.appendingPathComponent(language+"-original.lrc")
            try lines.enumerated().map { String(format:"[00:%02d.00]",$0.offset*4)+$0.element }.joined(separator:"\n").write(to:lrc,atomically:true,encoding:.utf8)
            model.importLyrics(from:lrc,for:selection)
            if let task = model.lyricTask { await task.value }
            func content(scale: CGFloat) -> some View {
                LyricPanelView(model: model)
                    .frame(width: 208, height: 192)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: 208 * scale, height: 192 * scale, alignment: .topLeading)
                    .environment(\.displayScale, scale)
            }
            let size = NSSize(width:1248,height:1152)
            let view = NSHostingView(rootView: content(scale: 6))
            view.frame = NSRect(origin:.zero,size:size)
            let window = NSWindow(contentRect:NSRect(x:180,y:250,width:1248,height:1152),styleMask:[.borderless],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = false
            window.appearance = NSAppearance(named:.aqua); window.contentView = view; window.orderFrontRegardless()
            for cue in (probe ? [2] : Array(0..<8)) {
                update(Int64(cue*4_000+500))
                try await Task.sleep(for:.milliseconds(240))
                prepareLayers(view, scale: 6)
                try FilmCaptureSupport.save(view:view,to:directory.appendingPathComponent("\(language)-cue-\(cue).png"), scale: 1)
            }
            if probe {
                window.orderOut(nil); window.close()
                defaults.removePersistentDomain(forName:suite)
                try? FileManager.default.removeItem(at:storage)
                continue
            }
            view.rootView = content(scale: 4)
            view.frame = NSRect(x: 0, y: 0, width: 832, height: 768)
            window.setContentSize(NSSize(width: 832, height: 768))
            let motionDirectory = directory.appendingPathComponent(language+"-native-motion")
            try FileManager.default.createDirectory(at: motionDirectory, withIntermediateDirectories: true)
            update(6_500)
            try await Task.sleep(for: .milliseconds(250))
            let clockStart = ProcessInfo.processInfo.systemUptime
            var motionFrames: [[String: Any]] = []
            for index in 0..<180 {
                let goal = clockStart + Double(index) / 30
                let delay = goal - ProcessInfo.processInfo.systemUptime
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                let elapsed = ProcessInfo.processInfo.systemUptime - clockStart
                update(6_500 + Int64(elapsed * 1_000))
                await Task.yield()
                let name = String(format: "frame-%04d.png", index)
                prepareLayers(view, scale: 4)
                try FilmCaptureSupport.save(view: view, to: motionDirectory.appendingPathComponent(name), scale: 1)
                motionFrames.append(["file": name, "elapsed": elapsed, "positionMS": 6_500 + Int64(elapsed * 1_000), "cueIndex": model.currentCueIndex ?? -1])
                try await Task.sleep(for: .milliseconds(2))
            }
            let motionReport: [String: Any] = ["kind": "authored-native-view-motion", "realPlayer": false, "productionView": "LyricPanelView", "origin": "Original HOLDSNOW demo lyrics; fixture source positions follow host monotonic elapsed time.", "renderScale": 4, "targetFPS": 30, "frames": motionFrames, "limitations": "Native production SwiftUI cue transition rendered with authored input; not a player, transport or acoustic-sync qualification."]
            try JSONSerialization.data(withJSONObject: motionReport, options: [.prettyPrinted, .sortedKeys]).write(to: motionDirectory.appendingPathComponent("capture.json"))
            view.rootView = content(scale: 6)
            view.frame = NSRect(x: 0, y: 0, width: 1248, height: 1152)
            window.setContentSize(NSSize(width: 1248, height: 1152))
            update(10_000)
            model.songMenuIsOpen = true
            model.setControlsVisible(true)
            try await Task.sleep(for:.milliseconds(240))
            prepareLayers(view, scale: 6)
            try FilmCaptureSupport.save(view:view,to:directory.appendingPathComponent(language+"-hover-layout-only.png"), scale: 1)
            window.orderOut(nil); window.close()
            defaults.removePersistentDomain(forName:suite)
            try? FileManager.default.removeItem(at:storage)
        }
        let report:[String:Any] = ["kind":"authored-native-layout-fixture", "productionView":"LyricPanelView", "logicalSize":[208,192],"renderScale":6,"languages":probe ? ["zh"] : ["zh","en"],"probeOnly":probe,"cuesPerLanguage":probe ? 1 : 8,"captureMethod":"Native view at unchanged 208x192 logical layout, scaled by SwiftUI into a larger actual hosting surface, then captured at 1x; no bitmap enlargement","realPlayerTest":false,"transportEnabled":false,"limitations":"Original authored fixture states rendered by production AppKit/SwiftUI view. Hover layout only; actual enabled controls and interactions are in real-music captures."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("SOURCE.json"))
    }
    private func prepareLayers(_ view: NSView, scale: CGFloat) {
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        func prepare(_ layer: CALayer) {
            layer.contentsScale = scale
            layer.rasterizationScale = scale
            layer.shouldRasterize = false
            layer.setNeedsDisplay()
            layer.sublayers?.forEach(prepare)
        }
        if let layer = view.layer { prepare(layer) }
        view.needsDisplay = true
        view.subviews.forEach { prepareLayers($0, scale: scale) }
    }

}
