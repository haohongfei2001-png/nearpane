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
    var openManagement: (() -> Void)?
    private let allowNetwork: Bool
    private let bundle: Bundle
    private let installationBlock: @MainActor () -> String?
    private let activityBlock: @MainActor () async -> String?
    private var started = false
    private var stopped = false
    private var pendingInstallation: (() -> Void)?
    private var checkingRelaunch = false
    private var installerRequestedTermination = false
    #if canImport(Sparkle)
    let userDriver = EmbeddedUpdateUserDriver()
    private var engine: SPUUpdater?
    private var observations: [NSKeyValueObservation] = []
    #endif

    init(allowNetwork: Bool, bundle: Bundle = .main,
         activityBlock: @escaping @MainActor () async -> String? = { nil },
         installationBlock: @escaping @MainActor () -> String? = { nil }) {
        self.allowNetwork = allowNetwork
        self.bundle = bundle
        self.installationBlock = installationBlock
        self.activityBlock = activityBlock
        status = allowNetwork ? "更新尚未开始检查。" : "隔离验收期间不连接更新服务。"
        super.init()
        #if canImport(Sparkle)
        userDriver.requestManagement = { [weak self] in self?.openManagement?() }
        userDriver.reportStatus = { [weak self] in self?.status = $0 }
        userDriver.reportOffer = { [weak self] in self?.offeredVersion = $0 }
        #endif
    }

    func start() {
        guard !started, !stopped else { return }
        started = true
        guard allowNetwork else { return }
        #if canImport(Sparkle)
        let engine = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: userDriver, delegate: self)
        self.engine = engine
        engine.sendsSystemProfile = false
        automaticChecks = engine.automaticallyChecksForUpdates
        if let problem = ApplicationUpdatePolicy.configurationProblem(bundle.infoDictionary ?? [:]) {
            status = problem
            return
        }
        do {
            try engine.start()
            if userDriver.phase == .idle {
                status = "可检查更新。安装前会请你确认，并安全退出当前应用。"
            }
        } catch {
            status = "更新暂不可用。" + error.localizedDescription
            return
        }
        observations = [
            engine.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
            engine.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
            engine.observe(\.sessionInProgress, options: [.new]) { [weak self] _, _ in
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
        userDriver.stop()
        #endif
    }

    var mayChangePreference: Bool { allowNetwork && started && !stopped }

    var canSwitchProfile: Bool {
        guard !stopped else { return false }
        #if canImport(Sparkle)
        let busy = engine?.sessionInProgress ?? false
        #else
        let busy = false
        #endif
        return installationAdmission.permitsProfileSwitch(sessionInProgress: busy,
            installationDeferred: pendingInstallation != nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard mayChangePreference else { return }
        #if canImport(Sparkle)
        engine?.automaticallyChecksForUpdates = enabled
        automaticChecks = engine?.automaticallyChecksForUpdates ?? false
        #endif
    }

    func check() {
        guard !stopped else { return }
        openManagement?()
        #if canImport(Sparkle)
        if userDriver.phase != .idle {
            userDriver.showUpdateInFocus()
            return
        }
        guard canCheck else { return }
        status = "正在检查 Nearpane 更新…"
        engine?.checkForUpdates()
        #endif
    }

    private func liveRelaunchBlock() async -> String? {
        let activity = await activityBlock()
        return installationBlock() ?? activity
    }

    func deferInstallation(_ install: @escaping () -> Void) {
        guard !stopped, pendingInstallation == nil else { return }
        pendingInstallation = install
        installationDeferred = true
        continueInstallation()
    }

    func continueInstallation() {
        guard !stopped, pendingInstallation != nil, !checkingRelaunch else { return }
        checkingRelaunch = true
        Task {
            defer { checkingRelaunch = false }
            let problem = await liveRelaunchBlock()
            guard !stopped, let install = pendingInstallation else { return }
            if let problem { status = problem; return }
            pendingInstallation = nil
            installationDeferred = false
            installerRequestedTermination = true
            install()
        }
    }

    func willRequestInstallation() {
        installerRequestedTermination = true
        installationAdmission.acceptInstallation()
    }

    /// Some Sparkle paths do not deliver the postpone callback. Recheck in the Host's
    /// termination barrier before stopping capture or restoring managed windows.
    func permitsTermination() async -> Bool {
        guard installerRequestedTermination else { return true }
        if let problem = await liveRelaunchBlock() { status = problem; return false }
        return true
    }

    #if canImport(Sparkle)
    private func refresh() {
        guard !stopped else { return }
        guard let updater = engine else { return }
        canCheck = !stopped && updater.canCheckForUpdates
        automaticChecks = updater.automaticallyChecksForUpdates
        sessionInProgress = updater.sessionInProgress
    }
    #endif
}

#if canImport(Sparkle)
extension ApplicationUpdater: SPUUpdaterDelegate {
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
        let destination = item.isInformationOnlyUpdate ? item.infoURL : item.fileURL
        guard destination?.scheme == "https" else {
            throw updateError("更新下载地址不符合安全要求。")
        }
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
        willRequestInstallation()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard !stopped else { return true }
        installationAdmission.acceptInstallation()
        deferInstallation(installHandler)
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
                set: { updater.setAutomaticChecks($0) }))
                .disabled(!updater.mayChangePreference)
                .accessibilityIdentifier("np.update.daily")
            Text("发现更新后提醒，安装由你确认。检查不会上传文字或截图。")
                .font(.caption).foregroundStyle(.secondary)
            Text(updater.status).font(.callout).accessibilityIdentifier("np.update.status")
            if updater.installationDeferred {
                Button("继续安装") { updater.continueInstallation() }
                    .accessibilityIdentifier("np.update.continue")
            }
            #if canImport(Sparkle)
            EmbeddedUpdateProgress(driver: updater.userDriver).disabled(updater.installationDeferred)
            #endif
            if !updater.installationDeferred && !updater.sessionInProgress {
                Button(updater.offeredVersion == nil ? "检查更新…" : "查看更新…") { updater.check() }
                    .disabled(!updater.canCheck).accessibilityIdentifier("np.update.check")
            }
        }
    }
}
