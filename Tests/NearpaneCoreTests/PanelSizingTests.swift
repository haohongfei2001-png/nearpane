import Foundation
import Testing

@testable import NearpaneCore

struct PanelSizingTests {
    private let usable = SurfaceRect(x: -800, y: 0, width: 800, height: 1280)
    private var portrait: ScreenGeometry { ScreenGeometry(id: "portrait", frame: usable, visibleFrame: usable) }

    @Test func factoryUsesReferenceWidthAndNaturalToolHeights() throws {
        let settings = DisplaySettings()
        let frame = try #require(settings.panel(on: portrait, fallbackEdge: .right))
        #expect(frame == SurfaceRect(x: -200, y: 0, width: 200, height: 1280))
        let sections = settings.contentHeights(frame.height, content: .full, voice: true, tray: true)
        #expect(sections.voice == 144 && sections.tray == 76 && sections.spaces == 1040)
        #expect(settings.sizeForm(width: frame.width, height: frame.height, content: .full, voice: true, tray: true) == .full)
    }

    @Test func continuousAxesClampIndependentlyAndStayInsideUsableDisplay() throws {
        var settings = DisplaySettings()
        func panel() throws -> SurfaceRect { try #require(settings.panel(on: portrait, fallbackEdge: .right)) }
        let minimum = PanelSizeMetrics.iconSide + 2 * PanelSizeMetrics.glassInset
        settings.measures = [.panelWidth: .init(20.125), .panelHeight: .init(78.125, .percent)]
        var frame = try panel()
        #expect(frame.width == 20.125 && frame.height == 1000)
        settings.measures[.panelHeight] = .init(0)
        frame = try panel()
        #expect(frame.width == 20.125 && frame.height == minimum)
        settings.measures[.panelWidth] = .init(17000)
        frame = try panel()
        #expect(frame.width == usable.width && frame.height == minimum)
        settings.measures[.sideInset] = .init(16000)
        settings.measures[.topInset] = .init(16000)
        settings.measures[.bottomInset] = .init(16000)
        let fitted = try panel()
        #expect(fitted.width == minimum && fitted.height == minimum)
        #expect(usable.geometry.intersection(fitted.geometry) == fitted.geometry)
    }

    @Test func smallFormsUseTheAvailableAxesAndConfiguredModules() {
        var settings = DisplaySettings()
        func form(_ w: Double, _ h: Double) -> PanelSizeForm {
            settings.sizeForm(width: w, height: h, content: .full, voice: true, tray: true)
        }
        let minimum = PanelSizeMetrics.minimumSide
        #expect(form(minimum, minimum) == .icon)
        #expect(form(minimum, 1280) == .compact)
        #expect(form(780, minimum) == .compact)
        #expect(form(175.9, 1280) == .compact)
        #expect(form(176, 1280) == .full)
        settings.measures[.voiceButtonWidth] = .init(125)
        #expect(form(140, 1280) == .compact)
        #expect(form(240, 1280) == .full)
        #expect(settings.measures[.voiceButtonWidth] == .init(125))
        settings.measures = [.waveformSize: .init(155)]
        #expect(form(150, 1280) == .compact)
    }

    @Test func independentPerDisplayDimensionsAndInternalMetricsSurviveRestart() throws {
        var configuration = HostConfiguration()
        var primary = DisplaySettings(), other = DisplaySettings()
        primary.measures = [.panelWidth: .init(17000), .panelHeight: .init(30.125, .percent), .voiceHeight: .init(178)]
        other.measures = [.panelWidth: .init(36.5), .panelHeight: .init(82, .percent), .cellWidth: .init(41)]
        configuration.displays = ["primary": primary, "other": other]
        let saved = try JSONEncoder().encode(configuration.validated())
        let decoded = try JSONDecoder().decode(HostConfiguration.self, from: saved).validated()
        #expect(decoded.displays == configuration.displays)
        other.measures[.cellWidth] = .init(17000)
        configuration.displays["other"] = other
        #expect(throws: ConfigurationError.invalid) { try configuration.validated() }
    }

    @Test func voiceControlsFoldBeforeTheirGlassHitAreasOverlap() {
        var settings = DisplaySettings()
        func form(_ width: Double) -> PanelSizeForm {
            settings.sizeForm(width:width,height:1280,content:.voiceOnly,voice:true,tray:false)
        }
        // 16 pt text padding + 32 pt voice + 26 pt copy + two 8 pt gaps,
        // inside the card's two 4%-width insets. The factory 100 pt panel fits.
        #expect(form(121.5) == .compact)
        #expect(form(122) == .full)
        #expect(form(176) == .full)
        settings.measures[.voiceButtonHeight] = .init(40)
        #expect(form(135.5) == .compact)
        #expect(form(136) == .full)
        // A larger copy glyph must still fit; none of these checks change the
        // requested type size or stored control dimensions to squeeze it in.
        settings.measures[.copySize] = .init(48)
        #expect(form(143.5) == .compact)
        #expect(form(144) == .full)
        #expect(settings.measures[.voiceButtonHeight] == .init(40))
        #expect(settings.measures[.copySize] == .init(48))
    }

    @Test func voiceCardInsetsCannotConsumeTheLastReadableLine() {
        var settings = DisplaySettings()
        func form(_ height: Double = 1280) -> PanelSizeForm {
            settings.sizeForm(width:200,height:height,content:.voiceOnly,voice:true,tray:false,
                              referenceHeight:1280)
        }
        // 63 pt previously passed the control/line check, but leaves only 55 pt
        // inside the card. Inspect the actual slot, not the panel's tall frame.
        settings.measures[.voiceHeight] = .init(63)
        #expect(form() == .compact)
        settings.measures[.voiceHeight] = .init(70.5)
        #expect(form() == .compact)
        settings.measures[.voiceHeight] = .init(71)
        #expect(form() == .full)
        // A saved sufficient section still cannot fit when its actual panel is
        // shorter. It must fold without changing the saved section height.
        #expect(form(63) == .compact)
        #expect(settings.measures[.voiceHeight] == .init(71))
    }

    @Test func relativeTextFoldsBeforeItBecomesUnreadableAndKeepsItsSavedScale() {
        var settings = DisplaySettings()
        settings.measures[.textSize] = .init(5, .percent)
        settings.measures[.voiceHeight] = .init(24, .percent)
        func form(_ height: Double, expanded: Bool = false) -> PanelSizeForm {
            settings.sizeForm(width: 200, height: height, content: .full, voice: true, tray: true,
                              temporarilyExpanded: expanded)
        }
        #expect(form(1280) == .full)
        #expect(form(450) == .compact)
        #expect(settings.readableFontSize(.textSize, in: 101.25) == DisplayMetric.textSize.factory.value)
        #expect(form(450, expanded: true) == .full)
        #expect(settings.measures[.textSize] == Measure(5, .percent))

        settings.measures = [.labelSize: .init(1, .percent), .spacesHeight: .init(100)]
        #expect(settings.referenceExtent(for: .labelSize, screen: portrait, primary: true) == 1280)
        #expect(form(1280) == .full) // 12.8 pt on the panel reference, independent of the 100 pt Spaces section.
        #expect(form(450) == .compact)
        settings.measures[.labelSize] = .init(0.01, .percent)
        #expect(settings.readableFontSize(.labelSize, in: 1280) == DisplayMetric.labelSize.factory.value)
        #expect(form(1280, expanded: true) == .full)
        #expect(settings.measures[.labelSize] == Measure(0.01, .percent))
        settings.measures[.labelSize] = .init(9)
        #expect(settings.readableFontSize(.labelSize, in: 400) == 9)
        #expect(form(450) == .full)
    }

    @Test func dockedReservesTheEffectiveCommittedWidthAndHonorsAnIndependentOverride() throws {
        var settings = DisplaySettings()
        func work() throws -> SurfaceRect {
            try DesktopWorkArea(display: portrait.id, screen: usable, usable: usable, primary: false,
                                settings: settings, fallbackEdge: .right).ordinary
        }
        settings.measures[.panelWidth] = .init(0.5)
        #expect(try work().width == usable.width - PanelSizeMetrics.minimumSide)
        settings.measures[.panelHeight] = .init(64)
        #expect(try work().width == usable.width - PanelSizeMetrics.minimumSide)
        settings.measures[.reservedWidth] = .init(6)
        settings.measures[.panelWidth] = .init(340)
        #expect(throws: DesktopWorkArea.ReservationError.narrowerThanPanel) { try work() }
        #expect(settings.measures[.reservedWidth] == .init(6))
        settings.measures[.reservedWidth] = .init(360)
        #expect(try work().width == 440)
        settings.measures[.panelWidth] = .init(200)
        #expect(try work().width == 440)
        settings.placement = .floating
        #expect(try work() == usable)
        settings.placement = .docked
        settings.measures[.reservedWidth] = nil
        settings.measures[.panelWidth] = .init(100, .percent)
        #expect(throws: WorkspaceFailure.minimumSize) { try work() }
    }

    @Test func ordinaryWindowsCannotEnterTheSideInsetOfTheCommittedPanel() throws {
        var settings = DisplaySettings()
        settings.measures[.sideInset] = .init(3.125, .percent)
        for edge in [SurfaceEdge.left, .right] {
            settings.edge = edge
            let panel = try #require(settings.panel(on: portrait, fallbackEdge: .right))
            let work = try DesktopWorkArea(display: portrait.id, screen: usable, usable: usable, primary: false,
                                           settings: settings, fallbackEdge: .right).ordinary
            #expect(work.width == 575 && work.geometry.intersection(panel.geometry) == nil)
            #expect(edge == .left ? work.x == panel.geometry.maxX : work.geometry.maxX == panel.x)
        }
        settings.measures[.reservedWidth] = .init(124.75)
        #expect(throws: DesktopWorkArea.ReservationError.narrowerThanPanel) {
            try DesktopWorkArea(display: portrait.id, screen: usable, usable: usable, primary: false,
                                settings: settings, fallbackEdge: .right)
        }
        settings.measures[.reservedWidth] = nil
        settings.measures[.sideInset] = .init(16000)
        #expect(throws: WorkspaceFailure.minimumSize) {
            try DesktopWorkArea(display: portrait.id, screen: usable, usable: usable, primary: false,
                                settings: settings, fallbackEdge: .right)
        }
    }
}
