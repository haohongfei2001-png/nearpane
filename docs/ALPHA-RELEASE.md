# 本地 Alpha 与公开发行的边界

个人 Alpha 使用固定标识 `com.holdsnow.nearpane.alpha`、资料格式 1 和单写锁。构建新版本时保留上一版应用，不在旧应用上重新签名，也不让两版同时使用活动资料。实际启动方式和遇到问题时的处理见[使用帮助](ALPHA-HELP.md)。

在本机可以离线运行两项检查（参数是已经冻结的 Alpha 路径）：

- `python3 scripts/check-alpha-distribution.py "<Alpha.app>"`。核对完整 bundle seal、稳定身份、所有 Mach-O 的 arm64 slice 与系统版本下限。增加 `--require-distribution-signatures` 时，本地临时签名必须以状态 2 拒绝。成功核对本地签名不是公证。
- `python3 scripts/rehearse-alpha-signing.py "<Alpha.app>"`。在临时副本演练由内而外的签名：两个只读助手和普通窗口控制助手先签，更新夹具和 Host 的三个 SHA-256 绑定，再签两个子应用，最后签 Host。重新核对全部代码和绑定后删除临时副本，并逐文件证明输入未改。脚本只接受本地临时签名，不会查询发布证书或向 Apple 上传。

真正发行前需要受权的 Developer ID、正式 entitlement 及 TCC 责任主体复核、所有嵌套代码的一致签名和时间戳、公证票据与附票校验。需要在干净系统上确认：不装开发工具时可运行的范围；已授权功能所需解释和撤销；资料、Keychain、辅助功能身份和旧版回退。当前 Apple Silicon Alpha 的完整集成部署下限为 macOS 26；本轮原生验收仅覆盖本机 build，不代表所有 26/27 版本。没有对普通窗口跨设备兼容性、整机续航或公开发行作出验收结论。

参考：[Apple 关于 macOS 分发前公证的要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。
