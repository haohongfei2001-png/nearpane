import Testing
@testable import NearpaneCore

struct WorkbenchLayoutTests {
    private let tools = [BuiltinCatalog.voice, BuiltinCatalog.screenshots, BuiltinCatalog.lyrics, BuiltinCatalog.memo, BuiltinCatalog.tasks]

    @Test func noteTaskAndClockCombinationsCanOwnPrimaryWithoutVoiceOrSpaces() {
        let frame = SurfaceRect(width: 1440, height: 832)
        let screens = [ScreenGeometry(id: "primary", frame: frame, visibleFrame: frame),
                       ScreenGeometry(id: "secondary", frame: frame, visibleFrame: frame)]
        for voice in [false, true] {
            for tray in [false, true] {
                var coordinator = MultiDisplayPresentationCoordinator()
                let active = coordinator.resolve(screens: screens, preferred: nil, settings: [:], demand: [:],
                    hidden: false, voice: voice, tray: tray, auxiliaryTools: true, spacesEnabled: false, uptime: 1)
                #expect(active.first?.content == .toolsOnly)
                #expect(active.last?.content == .hidden)
                let hidden = coordinator.resolve(screens: screens, preferred: nil, settings: [:], demand: [:],
                    hidden: true, voice: voice, tray: tray, auxiliaryTools: true, spacesEnabled: false, uptime: 2)
                #expect(hidden.allSatisfy { $0.content == .hidden })
                let blocked = coordinator.resolve(screens: screens, preferred: nil, settings: [:],
                    demand: ["primary": .init(blocked: true)], hidden: false, voice: voice, tray: tray,
                    auxiliaryTools: true, spacesEnabled: false, uptime: 3)
                #expect(blocked.first?.content == .hidden)
            }
        }
        var coordinator = MultiDisplayPresentationCoordinator()
        let withSpaces = coordinator.resolve(screens: screens, preferred: nil, settings: [:], demand: [:],
            hidden: false, voice: false, tray: false, auxiliaryTools: true, spacesEnabled: true, uptime: 1)
        #expect(withSpaces.first?.content == .full)
        let nothing = coordinator.resolve(screens: screens, preferred: nil, settings: [:], demand: [:],
            hidden: false, voice: false, tray: false, auxiliaryTools: false, spacesEnabled: false, uptime: 2)
        #expect(nothing.allSatisfy { $0.content == .hidden })
    }

    @Test func allToolsKeepReadableLyricsAndNinetySixPointWindowAreaOnLaptopHeight() {
        for order in [tools, Array(tools.reversed())] {
            let layout = LayoutComposer.compose(width: 240, height: 832, pinnedCount: 1, expanded: false,
                trayRows: 2, lyricsHeight: 192, toolOrder: order)
            #expect(layout.voice.height >= 80)
            #expect(layout.screenshots.height >= 76)
            #expect(layout.additionalTools[BuiltinCatalog.lyrics]?.height == 192)
            #expect((layout.additionalTools[BuiltinCatalog.memo]?.height ?? 0) >= 72)
            #expect((layout.additionalTools[BuiltinCatalog.tasks]?.height ?? 0) >= 72)
            #expect((layout.moduleRail?.height ?? 0) == 32)
            #expect(layout.windowArea.height >= 95.99)
            #expect(DisplaySettings().sizeForm(width: 240, height: 832, content: .full, voice: true, tray: true,
                trayRows: 2, lyricsHeight: 192, toolOrder: order, pinnedCount: 1) == .full)
            let regions = ([layout.voice, layout.screenshots, layout.windowArea] + Array(layout.additionalTools.values) +
                [layout.moduleRail].compactMap { $0 }).filter { $0.height > 0 }.sorted { $0.y < $1.y }
            for pair in zip(regions, regions.dropFirst()) {
                #expect(pair.0.y + pair.0.height <= pair.1.y + 0.001)
            }
            #expect((regions.last.map { $0.y + $0.height } ?? 0) <= 820.001)
        }
    }

    @Test func everyAvailableToolCombinationFitsWithoutGhostRegions() {
        for mask in 0..<(1 << tools.count) {
            let selected = tools.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            let hasVoice = selected.contains(BuiltinCatalog.voice)
            let hasTray = selected.contains(BuiltinCatalog.screenshots)
            let layout = LayoutComposer.compose(width: 240, height: 832, pinnedCount: 1, expanded: false,
                voiceEnabled: hasVoice, trayEnabled: hasTray, trayRows: 2, lyricsHeight: 192, toolOrder: selected)
            #expect((layout.voice.height > 0) == hasVoice)
            #expect((layout.screenshots.height > 0) == hasTray)
            for id in [BuiltinCatalog.lyrics, BuiltinCatalog.memo, BuiltinCatalog.tasks] {
                #expect(((layout.additionalTools[id]?.height ?? 0) > 0) == selected.contains(id))
            }
            #expect(layout.windowArea.height >= 95.99)
        }
    }

    @Test func shortNotebookOnlyPanelAdvertisesExpansionRatherThanClippingAnEditor() {
        let settings = DisplaySettings()
        let order = [BuiltinCatalog.memo, BuiltinCatalog.tasks]
        #expect(settings.sizeForm(width: 240, height: 120, content: .toolsOnly, voice: false, tray: false,
                                  toolOrder: order) == .compact)
        #expect(settings.sizeForm(width: 240, height: 220, content: .toolsOnly, voice: false, tray: false,
                                  toolOrder: order) == .full)
        #expect(settings.sizeForm(width: 100, height: 500, content: .toolsOnly, voice: false, tray: false,
                                  toolOrder: order) == .compact)
    }

    @Test func pressureDoesNotChangeSavedMetricsOrDuplicateRepeatedTools() {
        var settings = DisplaySettings()
        settings.measures[.voiceHeight] = Measure(200)
        let saved = settings
        let layout = LayoutComposer.compose(width: 240, height: 832, pinnedCount: 1, expanded: false,
            settings: settings, trayRows: 2, lyricsHeight: 192, toolOrder: tools)
        let repeated = LayoutComposer.compose(width: 240, height: 832, pinnedCount: 1, expanded: false,
            settings: settings, trayRows: 2, lyricsHeight: 192, toolOrder: tools + tools)
        #expect(layout == repeated)
        #expect(settings == saved)
        #expect(layout.voice.height < 200 && layout.voice.height >= 80)
    }
}
