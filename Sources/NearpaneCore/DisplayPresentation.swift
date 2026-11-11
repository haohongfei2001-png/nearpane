import Foundation

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
    public var toolAnchor: FloatingToolSurface?
    public var placement: SpacePanelPlacement = .docked
    public var policy: SecondaryPolicy = .onDemand
    public var spacesDismissed = false
    public var edge: SurfaceEdge?
    public var anchor: PanelAnchor = .top
    public var measures: [DisplayMetric: Measure] = [:]
    public init() {}
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        floatingPosition = try values.decodeIfPresent(PanelPosition.self, forKey: .floatingPosition)
        toolAnchor = try values.decodeIfPresent(FloatingToolSurface.self, forKey: .toolAnchor)
        placement = try values.decodeIfPresent(SpacePanelPlacement.self, forKey: .placement) ?? .docked
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
    public mutating func resolve(
        screens: [ScreenGeometry], preferred: String?, settings: [String: DisplaySettings],
        demand: [String: DisplayDemand], hidden: Bool, voice: Bool, tray: Bool,
        spacesEnabled: Bool, uptime: Double
    ) -> [DisplaySurfacePlan] {
        let usable = screens.filter { $0.frame.geometry.isValid && $0.visibleFrame.geometry.isValid && !$0.id.isEmpty }
        let counts = Dictionary(grouping: usable, by: \.id)
        let ids = usable.map(\.id).filter { counts[$0]?.count == 1 }
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
        let sections = contentHeights(referenceHeight ?? height, content: content, voice: voice, tray: tray)
        if voice && [.full, .compact, .voiceOnly].contains(content) {
            let pad = points(.textPadding, in: width)
            let requestedFont = points(.textSize, in: sections.voice)
            let font = readableFontSize(.textSize, in: sections.voice) ?? requestedFont
            if !temporarilyExpanded && font > requestedFont { return .compact }
            let waveformWidth = points(.waveformSize, in: width)
            let copySize = points(.copySize, in: sections.voice)
            let buttonHeight = max(points(.voiceButtonHeight, in: sections.voice), waveformWidth * 24 / 28, copySize)
            let rowWidth = max(points(.voiceButtonWidth, in: width), waveformWidth) + copySize
                + 2 * points(.buttonGap, in: width)
            if width < 2 * pad + max(rowWidth, 2 * font)
                || min(height, sections.voice) < 2 * pad + buttonHeight + font * 1.3 + 4 { return .compact }
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

    public func contentHeights(_ height: Double, content: PanelContent, voice: Bool, tray: Bool) -> (
        voice: Double, tray: Double, spaces: Double, gap: Double
    ) {
        let h = max(0, height)
        let showVoice = voice && [.full, .compact, .voiceOnly].contains(content)
        let showTray = tray && [.full, .compact, .trayOnly].contains(content)
        let showSpaces = content == .full || content == .spacesOnly
        let gaps = max(0, [showVoice, showTray, showSpaces].filter { $0 }.count - 1)
        let gap = min(points(.sectionGap, in: h), h / Double(max(1, gaps + 1)))
        let amounts = [
            showVoice ? points(.voiceHeight, in: h) : 0, showTray ? points(.trayHeight, in: h) : 0,
            showSpaces ? (content == .spacesOnly && measures[.spacesHeight] == nil ? h : points(.spacesHeight, in: h)) : 0,
        ]
        let scale = min(1, max(0, h - Double(gaps) * gap) / max(Double.leastNormalMagnitude, amounts.reduce(0, +)))
        return (amounts[0] * scale, amounts[1] * scale, amounts[2] * scale, gap)
    }
}

extension DisplaySettings {
    /// Same logical-point bases used by the panel, its sections and the two-column tray.
    public func referenceExtent(for key: DisplayMetric, screen: ScreenGeometry, primary: Bool) -> Double {
        let safe = screen.visibleFrame
        let panel = panel(on: screen, fallbackEdge: .right) ?? safe
        let sizes = contentHeights(panel.height, content: primary ? .full : .spacesOnly, voice: primary, tray: primary)
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
