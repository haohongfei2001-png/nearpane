import SwiftUI

/// The existing voice button's glyph only. No panel, color, size or control layout
/// is defined here. Every bar height comes from the current measured voice level.
struct VoiceCaptureGlyph: View {
    let presentation: PanelCapturePresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Keep one shape identity, including startup and recovery. Until capture
        // succeeds the triangle remains; existing help/error text explains why.
        // This avoids flashing a fourth glyph or claiming that capture is ready.
        let paused = presentation.state != .standby && presentation.state != .recognizing
        VoiceCaptureGlyphShape(
            paused: paused ? 1 : 0,
            speaking: presentation.state == .recognizing ? 1 : 0,
            level: presentation.liveVoiceLevel ?? 0)
        // A new value retargets the current shape; no delayed actions, queued
        // transitions, random oscillators or idle animation. State wins when
        // phase and level change together; level-only updates use the short ease.
        .animation(reduceMotion ? nil : .easeInOut(duration: paused ? 0.12 : 0.16),
                   value: presentation.state)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.07),
                   value: presentation.liveVoiceLevel)
        .frame(width: 28, height: 24)
        .accessibilityHidden(true)
    }
}

/// A single compatible path morphs triangle <-> dot <-> rounded vertical bars.
/// Both phase weights and the measured amplitude are animatable, so a quick VAD
/// change or pause starts from the shape currently on screen rather than flashing.
struct VoiceCaptureGlyphShape: Shape {
    var paused: Double
    var speaking: Double
    var level: Double

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(paused, AnimatablePair(speaking, level)) }
        set { paused = newValue.first; speaking = newValue.second.first; level = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        let pauseWeight = Self.unit(paused)
        let speechWeight = min(1 - pauseWeight, Self.unit(speaking))
        let dotWeight = 1 - pauseWeight - speechWeight
        let amplitude = sqrt(Self.unit(level))
        let scale = min(rect.width / 24, rect.height / 18)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let barWidth = 2.5
        let heights = [0.13, 0.60, 1.0, 0.64, 0.14].map { 4 + 13 * amplitude * $0 }
        var result = Path()

        // The center has a fixed vertex order in every state. The triangle is
        // right-facing; the capsule is vertical, never a sinusoidal wave line.
        for index in 0..<72 {
            let angle = Double(index) * .pi * 2 / 72
            let dx = cos(angle), dy = sin(angle)
            let radius = dotWeight * 5
                + pauseWeight * Self.triangleRadius(dx: dx, dy: dy)
                + speechWeight * Self.capsuleRadius(dx: dx, dy: dy, width: barWidth, height: heights[2])
            let point = CGPoint(x: center.x + CGFloat(radius * dx) * scale,
                                y: center.y + CGFloat(radius * dy) * scale)
            if index == 0 { result.move(to: point) } else { result.addLine(to: point) }
        }
        result.closeSubpath()

        // Outer bars grow out of and collapse into the center. No extra control,
        // label or expanded waveform is introduced during any transition.
        if speechWeight > 0.0001 {
            for index in [0, 1, 3, 4] {
                let width = CGFloat(barWidth * speechWeight) * scale
                let height = CGFloat(heights[index] * speechWeight) * scale
                let x = center.x + CGFloat(Double(index - 2) * 5 * speechWeight) * scale
                result.addRoundedRect(in: CGRect(x: x - width / 2, y: center.y - height / 2,
                                                  width: width, height: height),
                                      cornerSize: CGSize(width: width / 2, height: width / 2))
            }
        }
        return result
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    private static func triangleRadius(dx: Double, dy: Double) -> Double {
        // Ray intersection with vertices (5, 0), (-3.5, 5), (-3.5, -5).
        var distance = Double.infinity
        if dx < 0 { distance = min(distance, -3.5 / dx) }
        for denominator in [dy + 5 / 8.5 * dx, -dy + 5 / 8.5 * dx] where denominator > 0 {
            distance = min(distance, (25 / 8.5) / denominator)
        }
        return distance
    }

    private static func capsuleRadius(dx: Double, dy: Double, width: Double, height: Double) -> Double {
        let radius = width / 2, halfStem = max(0, height / 2 - radius)
        if abs(dx) > 0.000001 {
            let side = radius / abs(dx)
            if abs(side * dy) <= halfStem { return side }
        }
        return halfStem * abs(dy) + sqrt(max(0, radius * radius - halfStem * halfStem * dx * dx))
    }
}
