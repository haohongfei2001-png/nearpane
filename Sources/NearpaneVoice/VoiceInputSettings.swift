import AVFoundation
import Combine
import SaytileKit
import SwiftUI

private typealias ViewState<T> = State<T>

/// Checking readiness never opens the device. The VoiceSurface button owns capture.
public struct VoiceInputSettings: View {
    private let module: VoiceModule
    @ViewState private var availability: SpeechAvailability?
    @ViewState private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @ViewState private var route: VoiceInputRoute = .unknown
    @ViewState private var preparing = false
    @ViewState private var error: String?
    @ViewState private var editingAPI = false
    @ViewState private var language: LanguagePreference = .chinese
    @ViewState private var region = "cn-beijing"
    @ViewState private var workspace = ""
    @ViewState private var expertKey = ""
    @ViewState private var fusionKey = ""
    @ViewState private var consent = false

    public init(module: VoiceModule) { self.module = module }

    public var body: some View {
        Form {
            if let profile = module.recognitionProfile {
                Section("识别方式") {
                    LabeledContent("当前", value: profile.enabled ? "API · " + (profile.language?.label ?? "") : "Apple 本机")
                    if let issue = profile.issue { Text(issue).foregroundStyle(.secondary) }
                    if profile.needsCleanup {
                        Button(profile.enabled ? "切回本机并清除 API 密钥" : "清除 API 授权") {
                            Task {
                                do { try await module.disableAPI(); error = nil }
                                catch { self.error = error.localizedDescription }
                            }
                        }.disabled(module.changingRecognition)
                    } else if editingAPI {
                        apiForm
                    } else {
                        Button("配置 API 识别…") { editingAPI = true; error = nil }
                    }
                }
            }
            Section("本机输入") {
                LabeledContent("麦克风权限", value: permissionLabel)
                LabeledContent("输入设备", value: route.label)
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
                Button("重新检查") { Task { await refresh() } }.disabled(preparing)
            }
            VoiceOperationFeedback(module: module)
            if let error { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
        }.formStyle(.grouped).task { await refresh() }
        .task {
            for await _ in VoiceInputRouteObservation.shared.changes() { refreshDevice() }
        }
        .onReceive(Publishers.Merge(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification),
                                   NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification))) { _ in refreshDevice() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshDevice() }
        .onDisappear { clearDraft() }
    }

    @ViewBuilder private var apiForm: some View {
        Picker("识别语言", selection: $language) {
            ForEach([LanguagePreference.chinese, .english, .chineseEnglishMixed], id: \.self) { Text($0.label).tag($0) }
        }.onChange(of: language) { expertKey = ""; consent = false }
        if language == .chinese {
            Picker("Qwen 地域", selection: $region) {
                Text("北京").tag("cn-beijing")
                Text("新加坡").tag("ap-southeast-1")
            }.onChange(of: region) { expertKey = ""; consent = false }
            TextField("Qwen Workspace ID", text: $workspace)
                .onChange(of: workspace) { consent = false }
        }
        let expert = ASRModelRegistry.provider(for: language)?.label ?? ""
        SecureField(expert + " API Key", text: $expertKey)
        SecureField("OpenAI API Key", text: $fusionKey)
        Toggle("允许 " + expert + " 处理本次启用后的录音，并允许 OpenAI GPT-6 Astra 处理识别文字。服务可能计费。", isOn: $consent)
        HStack {
            Button("启用 API") {
                Task {
                    do {
                        try await module.enableAPI(language: language, workspace: workspace, region: region,
                                                   expertKey: expertKey, fusionKey: fusionKey, consent: consent)
                        error = nil
                    } catch { self.error = error.localizedDescription }
                    clearDraft()
                }
            }.disabled(!consent || expertKey.isEmpty || fusionKey.isEmpty || (language == .chinese && workspace.isEmpty)
                       || module.changingRecognition)
            Button("取消") { clearDraft() }
        }
    }
    private func clearDraft() {
        expertKey = ""; fusionKey = ""; consent = false; editingAPI = false
    }

    private func refreshDevice() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        route = VoiceInputRoute.current()
    }

    private func refresh() async {
        refreshDevice()
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

/// User-initiated edits, dictation and insertions report their outcomes in the host settings.
package struct VoiceOperationFeedback: View {
    let module: VoiceModule
    package init(module: VoiceModule) { self.module = module }

    package var body: some View {
        ForEach(module.operationMessages, id: \.self) { message in
            Text(message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
