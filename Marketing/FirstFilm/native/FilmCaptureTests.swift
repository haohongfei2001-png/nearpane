import AppKit
import Foundation
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
        for language in ["zh", "en"] {
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
                title: language == "zh" ? "一盏灯的距离" : "A Place to Stay", artists: ["HOLDSNOW"], album:"Original film study", durationMS:40_000, versionTags:[]))
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
            let size = NSSize(width:208,height:192)
            let view = NSHostingView(rootView:LyricPanelView(model:model))
            view.frame = NSRect(origin:.zero,size:size)
            let window = NSWindow(contentRect:NSRect(x:180,y:250,width:208,height:192),styleMask:[.borderless],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = false
            window.appearance = NSAppearance(named:.aqua); window.contentView = view; window.orderFrontRegardless()
            for cue in 0..<8 {
                update(Int64(cue*4_000+500))
                try await Task.sleep(for:.milliseconds(240))
                try FilmCaptureSupport.save(view:view,to:directory.appendingPathComponent("\(language)-cue-\(cue).png"))
            }
            update(10_000)
            model.songMenuIsOpen = true
            model.setControlsVisible(true)
            try await Task.sleep(for:.milliseconds(240))
            try FilmCaptureSupport.save(view:view,to:directory.appendingPathComponent(language+"-hover-layout-only.png"))
            window.orderOut(nil); window.close()
            defaults.removePersistentDomain(forName:suite)
            try? FileManager.default.removeItem(at:storage)
        }
        let report:[String:Any] = ["kind":"authored-native-layout-fixture", "productionView":"LyricPanelView", "logicalSize":[208,192],"renderScale":6,"languages":["zh","en"],"cuesPerLanguage":8,"realPlayerTest":false,"transportEnabled":false,"limitations":"Original authored fixture states rendered by production AppKit/SwiftUI view. Hover layout only; actual enabled controls and interactions are in real-music captures."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("SOURCE.json"))
    }
}
