import AVFoundation
import SwiftUI

private typealias ViewState<Value> = State<Value>

/// Only the domain's three-state glyph is exposed. No transcript is embedded in this control.
public struct FullscreenVoiceButton: View {
    private let module: VoiceModule
    private let permit: @MainActor () -> Bool
    @ViewState private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)

    public init(module: VoiceModule, permit: @escaping @MainActor () -> Bool) {
        self.module = module
        self.permit = permit
    }

    public var body: some View {
        let unavailable = Self.unavailableReason(active: module.active, busy: module.busy,
                                                 running: module.capture.isRunning, microphone: microphone)
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
        .buttonStyle(.plain).disabled(unavailable != nil)
        .accessibilityLabel(title)
        .accessibilityValue(module.control.state == .standby ? "待命" : module.control.state == .recognizing ? "正在识别" : "暂停")
        .accessibilityIdentifier("np.fullscreen.voice")
        .help(unavailable ?? title)
        .onAppear { microphone = AVCaptureDevice.authorizationStatus(for: .audio) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    static func unavailableReason(active: Bool, busy: Bool, running: Bool, microphone: AVAuthorizationStatus) -> String? {
        guard active else { return "语音模块已关闭" }
        guard !busy else { return "正在切换收音状态" }
        guard !running else { return nil }
        switch microphone {
        case .authorized: return nil
        case .notDetermined: return "请先在普通语音面板点击收音并确认麦克风权限"
        case .denied: return "当前 Nearpane 无法访问麦克风，可在语音设置中查看权限状态"
        case .restricted: return "此 Mac 限制麦克风访问"
        @unknown default: return "暂时无法确定麦克风状态"
        }
    }
}
