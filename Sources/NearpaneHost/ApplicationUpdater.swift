import AppKit
import Combine
import SwiftUI
import NearpaneCore
#if canImport(Sparkle)
import Sparkle
#endif

/// One updater belongs to the owning Host. Showing a panel never creates one.
@MainActor
final class ApplicationUpdater: NSObject, ObservableObject {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var status: String
    @Published private(set) var offeredVersion: String?
    @Published private(set) var installationDeferred = false
    @Published private(set) var sessionInProgress = false
    @Published private var installationAdmission = UpdateInstallationAdmission()
    private let allowNetwork: Bool
    private let bundle: Bundle
    private let installationBlock: @MainActor () -> String?
    private var started = false
    private var stopped = false
    private var pendingInstallation: (() -> Void)?
    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    #endif

    init(allowNetwork: Bool, bundle: Bundle = .main,
         installationBlock: @escaping @MainActor () -> String? = { nil }) {
        self.allowNetwork = allowNetwork
        self.bundle = bundle
        self.installationBlock = installationBlock
        status = allowNetwork ? "更新尚未开始检查。" : "隔离验收期间不连接更新服务。"
        super.init()
    }

    func start() {
        guard !started, !stopped else { return }
        started = true
        guard allowNetwork else { return }
        #if canImport(Sparkle)
        let controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        automaticChecks = controller.updater.automaticallyChecksForUpdates
        if let problem = ApplicationUpdatePolicy.configurationProblem(bundle.infoDictionary ?? [:]) {
            status = problem
            return
        }
        do {
            try controller.updater.start()
            status = "可检查更新。安装前会请你确认，并安全退出当前应用。"
        } catch {
            status = "更新暂不可用。" + error.localizedDescription
            return
        }
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
            controller.updater.observe(\.sessionInProgress, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
        ]
        #else
        status = "此工程构建不包含更新组件。"
        #endif
    }

    func stop() {
        stopped = true
        canCheck = false
        pendingInstallation = nil
        installationDeferred = false
        #if canImport(Sparkle)
        observations.removeAll()
        #endif
    }

    var mayChangePreference: Bool { allowNetwork && started && !stopped }

    var canSwitchProfile: Bool {
        guard !stopped else { return false }
        #if canImport(Sparkle)
        let busy = controller?.updater.sessionInProgress ?? false
        #else
        let busy = false
        #endif
        return installationAdmission.permitsProfileSwitch(sessionInProgress: busy,
            installationDeferred: pendingInstallation != nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard mayChangePreference else { return }
        #if canImport(Sparkle)
        controller?.updater.automaticallyChecksForUpdates = enabled
        automaticChecks = controller?.updater.automaticallyChecksForUpdates ?? false
        #endif
    }

    func check() {
        guard canCheck, !stopped else { return }
        #if canImport(Sparkle)
        status = "正在检查 Nearpane 更新…"
        controller?.checkForUpdates(nil)
        #endif
    }

    func continueInstallation() {
        guard !stopped, let install = pendingInstallation else { return }
        if let problem = installationBlock() { status = problem; return }
        pendingInstallation = nil
        installationDeferred = false
        install()
    }

    #if canImport(Sparkle)
    private func refresh() {
        guard !stopped else { return }
        guard let updater = controller?.updater else { return }
        canCheck = !stopped && updater.canCheckForUpdates
        automaticChecks = updater.automaticallyChecksForUpdates
        sessionInProgress = updater.sessionInProgress
    }
    #endif
}

#if canImport(Sparkle)
extension ApplicationUpdater: SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard allowNetwork, !stopped else { throw updateError("此运行环境已停止更新检查。") }
        if let problem = installationBlock() { throw updateError(problem) }
        if let problem = ApplicationUpdatePolicy.configurationProblem(bundle.infoDictionary ?? [:]) {
            throw updateError(problem)
        }
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        guard allowNetwork, !stopped else { throw updateError("此运行环境已停止更新。") }
        if let problem = installationBlock() { throw updateError(problem) }
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              ApplicationUpdatePolicy.accepts(currentVersion: version, currentBuild: build,
                  candidateVersion: item.displayVersionString, candidateBuild: item.versionString,
                  feedSignatureValid: item.signingValidationStatus == .succeeded) else {
            throw updateError("无法验证更新签名或版本顺序，已停止此更新。")
        }
        guard item.fileURL?.scheme == "https" else {
            throw updateError("更新下载地址不符合安全要求。")
        }
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                             andInImmediateFocus: Bool) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                  state: SPUUserUpdateState) {
        guard !stopped else { return }
        offeredVersion = update.displayVersionString
        status = "Nearpane \(update.displayVersionString) 可用。点击查看并确认安装。"
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        guard !stopped else { return }
        offeredVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        guard !stopped else { return }
        offeredVersion = nil
        // Finishing the UI session does not prove the installer has stopped.
        refresh()
    }

    @objc(updater:userDidMakeChoice:forUpdate:state:)
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        guard !stopped, choice == .install else { return }
        if state.stage == .notDownloaded {
            installationAdmission.acceptDownload()
        } else {
            installationAdmission.acceptInstallation()
        }
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        guard !stopped else { return }
        installationAdmission.cancelDownload()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        installationAdmission.acceptInstallation()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard !stopped else { return true }
        installationAdmission.acceptInstallation()
        guard let problem = installationBlock() else { return false }
        status = problem
        pendingInstallation = installHandler
        installationDeferred = true
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard !stopped else { return }
        if let problem = error as NSError? {
            if problem.domain == SUSparkleErrorDomain && problem.code == Int(SUError.noUpdateError.rawValue) {
                status = "当前已经是可用的最新版本。"
            } else if problem.domain == SUSparkleErrorDomain &&
                [SUError.installationCanceledError.rawValue, SUError.installationAuthorizeLaterError.rawValue]
                .map(Int.init).contains(problem.code) {
                status = "更新已取消，当前版本可继续使用。"
            } else {
                status = "更新未完成。" + problem.localizedDescription
            }
        }
        refresh()
    }

    private func updateError(_ message: String) -> NSError {
        NSError(domain: "com.holdsnow.nearpane.update", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif

struct ApplicationUpdateSettings: View {
    @ObservedObject var updater: ApplicationUpdater

    var body: some View {
        Section("应用更新") {
            Toggle("每天自动检查更新", isOn: Binding(get: { updater.automaticChecks },
                set: updater.setAutomaticChecks))
                .disabled(!updater.mayChangePreference)
                .accessibilityIdentifier("np.update.daily")
            Text("发现更新后提醒，安装由你确认。检查不会上传文字或截图。")
                .font(.caption).foregroundStyle(.secondary)
            Text(updater.status).font(.callout).accessibilityIdentifier("np.update.status")
            if updater.installationDeferred {
                Button("继续安装") { updater.continueInstallation() }
                    .accessibilityIdentifier("np.update.continue")
            } else {
                Button(updater.offeredVersion == nil ? "检查更新…" : "查看更新…") { updater.check() }
                    .disabled(!updater.canCheck).accessibilityIdentifier("np.update.check")
            }
        }
    }
}
