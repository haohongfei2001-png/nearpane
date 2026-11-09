import Foundation

public enum MeasureUnit: String, Codable, CaseIterable, Sendable { case points = "pt", percent = "%" }
public struct Measure: Codable, Equatable, Sendable {
    public var value: Double, unit: MeasureUnit
    public init(_ value: Double, _ unit: MeasureUnit = .points) { self.value = value; self.unit = unit }
    public func points(in extent: Double) -> Double { unit == .points ? value : extent * value / 100 }
    public var step: Double { unit == .points ? 0.5 : 0.1 }
    public var valid: Bool { value.isFinite && value >= 0 && value <= (unit == .percent ? 100 : 16384) }
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
             .textPadding, .trayPadding, .spacePadding, .modulePadding, .railButtonWidth, .buttonGap: true
        default: false
        }
    }
}

public enum SecondaryPolicy: String, Codable, CaseIterable, Sendable { case onDemand, contextualAuto, pinned }
public enum PanelAnchor: String, Codable, CaseIterable, Sendable { case top, center, bottom }
public enum PanelContent: Equatable, Sendable { case full, compact, voiceOnly, trayOnly, spacesOnly, hidden }

public struct DisplaySettings: Codable, Equatable, Sendable {
    public var policy: SecondaryPolicy = .onDemand
    public var edge: SurfaceEdge?
    public var anchor: PanelAnchor = .top
    public var measures: [DisplayMetric: Measure] = [:]
    public init() {}
    public func points(_ key: DisplayMetric, in extent: Double) -> Double {
        (measures[key] ?? key.factory).points(in: max(0, extent))
    }
    public func panel(on screen: ScreenGeometry, fallbackEdge: SurfaceEdge, heightFraction: Double = 1) -> SurfaceRect? {
        let f = screen.visibleFrame
        guard f.geometry.isValid, heightFraction.isFinite, heightFraction > 0 else { return nil }
        let side = min(points(.sideInset, in: f.width), f.width)
        let top = points(.topInset, in: f.height), bottom = points(.bottomInset, in: f.height)
        let available = f.height - top - bottom
        let w = min(points(.panelWidth, in: f.width), f.width - side)
        let full = min(points(.panelHeight, in: f.height), available)
        let h = min(full, full * heightFraction)
        guard w > 0, h > 0 else { return nil }
        let spare = available - h
        let fromTop = min(spare, (anchor == .center ? spare / 2 : anchor == .bottom ? spare : 0) + points(.verticalOffset, in: f.height))
        // NSScreen uses bottom-left coordinates. Desktop work areas use Quartz top-left coordinates.
        return .init(x: (edge ?? fallbackEdge) == .left ? f.x + side : f.x + f.width - side - w,
                     y: f.y + f.height - top - fromTop - h, width: w, height: h)
    }
}

public struct DisplayDemand: Equatable, Sendable {
    public var spaces, windows: Int
    public var blocked: Bool, complete: Bool
    public init(spaces: Int = 0, windows: Int = 0, blocked: Bool = false, complete: Bool = false) {
        self.spaces = spaces; self.windows = windows; self.blocked = blocked; self.complete = complete
    }
    public var multiple: Bool { spaces >= 2 || windows >= 2 }
}

public struct DisplaySurfacePlan: Equatable, Sendable {
    public let id: String, primary: Bool, content: PanelContent
}

public struct MultiDisplayPresentationCoordinator {
    private var requested = Set<String>()
    private var lastMultiple: [String: Double] = [:]
    public init() {}
    public mutating func request(_ id: String) { requested.insert(id) }
    public mutating func dismiss(_ id: String) { requested.remove(id) }
    public mutating func resolve(screens: [ScreenGeometry], preferred: String?, settings: [String: DisplaySettings],
                                 demand: [String: DisplayDemand], hidden: Bool, voice: Bool, tray: Bool,
                                 spacesEnabled: Bool, uptime: Double) -> [DisplaySurfacePlan] {
        var seen = Set<String>()
        let ids = screens.filter { $0.visibleFrame.geometry.isValid && seen.insert($0.id).inserted }.map(\.id)
        requested.formIntersection(ids)
        lastMultiple = lastMultiple.filter { ids.contains($0.key) }
        guard let primary = ids.first(where: { $0 == preferred }) ?? ids.first else { return [] }
        requested.remove(primary)
        return ids.map { id in
            let context = demand[id] ?? .init()
            let isPrimary = id == primary
            var content: PanelContent = .hidden
            if hidden || context.blocked { requested.remove(id); lastMultiple[id] = nil }
            else if isPrimary {
                let spaces = spacesEnabled && (context.multiple || !context.complete)
                if spaces { content = voice || tray ? .full : .spacesOnly }
                else if voice && tray { content = .compact }
                else if voice { content = .voiceOnly }
                else if tray { content = .trayOnly }
            } else if spacesEnabled {
                if context.multiple { lastMultiple[id] = uptime }
                else { requested.remove(id) }
                switch settings[id]?.policy ?? .onDemand {
                case .onDemand: if requested.contains(id) && context.multiple { content = .spacesOnly }
                case .contextualAuto:
                    if context.multiple || (context.complete && lastMultiple[id].map { uptime >= $0 && uptime - $0 < 2 } == true) {
                        content = .spacesOnly
                    }
                case .pinned: content = .spacesOnly
                }
            }
            return .init(id: id, primary: isPrimary, content: content)
        }
    }
}

public extension DisplaySettings {
    func contentHeights(_ height: Double, content: PanelContent, voice: Bool, tray: Bool) -> (voice: Double, tray: Double, spaces: Double, gap: Double) {
        let h = max(0, height)
        let showVoice = voice && [.full,.compact,.voiceOnly].contains(content)
        let showTray = tray && [.full,.compact,.trayOnly].contains(content)
        let showSpaces = content == .full || content == .spacesOnly
        let gaps = max(0, [showVoice,showTray,showSpaces].filter { $0 }.count - 1)
        let gap = min(points(.sectionGap,in:h), h / Double(max(1,gaps + 1)))
        let amounts = [showVoice ? points(.voiceHeight,in:h) : 0, showTray ? points(.trayHeight,in:h) : 0,
                       showSpaces ? (content == .spacesOnly && measures[.spacesHeight] == nil ? h : points(.spacesHeight,in:h)) : 0]
        let scale = min(1, max(0,h - Double(gaps) * gap) / max(Double.leastNormalMagnitude, amounts.reduce(0,+)))
        return (amounts[0] * scale, amounts[1] * scale, amounts[2] * scale, gap)
    }
}

public extension DisplaySettings {
    /// Same logical-point bases used by the panel, its sections and the two-column tray.
    func referenceExtent(for key: DisplayMetric, screen: ScreenGeometry, primary: Bool) -> Double {
        let safe = screen.visibleFrame
        let panel = panel(on:screen,fallbackEdge:.right) ?? safe
        let sizes = contentHeights(panel.height,content:primary ? .full : .spacesOnly,voice:primary,tray:primary)
        switch key {
        case .panelWidth,.reservedWidth,.sideInset: return safe.width
        case .panelHeight,.topInset,.bottomInset,.verticalOffset: return safe.height
        case .voiceHeight,.trayHeight,.spacesHeight,.sectionGap,.railHeight: return panel.height
        case .textHeight,.textSize,.lineGap,.voiceButtonHeight,.copySize: return sizes.voice
        case .columnGap: return max(0,panel.width - 2 * points(.trayPadding,in:panel.width))
        case .rowGap: return max(0,sizes.tray - 2 * points(.trayPadding,in:panel.width))
        case .cellWidth:
            let width = referenceExtent(for:.columnGap,screen:screen,primary:primary)
            return max(0,width - min(points(.columnGap,in:width),width/8))
        case .cellHeight,.trayMenuHeight:
            let height = referenceExtent(for:.rowGap,screen:screen,primary:primary)
            return max(0,height - min(points(.rowGap,in:height),height/8))
        case .trayButtonSize: return sizes.tray
        case .spaceRowHeight,.spaceRowGap:
            let viewport = min(sizes.spaces,points(.scrollHeight,in:sizes.spaces))
            return min(viewport,points(.desktopHeight,in:viewport))
        case .desktopHeight: return min(sizes.spaces,points(.scrollHeight,in:sizes.spaces))
        case .scrollHeight,.moduleHeight,.labelSize: return sizes.spaces
        default: return panel.width
        }
    }
}
