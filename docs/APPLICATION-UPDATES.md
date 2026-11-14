# Nearpane 应用内更新

Nearpane 复用 Riftlet 已采用的 Sparkle 2.10.1。框架版本、Git revision、官方二进制 ZIP 和 framework 内容摘要固定在 `Dependencies/update-runtime.json`，构建只使用经校验的本地缓存。安装包携带框架及嵌套更新助手，用户运行时无需 Swift、Python 或开发工具。

Settings 的应用页面提供每日检查开关和检查更新入口。初始自动检查关闭，用户开启后由 Sparkle 保存选择并按 86400 秒调度。后台发现更新时通过 Nearpane 菜单和 Settings 提醒，用户点击后打开 Sparkle，下载与安装由用户确认。自动下载和静默安装关闭。系统信息统计和更新说明中的 JavaScript 关闭。工具浮层和面板显隐共用同一个更新控制器。

## 独立的发布身份

计划通道固定为 `https://github.com/haohongfei2001-png/nearpane/releases/latest/download/appcast.xml`。Nearpane 的 bundle ID 为 `com.holdsnow.nearpane.alpha`。Riftlet 的 feed、公钥和版本不用于 Nearpane。

当前仓库尚无可供 Nearpane 使用的正式 Release、更新清单和更新签名公钥。包内 `SUPublicEDKey` 尚未配置时，运行时明确显示发布通道未就绪，检查入口关闭，不发起更新请求。用户可保存每日检查偏好，未来带有正式通道的版本沿用该偏好。

启用正式通道需要维护者保管 Nearpane 独立的 Ed25519 私钥，将对应的公钥加入签封 App，并发布签名 appcast、签名更新归档及一致的版本/build。私钥应使用 Sparkle 的 Keychain 或受保护发布凭据，不能写入源码或安装包。首个携带公钥的版本需要通过现有安装方式交付。Developer ID、公证和权限主体兼容仍按现有发行门禁完成。

## 验证与退出

更新清单必须签名，签名失败不设过期放行。下载包在解压前验证。Nearpane 在下载准入中要求营销版本和 build 均递增，并拒绝无签名、旧版、同版及非 HTTPS 资源。完整性和替换由 Sparkle 已验证的安装机制处理。

资料导入和切换同步核对 Sparkle 当前会话，以及已获用户同意的下载或安装。UI 会话结束不会清除安装准入，独立安装器仍可能运行。只有确定发生在安装开始前的下载取消才释放对应准入。安装前再检查当前资料操作，繁忙时保存 Sparkle 的继续安装回调，并在 Settings 提供继续入口。应用退出沿用 Host 的领域排空、窗口恢复和资料锁生命周期。Updater 不直接修改资料、不重播附件、也不对窗口发起操作。

`scripts/prepare-update-runtime.py` 获取和核验固定框架。`--offline` 要求已有正确归档。`--embed APP --sign-development` 将框架、许可和来源说明放入候选，清除构建目录 RPATH，并从内向外进行本地签封。`check-alpha-distribution.py` 检查嵌套身份、版本、系统下限及 Host 运行路径，`rehearse-alpha-signing.py` 在副本上演练完整封签。

当前离线策略测试和固定来源测试不能代替发布通道上的完整下载、替换、重启验收。正式更新包发布后，应在专用隔离资料中完成这一轮，并独立核对资料代际、UNKNOWN 和未完成恢复日志。

参考 [Sparkle 配置契约](https://sparkle-project.org/documentation/customization/)、[程序接入](https://sparkle-project.org/documentation/programmatic-setup/)，以及 [Riftlet 固定来源的更新器](https://github.com/haohongfei2001-png/Riftlet/blob/44f745a15ecb3682a9da0bda17f17a5d9fc1f07e/Sources/RiftletApp/ApplicationUpdater.swift)。
