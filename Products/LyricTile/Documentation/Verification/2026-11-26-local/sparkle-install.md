# 本机 Sparkle 安装验证

2026-11-26，macOS 27.0 (26A428)，arm64。以 `2e515ada576c` 的本机 release 核心程序与 Sparkle 2.10.1 制作两份隔离副本，保留原始可执行文件，使用测试专用 bundle ID、build 1/2、一次性 Ed25519 公钥和本机回环服务。两份 App 与上游同一源码编译的 `sparkle-cli` 均使用相同的 Developer ID 团队签名。测试打开签名 feed 和解压前校验。

| 实际安装步骤 | 结果 |
|---|---|
| 正确签名的 feed 提供错误 Ed25519 ZIP 签名 | Sparkle 下载完整 ZIP 并报告 improperly signed；返回 1，读取已安装版本仍为 1 |
| 等待安装器退出后提供正确签名 | Sparkle 下载、解压、安装，返回 0；读取已安装版本为 2，`codesign --verify --deep --strict` 成功 |

本次测试 ZIP 的 SHA256 为 `9b71a947637ea0b22c93ccef565b5594548b6ec6c999c3d166678f477bf6d083`。临时密钥和测试副本随测试目录清理。以上结果覆盖本机 Sparkle 安装器，不涉及真实应用菜单、正式密钥或公网更新文件传输。

本机只有 CLT 27.0，其 SwiftUI SDK 缺少 StateMacro 插件。构建时用 `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` 运行 `Scripts/build-app.sh`，应用的安装下限保持 macOS 27.0。实机链接器还会嵌入机器的 CLT 绝对搜索路径；打包脚本在签名前清除本地绝对 rpath，保留系统和包内相对路径。复制独立 App、移除该路径、重新签名后 `verify-bundle.py` 全部检查通过。
