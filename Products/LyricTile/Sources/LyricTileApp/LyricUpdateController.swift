import LyricCore
import Foundation
import Sparkle

@MainActor
final class LyricUpdateController {
    private var controller: SPUStandardUpdaterController?
    private var configurationMessage: String?

    init(bundle: Bundle = .main) {
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            configurationMessage = LyricLocalization.text("这是独立候选构建，尚未连接正式更新频道。安装与歌词功能可以正常使用。", "This candidate build is not connected to a release update channel. Installation and lyrics remain available.")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        do {
            try controller.updater.start()
            self.controller = controller
        } catch {
            configurationMessage = LyricLocalization.text("更新服务未能启动：\(error.localizedDescription)", "The update service could not start: \(error.localizedDescription)")
        }
    }
    /// nil means Sparkle opened its real update flow; never report "up to date"
    /// when no signed feed has been configured.
    func checkForUpdates() -> String? {
        guard let controller else { return configurationMessage ?? LyricLocalization.text("尚未配置更新频道。", "No update channel is configured.") }
        controller.checkForUpdates(nil)
        return nil
    }
}
