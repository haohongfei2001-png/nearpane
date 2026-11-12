import Foundation
#if canImport(SaytileVoiceUI)
import SaytileVoiceUI
#endif

public enum MeasureUnit: String, Codable, CaseIterable, Sendable {
    case points = "pt"
    case percent = "%"
}
public struct Measure: Codable, Equatable, Sendable {
    public var value: Double, unit: MeasureUnit
    public init(_ value: Double, _ unit: MeasureUnit = .points) {
        self.value = value
        self.unit = unit
    }
    public func points(in extent: Double) -> Double { unit == .points ? value : extent * value / 100 }
    public var step: Double { unit == .points ? 0.5 : 0.1 }
    public var valid: Bool { value.isFinite && value >= 0 && value <= (unit == .percent ? 100 : 16384) }
    public var validPanelExtent: Bool { value.isFinite && value >= 0 && (unit == .points || value <= 100) }
}

public enum DisplayMetric: String, Codable, CaseIterable, Sendable {
    case panelWidth, panelHeight, reservedWidth, sideInset, topInset, bottomInset, verticalOffset
    case voiceHeight, trayHeight, spacesHeight, sectionGap
    case textHeight, textPadding, textSize, lineGap, voiceButtonWidth, voiceButtonHeight, copySize, buttonGap, waveformSize
    case cellWidth, cellHeight, columnGap, rowGap, trayPadding, trayMenuHeight, trayButtonSize
    case spaceRowHeight, spaceRowGap, desktopWidth, desktopHeight, spacePadding, scrollHeight
    case cornerRadius, borderWidth, iconSize, labelSize, hitSize
    case railHeight, railButtonWidth, modulePadding, moduleHeight

    public var factory: Measure {
        switch self {
        case .panelWidth, .reservedWidth: .init(12.5, .percent)
        case .panelHeight, .textHeight, .desktopWidth, .desktopHeight, .scrollHeight: .init(100, .percent)
        case .voiceHeight: .init(22.5, .percent)
        case .trayHeight: .init(15, .percent)
        case .spacesHeight: .init(62.5, .percent)
        case .cellHeight, .cellWidth, .trayMenuHeight: .init(50, .percent)
        case .moduleHeight: .init(68, .percent)
        case .spaceRowHeight: .init(100, .percent)
        case .textPadding, .buttonGap: .init(8)
        case .textSize, .copySize, .iconSize: .init(13)
        case .waveformSize: .init(28)
        case .lineGap: .init(2)
        case .voiceButtonWidth, .railHeight: .init(32)
        case .voiceButtonHeight: .init(26)
        case .columnGap, .rowGap, .spacePadding: .init(4)
        case .spaceRowGap: .init(6)
        case .trayPadding: .init(5)
        case .trayButtonSize: .init(18)
        case .cornerRadius: .init(5)
        case .borderWidth: .init(0.8)
        case .labelSize: .init(10)
        case .hitSize: .init(18)
        case .railButtonWidth: .init(28)
        case .modulePadding: .init(12)
        default: .init(0)
        }
    }
    public var horizontal: Bool {
        switch self {
        case .panelWidth, .reservedWidth, .sideInset, .voiceButtonWidth, .cellWidth, .columnGap, .desktopWidth,
            .textPadding, .trayPadding, .spacePadding, .modulePadding, .railButtonWidth, .buttonGap:
            true
        default: false
        }
    }
}

public enum SpacePanelPlacement: String, Codable, CaseIterable, Sendable { case docked, floating }
public enum SecondaryPolicy: String, Codable, CaseIterable, Sendable { case onDemand, contextualAuto, pinned }
public enum PanelAnchor: String, Codable, CaseIterable, Sendable { case top, center, bottom }
public enum PanelContent: Equatable, Sendable { case full, compact, voiceOnly, trayOnly, spacesOnly, hidden }

public enum PanelSizeForm: Equatable, Sendable { case full, compact, icon }

/// Logical points. The icon view and the window clamp use the same small application icon and glass inset.
public enum PanelSizeMetrics {
    public static let iconSide = 16.0
    public static let glassInset = 2.0
    public static var minimumSide: Double { iconSide + 2 * glassInset }
}

public struct PanelPosition: Codable, Equatable, Sendable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
public struct DisplaySettings: Codable, Equatable, Sendable {
    public var floatingPosition: PanelPosition?
    public var fullscreenTools = FullscreenToolSettings()
    public var toolAnchor: FloatingToolSurface?
    public var placement: SpacePanelPlacement = .docked
    public var policy: SecondaryPolicy = .onDemand
    public var showsWindowContents = false
    public var spacesDismissed = false
    public var edge: SurfaceEdge?
    public var anchor: PanelAnchor = .top
    public var measures: [DisplayMetric: Measure] = [:]
    public init() {}
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        floatingPosition = try values.decodeIfPresent(PanelPosition.self, forKey: .floatingPosition)
        fullscreenTools = try values.decodeIfPresent(FullscreenToolSettings.self, forKey: .fullscreenTools) ?? .init()
        toolAnchor = try values.decodeIfPresent(FloatingToolSurface.self, forKey: .toolAnchor)
        placement = try values.decodeIfPresent(SpacePanelPlacement.self, forKey: .placement) ?? .docked
        showsWindowContents = try values.decodeIfPresent(Bool.self, forKey: .showsWindowContents) ?? false
        spacesDismissed = try values.decodeIfPresent(Bool.self, forKey: .spacesDismissed) ?? false
        policy = try values.decodeIfPresent(SecondaryPolicy.self, forKey: .policy) ?? .onDemand
        edge = try values.decodeIfPresent(SurfaceEdge.self, forKey: .edge)
        anchor = try values.decodeIfPresent(PanelAnchor.self, forKey: .anchor) ?? .top
        measures = try values.decodeIfPresent([DisplayMetric: Measure].self, forKey: .measures) ?? [:]
    }
    public func points(_ key: DisplayMetric, in extent: Double) -> Double {
        (measures[key] ?? key.factory).points(in: max(0, extent))
    }

    private func extentRange(_ extent: Double, inset: Double) -> ClosedRange<Double> {
        let safe = extent.isFinite ? max(0, extent) : 0
        let minimum = min(PanelSizeMetrics.minimumSide, safe)
        return minimum...max(minimum, safe - inset)
    }

    public func panelExtentRange(for axis: DisplayMetric, on screen: ScreenGeometry) -> ClosedRange<Double> {
        let safe = screen.visibleFrame
        switch axis {
        case .panelWidth:
            return extentRange(safe.width, inset: points(.sideInset, in: safe.width))
        case .panelHeight:
            return extentRange(safe.height, inset: points(.topInset, in: safe.height) + points(.bottomInset, in: safe.height))
        default:
            preconditionFailure("Expected panelWidth or panelHeight")
        }
    }

    func committedPanelWidth(in available: Double) -> Double {
        let range = extentRange(available, inset: points(.sideInset, in: available))
        return min(range.upperBound, max(range.lowerBound, points(.panelWidth, in: available)))
    }
    public func panel(
        on screen: ScreenGeometry, fallbackEdge: SurfaceEdge, heightFraction: Double = 1, floating: Bool = false
    ) -> SurfaceRect? {
        let f = screen.visibleFrame
        guard f.geometry.isValid, heightFraction.isFinite, heightFraction > 0 else { return nil }
        let w = committedPanelWidth(in: f.width)
        let side = min(points(.sideInset, in: f.width), f.width - w)
        let heights = panelExtentRange(for: .panelHeight, on: screen)
        let available = heights.upperBound
        let top = min(points(.topInset, in: f.height), f.height - available)
        let full = min(available, max(heights.lowerBound, points(.panelHeight, in: f.height)))
        let h = max(heights.lowerBound, min(full, full * heightFraction))
        let spare = available - h
        let fromTop = min(
            spare, (anchor == .center ? spare / 2 : anchor == .bottom ? spare : 0) + points(.verticalOffset, in: f.height))
        if floating, placement == .floating, let p = floatingPosition {
            return .init(
                x: f.x + min(max(0, p.x), f.width - w), y: f.y + min(max(0, p.y), f.height - h), width: w, height: h)
        }
        // NSScreen uses bottom-left coordinates. Desktop work areas use Quartz top-left coordinates.
        return .init(
            x: (edge ?? fallbackEdge) == .left ? f.x + side : f.x + f.width - side - w,
            y: f.y + f.height - top - fromTop - h, width: w, height: h)
    }
}

public struct DisplayDemand: Equatable, Sendable {
    public var spaces, windows: Int
    public var blocked: Bool, complete: Bool
    public init(spaces: Int = 0, windows: Int = 0, blocked: Bool = false, complete: Bool = false) {
        self.spaces = spaces
        self.windows = windows
        self.blocked = blocked
        self.complete = complete
    }
    public var multiple: Bool { spaces >= 2 || windows >= 2 }
}

public struct DisplaySurfacePlan: Equatable, Sendable {
    public let id: String, primary: Bool, content: PanelContent
    public init(id: String, primary: Bool, content: PanelContent) {
        self.id = id; self.primary = primary; self.content = content
    }
}

public struct MultiDisplayPresentationCoordinator {
    private var requested = Set<String>()
    private var suppressed = Set<String>()
    private var lastSettings: [String: DisplaySettings] = [:]
    private var lastMultiple: [String: Double] = [:]
    public init() {}
    public mutating func request(_ id: String) {
        suppressed.remove(id)
        requested.insert(id)
    }
    public mutating func dismiss(_ id: String) {
        suppressed.insert(id)
        requested.remove(id)
    }
    /// An invalid second record with the same UUID still makes that identity ambiguous.
    public static func identifiedScreens(_ screens: [ScreenGeometry]) -> [ScreenGeometry] {
        let records = Dictionary(grouping: screens, by: \.id)
        return screens.filter {
            !$0.id.isEmpty && $0.id != "unidentified-display" && records[$0.id]?.count == 1 &&
                $0.rotationDegrees.isFinite && $0.backingScale.isFinite && $0.backingScale > 0 && $0.visibleFrame.geometry.isValid &&
                $0.frame.geometry.intersection($0.visibleFrame.geometry) == $0.visibleFrame.geometry
        }
    }

    public mutating func resolve(
        screens: [ScreenGeometry], preferred: String?, settings: [String: DisplaySettings],
        demand: [String: DisplayDemand], hidden: Bool, voice: Bool, tray: Bool,
        spacesEnabled: Bool, uptime: Double
    ) -> [DisplaySurfacePlan] {
        let ids = Self.identifiedScreens(screens).map(\.id)
        suppressed.formIntersection(ids)
        for id in ids where (lastSettings[id]?.policy ?? .onDemand) != (settings[id]?.policy ?? .onDemand) { suppressed.remove(id) }
        lastSettings = settings
        requested.formIntersection(ids)
        lastMultiple = lastMultiple.filter { ids.contains($0.key) }
        guard let primary = ids.first(where: { $0 == preferred }) ?? ids.first else { return [] }
        requested.remove(primary)
        return ids.map { id in
            let context = demand[id] ?? .init()
            let isPrimary = id == primary
            let dismissed = suppressed.contains(id) || settings[id]?.spacesDismissed == true
            var content: PanelContent = .hidden
            if hidden || context.blocked {
                requested.remove(id)
                lastMultiple[id] = nil
            } else if isPrimary {
                let spaces = spacesEnabled && !dismissed && (context.multiple || !context.complete)
                if spaces {
                    content = voice || tray ? .full : .spacesOnly
                } else if voice && tray {
                    content = .compact
                } else if voice {
                    content = .voiceOnly
                } else if tray {
                    content = .trayOnly
                }
            } else if spacesEnabled && !dismissed {
                if context.multiple { lastMultiple[id] = uptime } else { requested.remove(id) }
                switch settings[id]?.policy ?? .onDemand {
                case .onDemand: if requested.contains(id) && context.multiple { content = .spacesOnly }
                case .contextualAuto:
                    if context.multiple
                        || (context.complete && lastMultiple[id].map { uptime >= $0 && uptime - $0 < 2 } == true)
                    {
                        content = .spacesOnly
                    }
                case .pinned: content = .spacesOnly
                }
            }
            return .init(id: id, primary: isPrimary, content: content)
        }
    }
}

extension DisplaySettings {
    /// Retain system typography when unset and preserve explicit point sizes. A percentage
    /// cannot reduce the visible transcript or Space caption below its factory text token.
    public func readableFontSize(_ metric: DisplayMetric, in extent: Double) -> Double? {
        guard let choice = measures[metric] else { return nil }
        let requested = choice.points(in: extent)
        return choice.unit == .percent ? max(metric.factory.value, requested) : requested
    }

    /// Fit ordinary module controls at their configured sizes. Condensing the panel never changes their stored metrics.
    public func sizeForm(width: Double, height: Double, content: PanelContent, voice: Bool, tray: Bool,
                         referenceHeight: Double? = nil, temporarilyExpanded: Bool = false) -> PanelSizeForm {
        let minimum = PanelSizeMetrics.minimumSide
        let compactSpan = 2 * minimum + 2 * PanelSizeMetrics.glassInset
        guard width.isFinite, height.isFinite, min(width, height) >= minimum,
              max(width, height) >= compactSpan else { return .icon }
        let sections = contentHeights(referenceHeight ?? height, width: width, content: content, voice: voice, tray: tray)
        if voice && [.full, .compact, .voiceOnly].contains(content) {
            // Legacy relative text preferences refer to the configured voice height.
            // The actual default card and controls scale down together on a narrow rail.
            let textBasis = points(.voiceHeight, in: referenceHeight ?? height)
            let requestedFont = points(.textSize, in: textBasis)
            let font = readableFontSize(.textSize, in: textBasis) ?? requestedFont
            if !temporarilyExpanded && font > requestedFont { return .compact }
            let scale = min(1, max(0.40, width / 240))
            func control(_ key: DisplayMetric, _ extent: Double) -> Double {
                measures[key]?.points(in: extent) ?? key.factory.points(in: extent) * scale
            }
            let pad = control(.textPadding, width)
            let waveformWidth = control(.waveformSize, width)
            let copySize = control(.copySize, sections.voice)
            let buttonHeight = max(control(.voiceButtonHeight, sections.voice), waveformWidth * 24 / 28, copySize)
            let rowWidth = max(control(.voiceButtonWidth, width), waveformWidth) + copySize + 2 * control(.buttonGap, width)
            let railSides = 2 * min(width / 4, width * 15 / 325)
            let railEnds = min(width * 25 / 325, sections.voice / 4) + min(width * 8 / 325, sections.voice / 8)
            if width - railSides < 2 * pad + max(rowWidth, 2 * font)
                || min(height, sections.voice) - railEnds < 2 * pad + buttonHeight + font * 1.3 + 4 * scale { return .compact }
        }
        if tray && [.full, .compact, .trayOnly].contains(content) {
            let pad = points(.trayPadding, in: width)
            let glyph = points(.trayButtonSize, in: sections.tray)
            if width < 2 * pad + 2 * glyph + points(.columnGap, in: width)
                || min(height, sections.tray) < 2 * pad + 2 * glyph + points(.rowGap, in: sections.tray) {
                return .compact
            }
        }
        if content == .full || content == .spacesOnly {
            let pad = points(.spacePadding, in: width)
            let labelBasis = referenceHeight ?? height
            let requestedLabel = points(.labelSize, in: labelBasis)
            let label = readableFontSize(.labelSize, in: labelBasis) ?? requestedLabel
            if !temporarilyExpanded && label > requestedLabel { return .compact }
            if width < 2 * pad + 4 * label || min(height, sections.spaces) < 2 * pad + label * 1.3 + minimum {
                return .compact
            }
        }
        return .full
    }

    public func contentHeights(_ height: Double, width: Double, content: PanelContent, voice: Bool, tray: Bool) -> (
        voice: Double, tray: Double, spaces: Double, gap: Double
    ) {
        let requested = requestedSectionHeights(height: height, width: width, content: content, voice: voice, tray: tray)
        let total = requested.voice + requested.tray + requested.spaces
        let scale = min(1, requested.available / max(Double.leastNormalMagnitude, total))
        return (requested.voice * scale, requested.tray * scale, requested.spaces * scale, requested.gap)
    }

    public func requestedSectionHeights(height: Double, width: Double, content: PanelContent, voice: Bool, tray: Bool)
        -> (voice: Double, tray: Double, spaces: Double, gap: Double, available: Double) {
        let h = max(0, height)
        let showVoice = voice && [.full, .compact, .voiceOnly].contains(content)
        let showTray = tray && [.full, .compact, .trayOnly].contains(content)
        let showSpaces = content == .full || content == .spacesOnly
        let gaps = max(0, [showVoice, showTray, showSpaces].filter { $0 }.count - 1)
        let gap = min(points(.sectionGap, in: h), h / Double(max(1, gaps + 1)))
        #if canImport(SaytileVoiceUI)
        // NSWindow rounds the standalone factory slot to whole logical points.
        // Match that host boundary before SwiftUI lays out the embedded card.
        let factoryVoice = VoiceRailMetrics.factoryHeight(width: width, visibleHeight: h).rounded()
        #else
        let factoryVoice = min(h * 0.225, width * 173 / 325).rounded()
        #endif
        let voiceHeight = showVoice ? measures[.voiceHeight]?.points(in: h) ?? factoryVoice : 0
        let trayHeight = showTray ? measures[.trayHeight]?.points(in: h) ?? min(h * 0.225, width * 195 / 325) : 0
        let remaining = max(0, h - voiceHeight - trayHeight - Double(gaps) * gap)
        let spaceHeight = showSpaces ? measures[.spacesHeight]?.points(in: h) ?? remaining : 0
        return (voiceHeight, trayHeight, spaceHeight, gap, max(0, h - Double(gaps) * gap))
    }
}

extension DisplaySettings {
    /// Same logical-point bases used by the panel, its sections and the two-column tray.
    public func referenceExtent(for key: DisplayMetric, screen: ScreenGeometry, primary: Bool) -> Double {
        let safe = screen.visibleFrame
        let panel = panel(on: screen, fallbackEdge: .right) ?? safe
        let sizes = contentHeights(panel.height, width: panel.width, content: primary ? .full : .spacesOnly, voice: primary, tray: primary)
        switch key {
        case .panelWidth, .reservedWidth, .sideInset: return safe.width
        case .panelHeight, .topInset, .bottomInset, .verticalOffset: return safe.height
        case .voiceHeight, .trayHeight, .spacesHeight, .sectionGap, .railHeight, .labelSize: return panel.height
        case .textHeight, .textSize, .lineGap, .voiceButtonHeight, .copySize: return sizes.voice
        case .columnGap: return max(0, panel.width - 2 * points(.trayPadding, in: panel.width))
        case .rowGap: return max(0, sizes.tray - 2 * points(.trayPadding, in: panel.width))
        case .cellWidth:
            let width = referenceExtent(for: .columnGap, screen: screen, primary: primary)
            return max(0, width - min(points(.columnGap, in: width), width / 8))
        case .cellHeight, .trayMenuHeight:
            let height = referenceExtent(for: .rowGap, screen: screen, primary: primary)
            return max(0, height - min(points(.rowGap, in: height), height / 8))
        case .trayButtonSize: return sizes.tray
        case .spaceRowHeight, .spaceRowGap:
            let viewport = min(sizes.spaces, points(.scrollHeight, in: sizes.spaces))
            return min(viewport, points(.desktopHeight, in: viewport))
        case .desktopHeight: return min(sizes.spaces, points(.scrollHeight, in: sizes.spaces))
        case .scrollHeight, .moduleHeight: return sizes.spaces
        default: return panel.width
        }
    }
}
