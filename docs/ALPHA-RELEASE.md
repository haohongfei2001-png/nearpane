# 本地 Alpha 与公开发行的边界

个人 Alpha 默认安装到 `/Applications/Nearpane.app`。已有个人目录安装且系统目录无同名应用时，更新沿用个人目录；首次安装遇系统目录不可写时也使用个人目录。应用标识为 `com.holdsnow.nearpane.alpha`。更新时正常退出正在运行的 Nearpane，使用 `scripts/build-candidate.sh` 将新包原子替换至原安装路径。已有 Developer ID 签名的安装须使用获准的相同签名身份，通过 `NEARPANE_LOCAL_SIGNING_IDENTITY` 传给构建脚本；发布工具会核对签名连续性。默认安装的包收据为 `build/candidate/package.json`。日常开发使用 `scripts/test.sh` 和 `scripts/build-app.sh`。独立验收可用 `NEARPANE_CANDIDATE_OUTPUT` 指定临时目录，验收结束后保留所需的归档与收据，并清理该次临时 App。各版沿用资料格式 1 和单写锁。[Alpha 使用帮助](ALPHA-HELP.md)

用户安装当前 Alpha 时只需完整的 App。窗口管理和资料导入共用签封在包内的 NearpaneAutomation。用于维护本仓库的构建工具仍在开发机上运行。为最终包验证运行环境时可从终端执行 `"<Alpha.app>/Contents/MacOS/NearpaneHost" --check-helper-runtime`。首次构建所用的 CPython 来源和 SHA-256 见[运行环境来源锁](../Dependencies/automation-runtime.json)。

P5.9 增加 Nearpane 独立反馈记录及应用内更新入口。反馈本机库位于稳定资料容器的 `Feedback` 目录，处于各个 `generations` 之外，资料导入与回退保留反馈草稿和原回执。更新框架固定在[更新来源锁](../Dependencies/update-runtime.json)，安装包内各二进制的实际数量及指纹见当次包收据。Nearpane 签名发布通道就绪后才允许联网检查，所需发布配置及安装边界见[应用内更新](APPLICATION-UPDATES.md)。

交付前在本机对冻结的 Alpha 运行以下离线检查。

- `python3 scripts/check-alpha-distribution.py "<Alpha.app>"`。核对完整 bundle seal、稳定身份、所有 Mach-O 的 arm64 slice 与系统版本下限。增加 `--require-distribution-signatures` 时，本地临时签名必须以状态 2 拒绝。成功核对本地签名不是公证。
- `python3 scripts/rehearse-alpha-signing.py "<Alpha.app>"`。在临时副本上从内向外签署各助手和应用，更新内嵌指纹，再复核签名及输入原件。演练只使用本地临时签名。

真正发行前需要受权的 Developer ID、正式 entitlement 及 TCC 责任主体复核、所有嵌套代码的一致签名和时间戳、公证票据与附票校验。需要在干净系统上确认：不装开发工具时可运行的范围；已授权功能所需解释和撤销；资料、Keychain、辅助功能身份和旧版回退。当前 Apple Silicon Alpha 的完整集成部署下限为 macOS 26；本轮原生验收仅覆盖本机 build，不代表所有 26/27 版本。没有对普通窗口跨设备兼容性、整机续航或公开发行作出验收结论。

参考：[Apple 关于 macOS 分发前公证的要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。
