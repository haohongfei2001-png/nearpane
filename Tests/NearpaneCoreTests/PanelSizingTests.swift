import Foundation
import Testing

@testable import NearpaneCore

struct PanelSizingTests {
    private let usable = SurfaceRect(x: -800, y: 0, width: 800, height: 1280)
    private var portrait: ScreenGeometry { ScreenGeometry(id: "portrait", frame: usable, visibleFrame: usable) }

    @Test func factoryKeepsPanelAndModuleProportions() throws {
        let settings = DisplaySettings()
        let frame = try #require(settings.panel(on: portrait, fallbackEdge: .right))
        #expect(frame == SurfaceRect(x: -100, y: 0, width: 100, height: 1280))
        let sections = settings.contentHeights(frame.height, content: .full, voice: true, tray: true)
        #expect(sections.voice == 288 && sections.tray == 192 && sections.spaces == 800)
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
        #expect(form(100, 1280) == .full)
        settings.measures[.voiceButtonWidth] = .init(125)
        #expect(form(100, 1280) == .compact)
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

    @Test func relativeTextFoldsBeforeItBecomesUnreadableAndKeepsItsSavedScale() {
        var settings = DisplaySettings()
        settings.measures[.textSize] = .init(5, .percent)
        func form(_ height: Double, expanded: Bool = false) -> PanelSizeForm {
            settings.sizeForm(width: 100, height: height, content: .full, voice: true, tray: true,
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
        #expect(try work().width == 794)
        settings.placement = .floating
        #expect(try work() == usable)
        settings.placement = .docked
        settings.measures[.reservedWidth] = nil
        settings.measures[.panelWidth] = .init(100, .percent)
        #expect(throws: WorkspaceFailure.minimumSize) { try work() }
    }
}
