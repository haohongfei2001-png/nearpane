# LyricTile 1.0.0 (2) 安装候选包

源码 `b28d9881a0c87b83eb00995072c6155da699b01c`。本机 macOS 27.0（26A428）、arm64、Swift 6.4。bundle ID 为 `com.holdsnow.lyrictile`。Developer ID Application 团队 `ZB9D4T66QB`。ZIP 仅包含 `LyricTile.app`，DMG 包含独立 App 和指向 `/Applications` 的安装快捷方式。图标的 10 个 ICNS 图层可解码，覆盖 16–1024 像素。

| 交付文件 | SHA256 |
|---|---|
| `LyricTile-1.0.0-2-arm64.dmg` | `baeacac6205922f2997388384bd424daabd2a793be07f74d8554c20494f57675` |
| `LyricTile-1.0.0-2-arm64.zip` | `235b69918ede4180d6138eb9a729d42e97108add3045da27356f0695a51ea168` |

Apple 返回 App 提交 `98b9ab70-9c90-4da0-9b66-49b87fb76094` 和 DMG 提交 `1fcf5ce4-a1a8-49f2-bd09-2578ca4cc7ef` 的状态均为 `Accepted`。分别装订后 `stapler validate` 和 Gatekeeper 均通过，来源为 `Notarized Developer ID`。本机只读挂载最终 DMG，将应用复制至独立安装目录，卸载卷后再次验证该副本的完整代码签名、公证票据和 Gatekeeper，全部通过。

从该安装副本的 Info.plist 取得真实公开 HTTPS 频道，并通过上游 Sparkle 2.10.1 的 `sparkle-cli --probe` 直接查询，回报 `No new update available!`。公开 appcast HTTP 200，当前条目为 0，验证时的 SHA256 为 `a3da4ec90bf664670bfa4f860924702307f4e9c9858c0b427a72b489c6e4a445`。隔离安装测试的范围见 [Sparkle 实机记录](sparkle-install.md)。正式 ZIP 已使用 LyricTile 专属 Ed25519 密钥签名，CryptoKit 使用 App 内公钥独立验签通过。空目录随后也已签名。公开下载待发行决定。

最终 ZIP 的 Sparkle `edSignature` 为 `E7gRSCzxuVzpXAERoX3FQGE409QSfAxNE4+b6gX2uwHICsyUbJjrGTj/Y/wxPwt6ONMA0mV3CBzHUneStFGCCw==`。

实装升级已完成。用最初的本机 build 1 制作隔离副本，加上产品正式公钥和 feed 后重新进行 Developer ID 签名。上游 Sparkle 安装器读取经产品密钥签名的回环测试目录，安装上述原封不动的公证 ZIP。读回 build 2 的 Info.plist 和可执行文件字节与 DMG 内副本一致，安装后的签名、stapler、Gatekeeper 全部通过。详见 [安装读回](upgrade-to-build2.json)。公网空目录签名后重新获取为 HTTP 200，SHA256 为 `816dddb628be95e46b3b46e57e4fc6be337be5ee4c1ac93102c3467f275a49c0`。
