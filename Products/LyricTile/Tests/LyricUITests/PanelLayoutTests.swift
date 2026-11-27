import AppKit
import Foundation
import LyricCore
import LyricPlayback
import LyricServices
import SwiftUI
import Testing
@testable import LyricUI

/// Native view layout fixtures only. These authored songs never enter the app,
/// a real player, a production session lease, or the release bundle.
@Suite("Native panel layout fixtures", .serialized)
@MainActor
struct PanelLayoutTests {
    @Test(arguments: PanelLayoutScenario.allCases)
    func productionViewFitsItsSurface(_ scenario: PanelLayoutScenario) async throws {
        let fixture = try PanelLayoutFixture(scenario: scenario)
        defer { fixture.remove() }
        let model = try await fixture.model()
        #expect(!model.ownsSession)

        _ = NSApplication.shared
        let size = NSSize(width: scenario.width, height: scenario.height)
        let hosting = NSHostingView(rootView: LyricPanelView(model: model))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.appearance = NSAppearance(named: scenario.dark ? .darkAqua : .aqua)
        window.contentView = hosting
        defer { window.orderOut(nil); window.close() }

        // Pin the control presentation while rendering. This tests its layout,
        // not a synthetic mouse event or a successful transport command.
        model.songMenuIsOpen = scenario.hover
        model.setControlsVisible(scenario.hover)
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        #expect(hosting.bounds.size == size)
        #expect(window.contentView === hosting)
        #expect(model.controlsVisible == scenario.hover)
        let glyphs = nativeGlyphs(in: hosting)
        if scenario.hasLyrics {
            #expect(model.panelContent == .lyrics)
            #expect(model.currentCue?.text == scenario.currentLine)
            #expect(model.contextText(at: -2) == "把微光留在纸上")
            #expect(model.contextText(at: -1) == "窗外的风经过长街")
            #expect(model.contextText(at: 1) == "脚步跟着雨停下来")
            #expect(model.contextText(at: 2) == "灯在街角慢慢亮起")
            #expect(glyphs.count == 1)
            let glyph = try #require(glyphs.first)
            let frame = hosting.convert(glyph.bounds, from: glyph)
            // Check the production CoreText view really participates in layout
            // and remains inside the window, including long text at 176 pt.
            #expect(frame.width > 80)
            #expect(frame.height > 20)
            if scenario == .lightLyrics || scenario == .lightLyricsHover {
                #expect(frame.height <= 30)
            }
            if scenario == .narrowDarkLongLyrics {
                #expect(frame.height == 87)
                #expect(glyph.toolTip == scenario.currentLine)
            }
            if scenario == .lightLongLyrics {
                #expect(frame.height >= 81 && frame.height <= 108)
                #expect(glyph.toolTip == nil)
            }
            if scenario.hover {
                let top = hosting.isFlipped ? frame.minY : size.height - frame.maxY
                let bottom = hosting.isFlipped ? frame.maxY : size.height - frame.minY
                #expect(top >= 46 && bottom <= 131)
                #expect(frame.height <= 58)
            }
            #expect(frame.minX >= -0.5 && frame.maxX <= size.width + 0.5)
            #expect(frame.minY >= -0.5 && frame.maxY <= size.height + 0.5)
            if scenario.dark {
                #expect(model.translationText == PanelLayoutFixture.translation)
            }
        } else {
            #expect(glyphs.isEmpty)
            if scenario != .noSong { #expect(model.panelContent == .compact) }
        }
        if scenario == .missingMetadata {
            #expect(model.title == "未提供曲名")
            #expect(model.artist.isEmpty)
            #expect(model.artwork == nil)
            #expect(model.durationMS == nil)
            #expect(model.playbackPositionMS == nil)
            #expect(!model.canSeek)
        }

        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        let alpha = maximumAlpha(in: bitmap)
        if scenario == .noSong {
            // The real root view must draw no waiting tile or material surface.
            #expect(alpha < 0.01)
        } else {
            #expect(alpha > 0.5)
        }
        try saveEvidenceIfRequested(window: window, scenario: scenario,
                                    glyphCount: glyphs.count, maximumAlpha: alpha)

        if scenario == .lightLongLyrics || scenario == .narrowDarkLongLyrics {
            let glyph = try #require(glyphs.first)
            let original = hosting.convert(glyph.bounds, from: glyph)
            // A still cue has no animation clock to repair a stale clip. Change
            // only hover/height, retaining the very same native glyph view.
            model.songMenuIsOpen = true
            model.setControlsVisible(true)
            try await Task.sleep(for: .milliseconds(80))
            hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
            let hovered = hosting.convert(glyph.bounds, from: glyph)
            #expect(hovered.height < original.height)
            // An odd row height can snap to the adjacent half point on a 1x host.
            #expect(abs(hovered.midY - original.midY) <= 0.5)
            #expect(glyph.toolTip == scenario.currentLine)
            model.songMenuIsOpen = false
            model.setControlsVisible(false)
            try await Task.sleep(for: .milliseconds(80))
            hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
            #expect(hosting.convert(glyph.bounds, from: glyph) == original)
            #expect(scenario == .narrowDarkLongLyrics || glyph.toolTip == nil)
        }
    }

    @Test func pausedInteractionKeepsItsSurfaceWhenLyricsArrive() async throws {
        let fixture = try PanelLayoutFixture(scenario: .compact)
        defer { fixture.remove() }
        let model = try await fixture.model()
        let playing = model.snapshot
        let selection = try #require(playing.selection)
        model.isVisible = true
        model.panelInteractionActive = true
        model.receive(.init(player: playing.player, selection: selection,
            anchor: .init(selection: selection, positionMS: 12_000, observedAt: PlaybackClock.now(),
                          playbackRate: 0, state: .paused, quality: .coarseSourceAnchor, expectedErrorMS: nil),
            state: .paused, capabilities: playing.capabilities))
        let file = fixture.directory.appendingPathComponent("paused-arrival.lrc")
        try Data("[00:00]把微光留在纸上".utf8).write(to: file)
        model.importLyrics(from: file, for: selection)
        await (try #require(model.lyricTask)).value
        #expect(model.document?.source.providerID == "local")
        #expect(model.currentCue != nil)
        #expect(model.panelContent == .compact)
        model.panelInteractionActive = false
        #expect(model.panelContent == .lyrics)
        model.receive(playing)
        #expect(model.panelContent == .lyrics)
        #expect(model.pausedPanelContent == nil)
    }

    private func nativeGlyphs(in view: NSView) -> [LyricGlyphView] {
        (view as? LyricGlyphView).map { [$0] } ?? view.subviews.flatMap { nativeGlyphs(in: $0) }
    }

    private func maximumAlpha(in bitmap: NSBitmapImageRep) -> CGFloat {
        var maximum: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                maximum = max(maximum, bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                if maximum >= 1 { return maximum }
            }
        }
        return maximum
    }

    private func saveEvidenceIfRequested(window: NSWindow, scenario: PanelLayoutScenario,
                                         glyphCount: Int, maximumAlpha: CGFloat) throws {
        guard let path = ProcessInfo.processInfo.environment["LYRICTILE_UI_EVIDENCE_DIR"],
              !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("fixture-\(scenario.rawValue).png")
        try LyricNativeSmoke.capture(window: window, to: image)
        let glyphFrames: [[String: Double]] = window.contentView.map { view in
            nativeGlyphs(in: view).map { glyph in
                let rect = view.convert(glyph.bounds, from: glyph)
                return ["x": Double(rect.minX), "y": Double(rect.minY),
                        "width": Double(rect.width), "height": Double(rect.height)]
            }
        } ?? []
        let report: [String: Any] = [
            "kind": "authored-native-layout-fixture",
            "scenario": scenario.rawValue,
            "image": image.lastPathComponent,
            "logicalWidth": scenario.width,
            "logicalHeight": scenario.height,
            "darkAppearance": scenario.dark,
            "controlsPresented": scenario.hover,
            "nativeGlyphViews": glyphCount,
            "glyphViewports": glyphFrames,
            "maximumAlpha": Double(maximumAlpha),
            "realPlayerTest": false,
            "transportCommandsTested": false,
            "sessionLeaseAcquired": false,
            "networkStarted": false,
            "artworkAcceptanceTested": false,
            "limitations": "Authored test input. No session lease: transport is disabled and cover acceptance is not exercised. Hover presentation is pinned; no mouse event is claimed."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("fixture-\(scenario.rawValue).json"), options: .atomic)
    }
}

enum PanelLayoutScenario: String, CaseIterable, Sendable {
    case lightLyrics = "light-lyrics"
    case lightLyricsHover = "light-lyrics-hover"
    case lightLongLyrics = "light-long-lyrics"
    case lightLongLyricsHover = "light-long-lyrics-hover"
    case compact = "compact"
    case compactHover = "compact-hover"
    case narrowDarkLongLyrics = "narrow-dark-long-lyrics"
    case narrowDarkLongLyricsHover = "narrow-dark-long-lyrics-hover"
    case missingMetadata = "missing-metadata"
    case noSong = "no-song-transparent"

    var width: CGFloat { dark ? 176 : 208 }
    var height: CGFloat { hasLyrics || self == .noSong ? LyricPanelLayout.lyricsHeight : LyricPanelLayout.compactHeight }
    var dark: Bool { self == .narrowDarkLongLyrics || self == .narrowDarkLongLyricsHover }
    var hover: Bool {
        [.lightLyricsHover, .lightLongLyricsHover, .compactHover,
         .narrowDarkLongLyricsHover, .missingMetadata].contains(self)
    }
    var hasLyrics: Bool {
        [.lightLyrics, .lightLyricsHover, .lightLongLyrics, .lightLongLyricsHover,
         .narrowDarkLongLyrics, .narrowDarkLongLyricsHover].contains(self)
    }
    var currentLine: String {
        switch self {
        case .narrowDarkLongLyrics, .narrowDarkLongLyricsHover:
            "我把窗边缓缓经过的风写进一张还没有寄出的信里，等街角的灯再次亮起"
        case .lightLongLyrics, .lightLongLyricsHover:
            "沿着安静的街道，慢慢走向那一盏还没有熄灭的灯"
        default: "让这一刻慢下来"
        }
    }
}

@MainActor
private struct PanelLayoutFixture {
    static let translation = "I leave the passing wind in a letter and wait for the corner light."
    let scenario: PanelLayoutScenario
    let directory: URL
    let defaults: UserDefaults
    let defaultsName: String
    let sessionID = UUID()

    init(scenario: PanelLayoutScenario) throws {
        self.scenario = scenario
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricPanelLayout-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsName = "LyricPanelLayout.test." + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        var settings = LyricSettings()
        settings.onlineLyrics = false
        settings.appearance = scenario.dark ? .dark : .light
        settings.largeText = scenario.dark
        settings.showTranslation = scenario.dark
        settings.save(to: defaults)
    }

    func model() async throws -> LyricAppModel {
        let repository = LyricRepository(storageURL: directory, onlineEnabled: false)
        let model = LyricAppModel(repository: repository, defaults: defaults)
        guard scenario != .noSong else { return model }
        let selection = LyricDomain.Selection(playerBundleID: "test.lyrictile.layout",
            sessionID: sessionID, generation: 1,
            recording: .init(fingerprint: "authored-layout-\(scenario.rawValue)", platformIDs: [], isrc: nil,
                title: scenario == .missingMetadata ? nil : "一盏灯的距离", artists: scenario == .missingMetadata ? [] : ["原创界面夹具"],
                album: "仅供布局验证", durationMS: scenario == .missingMetadata ? nil : 40_000, versionTags: []))
        let anchor: LyricDomain.PlaybackAnchor? = scenario == .missingMetadata ? nil : .init(
            selection: selection, positionMS: 12_000, observedAt: PlaybackClock.now(),
            playbackRate: 1, state: .playing, quality: .coarseSourceAnchor, expectedErrorMS: nil)
        model.receive(.init(player: .appleMusic, selection: selection, anchor: anchor, state: .playing,
            capabilities: .init(canPlay: true, canPause: true, canNext: true, canPrevious: true,
                                canSeek: scenario != .missingMetadata)))
        if let resolution = model.lyricTask { await resolution.value }
        if scenario.hasLyrics {
            let file = directory.appendingPathComponent(scenario.dark ? "authored-layout.ttml" : "authored-layout.lrc")
            let text: String
            if scenario.dark {
                text = """
                <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="zh-Hans">
                <body><div>
                <p begin="0s" end="5s">把微光留在纸上</p>
                <p begin="5s" end="10s">窗外的风经过长街</p>
                <p begin="10s" end="15s">\(scenario.currentLine)<span ttm:role="x-translation" xml:lang="en">\(Self.translation)</span></p>
                <p begin="15s" end="20s">脚步跟着雨停下来</p>
                <p begin="20s" end="40s">灯在街角慢慢亮起</p>
                </div></body></tt>
                """
            } else {
                text = """
                [00:00]把微光留在纸上
                [00:05]窗外的风经过长街
                [00:10]\(scenario.currentLine)
                [00:15]脚步跟着雨停下来
                [00:20]灯在街角慢慢亮起
                """
            }
            try Data(text.utf8).write(to: file, options: .atomic)
            model.importLyrics(from: file, for: selection)
            let imported = try #require(model.lyricTask)
            await imported.value
            #expect(model.document?.source.providerID == "local")
            #expect(model.leadCues.count == 5)
            #expect(model.lyricFailure == nil)
        }
        return model
    }

    func remove() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: directory)
    }
}
