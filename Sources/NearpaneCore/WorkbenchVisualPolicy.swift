import Foundation

/// The supported product controls are deliberately smaller than the internal
/// design-token vocabulary. Legacy overrides are retained for recovery, while
/// current surfaces use the same adaptive width, type and spacing rules.
public enum WorkbenchVisualPolicy {
    public static let revision = 1
    public static let voiceTextSizes = [12.0, 14.0, 16.0]
    public static let windowLabelSizes = [10.0, 11.0, 12.0]

    public static func widthRange(in available: Double) -> ClosedRange<Double> {
        let upper = available.isFinite ? min(420, max(0, available)) : 0
        return min(220, upper)...upper
    }

    public static func width(in available: Double, settings: DisplaySettings) -> Double {
        let range = widthRange(in: available)
        let saved = settings.measures[.panelWidth] ?? settings.measures[.reservedWidth]
        let raw = saved?.points(in: max(0, available)) ?? DisplaySettings.recommendedPanelWidth(in: available)
        let finite = raw.isFinite ? raw : range.lowerBound
        return min(range.upperBound, max(range.lowerBound, finite))
    }

    public static func nearest(_ value: Double, in choices: [Double]) -> Double {
        choices.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }
}

extension DisplaySettings {
    public func applyingWorkbenchVisualPolicy() -> Self {
        var next = self
        let supported: Set<DisplayMetric> = [.panelWidth, .textSize, .labelSize]
        for (metric, value) in measures where !supported.contains(metric) {
            if next.retiredVisualOverrides[metric] == nil { next.retiredVisualOverrides[metric] = value }
        }
        next.measures = measures.filter { supported.contains($0.key) }
        if next.measures[.panelWidth] == nil, let oldReservation = measures[.reservedWidth] {
            next.measures[.panelWidth] = oldReservation
        }
        for (metric, sizes) in [(DisplayMetric.textSize, WorkbenchVisualPolicy.voiceTextSizes),
                                (.labelSize, WorkbenchVisualPolicy.windowLabelSizes)] {
            guard let saved = next.measures[metric] else { continue }
            let resolved = Measure(WorkbenchVisualPolicy.nearest(saved.points(in: 100), in: sizes))
            if saved != resolved, next.retiredVisualOverrides[metric] == nil {
                next.retiredVisualOverrides[metric] = saved
            }
            next.measures[metric] = resolved
        }
        if glass.outerTransparency != nil || glass.innerTransparency != nil || glass.rimWidth != nil {
            if next.retiredGlassOverrides == nil { next.retiredGlassOverrides = glass }
            next.glass.outerTransparency = nil
            next.glass.innerTransparency = nil
            next.glass.rimWidth = nil
        }
        next.visualStyleRevision = WorkbenchVisualPolicy.revision
        return next
    }
}
