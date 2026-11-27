import Foundation

/// Surface coordinates are top-left logical points. Screen placement alone uses AppKit coordinates.
public struct SurfaceRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum SurfaceEdge: String, Codable, CaseIterable, Sendable { case left, right }

public struct ScreenGeometry: Equatable, Sendable {
    public let id: String
    public let frame: SurfaceRect
    public let visibleFrame: SurfaceRect

    /// Presentation generation evidence. Layout continues to use the logical-point rectangles.
    public let rotationDegrees: Double
    public let backingScale: Double

    public init(id: String, frame: SurfaceRect, visibleFrame: SurfaceRect, rotationDegrees: Double = 0, backingScale: Double = 1) {
        self.id = id; self.frame = frame; self.visibleFrame = visibleFrame
        self.rotationDegrees = rotationDegrees; self.backingScale = backingScale
    }
}

public enum SurfacePlacement {
    /// A missing preferred display falls back without rewriting the preference.
    public static func resolve(screens: [ScreenGeometry], preferredID: String?, edge: SurfaceEdge, settings: [String: DisplaySettings] = [:]) -> SurfaceRect? {
        let usable = screens.filter {
            [$0.frame, $0.visibleFrame].allSatisfy { rect in
                rect.x.isFinite && rect.y.isFinite && rect.width.isFinite && rect.width > 0 &&
                rect.height.isFinite && rect.height > 0
            }
        }
        guard let screen = usable.first(where: { $0.id == preferredID }) ?? usable.first else { return nil }
        return (settings[screen.id] ?? .init()).panel(on:screen,fallbackEdge:edge)
    }
}

public struct SurfaceLayout: Equatable, Sendable {
    public let voice: SurfaceRect
    public let screenshots: SurfaceRect
    public let additionalTools: [String: SurfaceRect]
    public let desktop: SurfaceRect
    public let moduleRail: SurfaceRect?
    public let expanded: SurfaceRect?
    public let railCapacity: Int
    public let overflowCount: Int

    /// The configured desktop section includes the optional tool strip at its leading edge.
    public var windowArea: SurfaceRect {
        guard let moduleRail else { return desktop }
        return SurfaceRect(x: desktop.x, y: desktop.y + moduleRail.height, width: desktop.width,
                           height: desktop.height - moduleRail.height)
    }
}

public enum LayoutComposer {
    public static func compose(width: Double, height: Double, pinnedCount: Int, expanded: Bool,
                               settings: DisplaySettings = .init(), content: PanelContent = .full,
                               voiceEnabled: Bool = true, trayEnabled: Bool = true, referenceHeight: Double? = nil,
                               voiceCompact: Bool = false, trayRows: Int = 1, lyricsHeight: Double = 0,
                               toolOrder: [String] = [BuiltinCatalog.voice, BuiltinCatalog.screenshots]) -> SurfaceLayout {
        let w = width.isFinite ? max(0, width) : 0
        let h = height.isFinite ? max(0, height) : 0
        let reference = referenceHeight ?? h
        let sizes = settings.contentHeights(reference, content: content, voice: voiceEnabled, tray: trayEnabled)
        let inset = min(settings.glass.inset(width: w), h / 2)
        let bottom = h - inset
        var y = inset
        var frames: [String: SurfaceRect] = [:]
        var seen = Set<String>()
        var requested: [(id: String, preferred: Double, minimum: Double)] = []
        for id in toolOrder where seen.insert(id).inserted {
            let preferred: Double
            switch id {
            case BuiltinCatalog.voice where sizes.voice > 0:
                preferred = voiceCompact ? 40 : sizes.voice
            case BuiltinCatalog.screenshots where sizes.tray > 0:
                preferred = settings.measures[.trayHeight] == nil && trayRows > 1 ? 144 : sizes.tray
            case BuiltinCatalog.lyrics:
                preferred = (content == .full || content == .toolsOnly) && w >= 176 && lyricsHeight.isFinite
                    ? max(0, min(192, lyricsHeight)) : 0
            case BuiltinCatalog.memo, BuiltinCatalog.tasks:
                preferred = content == .full || content == .toolsOnly ? 128 : 0
            default: continue
            }
            guard preferred > 0 else { continue }
            let minimum = minimumToolHeight(id, preferred: preferred, width: max(0, w - 2 * inset),
                                            settings: settings, voiceCompact: voiceCompact)
            requested.append((id, preferred, minimum))
        }
        let rail = pinnedCount > 0 ? settings.points(.railHeight, in: reference) : 0
        let hasWindows = content == .full || content == .spacesOnly
        let gapCount = max(0, requested.count - 1) + (!requested.isEmpty && (hasWindows || rail > 0) ? 1 : 0)
        let gaps = Double(gapCount) * sizes.gap
        let usable = max(0, bottom - inset)
        let minimumTools = requested.reduce(0) { $0 + $1.minimum }
        // Preserve normal geometry. Only crowded combinations borrow vertical room
        // from text viewports and thumbnail padding. Lyrics keep their full reading
        // height, and Spaces retains a useful window area whenever it physically fits.
        let desiredResident = hasWindows ? min(settings.points(.spacesHeight, in: reference), 96 + rail) : rail
        let residentReserve = min(desiredResident, max(0, usable - minimumTools - gaps))
        let preferredTools = requested.reduce(0) { $0 + $1.preferred }
        let flexibility = max(0, preferredTools - minimumTools)
        let shortage = min(flexibility, max(0, preferredTools + gaps + residentReserve - usable))
        let pressure = flexibility > 0 ? shortage / flexibility : 0
        for request in requested {
            let allocated = request.preferred - pressure * (request.preferred - request.minimum)
            // In physically undersized panels, sizeForm presents the existing
            // expansion button instead of exposing a cut-off lyric control surface.
            if request.id == BuiltinCatalog.lyrics && allocated > bottom - y + 0.001 { continue }
            let section = SurfaceRect(y: y, width: w, height: min(allocated, max(0, bottom - y)))
            frames[request.id] = section
            y = min(bottom, y + section.height + sizes.gap)
        }
        let available = content == .full || content == .spacesOnly ? max(0, bottom - y) : 0
        let toolExpansion = expanded && rail > 0 ? settings.points(.moduleHeight, in: reference) : 0
        let sectionHeight = content == .toolsOnly
            ? min(max(0, bottom - y), rail + toolExpansion)
            : min(available, settings.points(.spacesHeight, in: reference))
        let desktop = SurfaceRect(y: y, width: w, height: sectionHeight)
        let railHeight = min(rail, desktop.height)
        let windowHeight = desktop.height - railHeight
        let unit = max(1, settings.points(.railButtonWidth, in: w) + 4)
        let capacity = max(1, Int(max(0, w - 16) / unit))
        let empty = SurfaceRect(width: w, height: 0)
        return SurfaceLayout(voice: frames.removeValue(forKey: BuiltinCatalog.voice) ?? empty,
            screenshots: frames.removeValue(forKey: BuiltinCatalog.screenshots) ?? empty, additionalTools: frames,
            desktop: desktop, moduleRail: railHeight > 0 ? SurfaceRect(y: y, width: w, height: railHeight) : nil,
            expanded: expanded ? SurfaceRect(x: min(6, w / 2), y: y + railHeight + min(6, windowHeight / 2),
                width: max(0, w - 12), height: max(0, min(windowHeight, settings.points(.moduleHeight, in: windowHeight)) - 12)) : nil,
            railCapacity: capacity, overflowCount: max(0, pinnedCount - capacity))
    }

    /// Minimum usable existing controls; this does not resize fonts or change saved
    /// metrics. Explicit smaller user settings are still handled by sizeForm.
    static func minimumToolHeight(_ id: String, preferred: Double, width: Double,
                                  settings: DisplaySettings, voiceCompact: Bool) -> Double {
        let minimum: Double
        switch id {
        case BuiltinCatalog.voice:
            if voiceCompact { minimum = 40 }
            else {
                let font = settings.readableFontSize(.textSize, in: preferred) ?? settings.points(.textSize, in: preferred)
                let line = settings.measures[.textSize] == nil ? font * 4 / 3 : font * 1.3
                let controls = max(settings.points(.voiceButtonHeight, in: preferred),
                                   settings.points(.waveformSize, in: width) * 24 / 28,
                                   settings.points(.copySize, in: preferred))
                minimum = max(80, 2 * settings.points(.textPadding, in: width) + controls + line + DisplaySettings.voiceFooterGap)
            }
        case BuiltinCatalog.screenshots:
            minimum = max(76, 2 * settings.points(.trayPadding, in: width) +
                          2 * settings.points(.trayButtonSize, in: preferred) + settings.points(.rowGap, in: preferred))
        case BuiltinCatalog.memo, BuiltinCatalog.tasks: minimum = 72
        default: minimum = preferred
        }
        return min(preferred, minimum)
    }
}
