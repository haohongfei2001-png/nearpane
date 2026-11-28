import SwiftUI
import SaytileVoiceUI

/// The button shape is shared by the sidebar and the fullscreen tool.
/// Every bar height comes from the current measured voice level.
struct VoiceCaptureGlyph: View {
    let presentation: PanelCapturePresentation
    var width: Double = 28
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        // Keep one shape identity, including startup and recovery. Until capture
        // succeeds the triangle remains; existing help/error text explains why.
        // This avoids flashing a fourth glyph or claiming that capture is ready.
        let state: VoicePanelState = switch presentation.state {
        case .paused: .paused
        case .standby: .standby
        case .recognizing: .recognizing
        }
        SaytileVoiceUI.VoiceCaptureGlyph(
            presentation: VoicePanelCapture(state: state, level: presentation.liveVoiceLevel,
                                            actionLabel: "", accessibilityValue: ""),
            scale: width / 28)
        .foregroundStyle(ink)
    }

    private var ink: AnyShapeStyle {
        if contrast == .increased { return AnyShapeStyle(Color.primary) }
        return AnyShapeStyle(.tint)
    }
}
