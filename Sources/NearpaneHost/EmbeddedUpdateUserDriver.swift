#if canImport(Sparkle)
import AppKit
import Combine
import Foundation
import Sparkle
import SwiftUI

/// Sparkle supplies update mechanics; Nearpane supplies every product interaction
/// inside its retained main window. This driver has no windows, alerts or sheets.
@MainActor
final class EmbeddedUpdateUserDriver: NSObject, ObservableObject, SPUUserDriver {
    enum Phase: Equatable { case idle, permission, checking, available, downloading, extracting, ready, installing, result }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var progress: Double?
    @Published private(set) var primaryTitle: String?
    @Published private(set) var secondaryTitle: String?
    @Published private(set) var releaseNotes: String?
    @Published private(set) var informationURL: URL?
    var requestManagement: (() -> Void)?
    var reportStatus: ((String) -> Void)?
    var reportOffer: ((String?) -> Void)?
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?
    private var downloaded: UInt64 = 0
    private var expected: UInt64 = 0
    private var stopped = false

    func performPrimary() { let action = primaryAction; clearActions(); action?() }
    func performSecondary() { let action = secondaryAction; clearActions(); action?() }
    func stop() { stopped = true; clearActions(); progress = nil }

    private func clearActions() {
        primaryAction = nil; secondaryAction = nil
        primaryTitle = nil; secondaryTitle = nil
    }
    private func transition(_ phase: Phase, _ message: String) {
        clearActions(); progress = nil
        self.phase = phase; reportStatus?(message)
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        guard !stopped else { reply(.init(automaticUpdateChecks: false, sendSystemProfile: false)); return }
        transition(.permission, "是否每天自动检查 Nearpane 更新？安装前仍会请你确认。")
        primaryTitle = "允许自动检查"; secondaryTitle = "仅手动检查"
        primaryAction = { reply(.init(automaticUpdateChecks: true, sendSystemProfile: false)) }
        secondaryAction = { reply(.init(automaticUpdateChecks: false, sendSystemProfile: false)) }
        requestManagement?()
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        guard !stopped else { cancellation(); return }
        transition(.checking, "正在检查 Nearpane 更新…")
        secondaryTitle = "取消检查"; secondaryAction = cancellation
        requestManagement?()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !stopped else { reply(.dismiss); return }
        let version = appcastItem.displayVersionString
        reportOffer?(version)
        // A background finding is a quiet badge, not a new window or a retained
        // update session that would unnecessarily block profile switching.
        if !state.userInitiated {
            reportStatus?("Nearpane \(version) 可用，可在此查看并确认安装。")
            reply(.dismiss)
            return
        }
        transition(.available, "Nearpane \(version) 可用。")
        releaseNotes = UpdateReleaseNotesText.plain(appcastItem.itemDescription)
        informationURL = appcastItem.infoURL.flatMap { $0.scheme == "https" ? $0 : nil }
        if !appcastItem.isInformationOnlyUpdate {
            primaryTitle = state.stage == .notDownloaded ? "下载更新" : "安装并重新打开"
            primaryAction = { [weak self] in self?.reportOffer?(nil); reply(.install) }
        }
        secondaryTitle = "稍后"
        secondaryAction = { reply(.dismiss) }
        requestManagement?()
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard !stopped, downloadData.data.count <= 262_144 else { return }
        releaseNotes = UpdateReleaseNotesText.plain(String(data: downloadData.data, encoding: .utf8))
    }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        guard !stopped else { return }
        releaseNotes = "发行说明暂时无法载入。" + error.localizedDescription
    }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        guard !stopped else { acknowledgement(); return }
        transition(.result, error.localizedDescription)
        primaryTitle = "知道了"; primaryAction = acknowledgement
        reportOffer?(nil)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        guard !stopped else { acknowledgement(); return }
        transition(.result, "更新未完成。" + error.localizedDescription)
        primaryTitle = "知道了"; primaryAction = acknowledgement
        requestManagement?()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        guard !stopped else { cancellation(); return }
        transition(.downloading, "正在下载更新…")
        downloaded = 0; expected = 0
        secondaryTitle = "取消下载"; secondaryAction = cancellation
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard !stopped else { return }
        expected = expectedContentLength
        updateDownloadProgress()
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard !stopped else { return }
        let total = downloaded.addingReportingOverflow(length)
        downloaded = total.overflow ? UInt64.max : total.partialValue
        updateDownloadProgress()
    }
    private func updateDownloadProgress() {
        progress = expected > 0 ? min(1, Double(downloaded) / Double(expected)) : nil
    }
    func showDownloadDidStartExtractingUpdate() {
        guard !stopped else { return }
        transition(.extracting, "正在准备更新…")
    }
    func showExtractionReceivedProgress(_ progress: Double) {
        guard !stopped else { return }
        self.progress = progress.isFinite ? min(1, max(0, progress)) : nil
    }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !stopped else { reply(.dismiss); return }
        transition(.ready, "更新已准备好。安装前会保存状态，并等待当前任务结束。")
        primaryTitle = "安装并重新打开"
        primaryAction = { reply(.install) }
        secondaryTitle = "稍后安装"; secondaryAction = { reply(.dismiss) }
        requestManagement?()
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        guard !stopped else { return }
        transition(.installing, applicationTerminated ? "正在安装更新…" : "正在等待 Nearpane 完成当前任务…")
        if !applicationTerminated {
            primaryTitle = "继续安装"; primaryAction = retryTerminatingApplication
        }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        guard !stopped else { acknowledgement(); return }
        transition(.result, relaunched ? "更新已完成，Nearpane 已重新打开。" : "更新已完成。")
        primaryTitle = "完成"; primaryAction = acknowledgement
        reportOffer?(nil)
    }
    func dismissUpdateInstallation() {
        clearActions(); phase = .idle; progress = nil; releaseNotes = nil; informationURL = nil
    }
    func showUpdateInFocus() { if !stopped { requestManagement?() } }
}

/// Render downloaded release notes as inert text. Do not load HTML, remote images,
/// JavaScript or an independent WebKit window from update metadata.
enum UpdateReleaseNotesText {
    static func plain(_ source: String?) -> String? {
        guard let source, !source.isEmpty else { return nil }
        var value = String(source.prefix(65_536))
        value = value.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?i)<(?:br\\s*/?|/p|/div|/li|/h[1-6])>", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            value = value.replacingOccurrences(of: entity, with: character)
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct EmbeddedUpdateProgress: View {
    @ObservedObject var driver: EmbeddedUpdateUserDriver
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if [.checking, .downloading, .extracting, .installing].contains(driver.phase) {
                if let progress = driver.progress { ProgressView(value: progress) }
                else { ProgressView().controlSize(.small) }
            }
            if let notes = driver.releaseNotes {
                DisclosureGroup("发行说明") {
                    ScrollView { Text(notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 180)
                }
            }
            if let url = driver.informationURL { Link("查看更新说明", destination: url) }
            HStack {
                if let title = driver.primaryTitle {
                    Button(title) { driver.performPrimary() }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("np.update.primary")
                }
                if let title = driver.secondaryTitle {
                    Button(title) { driver.performSecondary() }.accessibilityIdentifier("np.update.secondary")
                }
            }
        }
        .accessibilityIdentifier("np.update.embedded")
    }
}
#endif
