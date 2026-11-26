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
            configurationMessage = "这是独立候选构建，尚未连接正式更新频道。安装与歌词功能可以正常使用。"
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        do {
            try controller.updater.start()
            self.controller = controller
        } catch {
            configurationMessage = "更新服务未能启动：\(error.localizedDescription)"
        }
    }
    /// nil means Sparkle opened its real update flow; never report "up to date"
    /// when no signed feed has been configured.
    func checkForUpdates() -> String? {
        guard let controller else { return configurationMessage ?? "尚未配置更新频道。" }
        controller.checkForUpdates(nil)
        return nil
    }
}
