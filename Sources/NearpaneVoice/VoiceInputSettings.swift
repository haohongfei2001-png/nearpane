import AVFoundation
import SaytileKit
import SwiftUI

private typealias ViewState<T> = State<T>

/// Checking readiness never opens the device. The VoiceSurface button owns capture.
public struct VoiceInputSettings: View {
    @ViewState private var availability: SpeechAvailability?
    @ViewState private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @ViewState private var preparing = false
    @ViewState private var error: String?

    public init() {}

    public var body: some View {
        Form {
            LabeledContent("麦克风", value: permissionLabel)
            Text(availability?.message ?? "正在检查本机中文识别资源…")
            if let availability, availability.supported && !availability.installed {
                Button(preparing ? "正在准备…" : "准备本机中文识别资源") {
                    guard !preparing else { return }
                    preparing = true
                    error = nil
                    Task {
                        do { try await AppleSpeechService.prepare() }
                        catch { self.error = error.localizedDescription }
                        await refresh()
                        preparing = false
                    }
                }.disabled(preparing)
            }
            if let error { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
            Button("重新检查") { Task { await refresh() } }.disabled(preparing)
        }.padding().task { await refresh() }
    }

    private func refresh() async {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        availability = await AppleSpeechService.availability()
    }

    private var permissionLabel: String {
        switch microphone {
        case .authorized: "已允许"
        case .notDetermined: "首次开始收音时询问"
        case .denied: "请在系统设置的「隐私与安全性 → 麦克风」中允许"
        case .restricted: "系统已限制访问"
        @unknown default: "状态未知"
        }
    }
}
