import AVFoundation
import SwiftUI

/// Only the domain's three-state glyph is exposed. No transcript is embedded in this control.
public struct FullscreenVoiceButton: View {
    private let module: VoiceModule
    private let permit: @MainActor () -> Bool

    public init(module: VoiceModule, permit: @escaping @MainActor () -> Bool) {
        self.module = module
        self.permit = permit
    }

    public var body: some View {
        let available = module.active && !module.busy &&
            (module.capture.isRunning || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        let title = module.capture.isRunning ? "暂停收音" : "开始或恢复收音"
        Button {
            Task { @MainActor in
                guard permit() else { return }
                await module.toggle(requestPermission: false)
            }
        } label: {
            VoiceCaptureGlyph(presentation: module.control, width: 22)
                .frame(width: 38, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!available)
        .accessibilityLabel(title)
        .accessibilityValue(module.control.state == .standby ? "待命" : module.control.state == .recognizing ? "正在识别" : "暂停")
        .accessibilityIdentifier("np.fullscreen.voice")
        .help(available ? title : "收音暂不可用，请检查语音设置和麦克风权限")
    }
}
