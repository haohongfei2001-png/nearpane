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
    /// The full content extent. A smaller viewport scrolls instead of dropping modules.
    public let contentHeight: Double

    /// The configured desktop section includes the optional tool strip at its leading edge.
    public var windowArea: SurfaceRect {
        guard let moduleRail else { return desktop }
        return SurfaceRect(x: desktop.x, y: desktop.y + moduleRail.height, width: desktop.width,
                           height: desktop.height - moduleRail.height)
    }

    public func frame(for moduleID: String) -> SurfaceRect? {
        switch moduleID {
        case BuiltinCatalog.voice: voice.height > 0 ? voice : nil
        case BuiltinCatalog.screenshots: screenshots.height > 0 ? screenshots : nil
        case BuiltinCatalog.desktop: windowArea.height > 0 ? windowArea : nil
        default: additionalTools[moduleID]
        }
    }

    /// Keep the native glass mask aligned with content moving inside the sidebar.
    public func translated(y offset: Double) -> Self {
        func shift(_ rect: SurfaceRect) -> SurfaceRect {
            .init(x: rect.x, y: rect.y + offset, width: rect.width, height: rect.height)
        }
        return Self(voice: shift(voice), screenshots: shift(screenshots),
                    additionalTools: additionalTools.mapValues(shift), desktop: shift(desktop),
                    moduleRail: moduleRail.map(shift), expanded: expanded.map(shift),
                    railCapacity: railCapacity, overflowCount: overflowCount, contentHeight: contentHeight)
    }
}

public enum LayoutComposer {
    public static func compose(width: Double, height: Double, pinnedCount: Int, expanded: Bool,
                               settings: DisplaySettings = .init(), content: PanelContent = .full,
                               voiceEnabled: Bool = true, trayEnabled: Bool = true, referenceHeight: Double? = nil,
                               voiceCompact: Bool = false, trayRows: Int = 1, lyricsHeight: Double = 0, notesHeight: Double = 128,
                               toolOrder: [String] = [BuiltinCatalog.voice, BuiltinCatalog.screenshots]) -> SurfaceLayout {
        let w = width.isFinite ? max(0, width) : 0
        let h = height.isFinite ? max(0, height) : 0
        let reference = referenceHeight ?? h
        let sizes = settings.contentHeights(reference, content: content, voice: voiceEnabled, tray: trayEnabled)
        let inset = min(settings.glass.inset(width: w), h / 2)
        let hasWindows = content == .full || content == .spacesOnly
        let hasTools = content == .full || content == .toolsOnly
        let rail = pinnedCount > 0 && (hasWindows || hasTools) ? settings.points(.railHeight, in: reference) : 0
        // Legacy sample adapters can retain their strip; shipped modules are all
        // direct, ordered content. The clock no longer occupies a protected strip.
        let expandedSample = expanded && rail > 0 && !hasWindows ? settings.points(.moduleHeight, in: reference) : 0
        let sampleOnlyID = "nearpane.legacy-module-strip"
        var order = toolOrder
        if hasWindows && !order.contains(BuiltinCatalog.desktop) { order.append(BuiltinCatalog.desktop) }
        if !hasWindows && rail > 0 { order.append(sampleOnlyID) }
        var seen = Set<String>()
        var requested: [(id: String, preferred: Double, minimum: Double)] = []
        for id in order where seen.insert(id).inserted {
            let preferred: Double
            let minimum: Double
            switch id {
            case BuiltinCatalog.desktop where hasWindows:
                // A usable card viewport, not a reserved fraction or a fixed position.
                preferred = 96 + rail
                minimum = preferred
            case sampleOnlyID:
                preferred = rail + expandedSample
                minimum = preferred
            case BuiltinCatalog.voice where sizes.voice > 0:
                preferred = voiceCompact ? 40 : sizes.voice
                minimum = minimumToolHeight(id, preferred: preferred, width: max(0, w - 2 * inset), settings: settings, voiceCompact: voiceCompact)
            case BuiltinCatalog.screenshots where sizes.tray > 0:
                preferred = settings.measures[.trayHeight] == nil && trayRows > 1 ? 144 : sizes.tray
                minimum = minimumToolHeight(id, preferred: preferred, width: max(0, w - 2 * inset), settings: settings, voiceCompact: voiceCompact)
            case BuiltinCatalog.lyrics:
                preferred = hasTools && w >= 176 && lyricsHeight.isFinite
                    ? max(0, min(192, lyricsHeight)) : 0
                minimum = preferred
            case BuiltinCatalog.memo:
                preferred = hasTools && notesHeight.isFinite ? max(44, min(280, notesHeight)) : 0
                minimum = min(preferred, 72)
            case BuiltinCatalog.clock:
                preferred = hasTools ? 40 : 0
                minimum = preferred
            default: continue
            }
            guard preferred > 0 else { continue }
            requested.append((id, preferred, minimum))
        }
        let gaps = Double(max(0, requested.count - 1)) * sizes.gap
        let usable = max(0, h - 2 * inset)
        let minimumTotal = requested.reduce(0) { $0 + $1.minimum }
        let preferredTotal = requested.reduce(0) { $0 + $1.preferred }
        let flexibility = max(0, preferredTotal - minimumTotal)
        let shortage = min(flexibility, max(0, preferredTotal + gaps - usable))
        let pressure = flexibility > 0 ? shortage / flexibility : 0
        let remaining = max(0, usable - gaps - (preferredTotal - shortage))
        var y = inset
        var frames: [String: SurfaceRect] = [:]
        for request in requested {
            var allocated = request.preferred - pressure * (request.preferred - request.minimum)
            if request.id == BuiltinCatalog.desktop { allocated += remaining }
            let section = SurfaceRect(y: y, width: w, height: allocated)
            frames[request.id] = section
            y += section.height + sizes.gap
        }
        let empty = SurfaceRect(width: w, height: 0)
        let desktop = frames.removeValue(forKey: BuiltinCatalog.desktop) ?? frames.removeValue(forKey: sampleOnlyID) ?? empty
        let railHeight = min(rail, desktop.height)
        let windowHeight = desktop.height - railHeight
        let unit = max(1, settings.points(.railButtonWidth, in: w) + 4)
        let capacity = max(1, Int(max(0, w - 16) / unit))
        let contentHeight = requested.isEmpty ? 2 * inset : y - sizes.gap + inset
        return SurfaceLayout(voice: frames.removeValue(forKey: BuiltinCatalog.voice) ?? empty,
            screenshots: frames.removeValue(forKey: BuiltinCatalog.screenshots) ?? empty, additionalTools: frames,
            desktop: desktop, moduleRail: railHeight > 0 ? SurfaceRect(y: desktop.y, width: w, height: railHeight) : nil,
            expanded: expanded ? SurfaceRect(x: min(6, w / 2), y: desktop.y + railHeight + min(6, windowHeight / 2),
                width: max(0, w - 12), height: max(0, min(windowHeight, settings.points(.moduleHeight, in: windowHeight)) - 12)) : nil,
            railCapacity: capacity, overflowCount: max(0, pinnedCount - capacity), contentHeight: contentHeight)
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
        case BuiltinCatalog.memo: minimum = 72
        default: minimum = preferred
        }
        return min(preferred, minimum)
    }
}
