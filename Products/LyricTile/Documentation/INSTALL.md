# 安装与使用 · Installation

## 中文

**系统要求：Apple silicon Mac，macOS 27 或更新版本。** LyricTile 独立运行，不需要安装 Nearpane。

当前最新源码与云端候选见 [STATUS](../STATUS.md)；旧 build 4 已公证，但它早于现有界面。不要把旧安装包当成最新版。尚未发布正式包时，官网会显示候选状态，不提供指向旧包的正式下载按钮。GitHub Actions 候选供工程核验，通常需要 GitHub 登录，临时签名不能替代 Developer ID 和公证。

正式安装包发布后的流程：

1. 从产品页的正式下载入口获取 DMG。可以与同一 Release 的 `SHA256SUMS` 核对。
2. 打开 DMG，把 LyricTile 拖入“应用程序”，从“应用程序”启动，然后推出安装磁盘。
3. 阅读欢迎页。在线歌词默认开启，可在那里或设置中关闭。
4. 在支持的播放器中播放歌曲。系统需要时允许 LyricTile 控制该音乐播放器。仅拒绝这项权限时，可从菜单栏的权限引导重新尝试；也可在“系统设置 → 隐私与安全性 → 自动化”调整。
5. 播放时歌词板自动出现。悬停显示音乐信息、播放控制和进度；停止播放后自动隐藏。

没有匹配歌词时会显示紧凑歌曲摘要。可以通过歌曲菜单导入 LRC、TTML、Lyricsfile 或纯文本，或选择其他歌词版本。没有时间标记的纯文本不宣称自动同步。时间偏差可在歌曲菜单中校准。切换到直播版、翻唱或重制版时，请核对实际版本。

更新通过应用菜单中的更新入口使用本产品专用 Sparkle 通道。也可以退出 LyricTile 后，从新 DMG 替换应用程序中的同名应用；无需删除歌词目录或偏好。确认最新包的版本、构建号和来源后再安装。

常见情况：

- **没有面板：** 先确认播放器确实正在播放歌曲，及菜单栏显示的来源是否正确；暂停后自动隐藏属于设计行为。
- **显示歌曲但没有歌词：** 检查在线查找开关和网络，尝试其他版本或导入本地文件。歌词覆盖率取决于内容来源。
- **歌词不随播放移动：** 当前播放器可能没有提供可用进度；无时码歌词也不会被伪造为同步歌词。
- **控制按钮不可用：** 控制能力取决于播放器当前状态及系统媒体来源归属，不可用时不向其他播放器误发命令。

[真实支持范围](SUPPORT.md) · [隐私](PRIVACY.md) · [第三方许可](THIRD_PARTY_NOTICES.md)

## English

**Requirements: an Apple silicon Mac running macOS 27 or later.** LyricTile runs independently; Nearpane is not required.

See [STATUS](../STATUS.md) for the latest source and cloud candidate. Notarized build 4 predates the current interface and is not the latest release. Until a final package is published, the product page shows candidate status and does not present an old package as a current download. GitHub Actions packages are engineering candidates, usually require GitHub sign-in, and use ad-hoc signing rather than Developer ID notarization.

When the final installer is available:

1. Download its DMG from the product page. Optionally compare its checksum with `SHA256SUMS` from the same release.
2. Open the DMG, drag LyricTile to Applications, launch that installed copy, and eject the installer disk.
3. Read the welcome screen. Online lookup is initially on and can be turned off there or in settings.
4. Play a song in a supported player. Allow macOS Automation access to that player when requested. If denied, retry using the menu-bar guidance or change it in System Settings → Privacy & Security → Automation.
5. The lyrics panel appears during playback. Hover for artwork, song details, controls, and progress. It hides when playback stops.

If lyrics are unavailable, a compact song summary remains. The song menu lets you import LRC, TTML, Lyricsfile, or plain text; choose another lyric version; and adjust timing. Plain text without time tags does not provide synchronized lyrics. Check the recording version for live, cover, and remastered tracks.

Use the app's update menu for the dedicated LyricTile Sparkle channel, or quit the app and replace it from a newer DMG. You do not need to remove your saved lyrics or preferences.

If no panel appears, confirm that a song is playing and the selected source is correct. If song details appear without lyrics, check online lookup and connectivity or import a local file. Unavailable controls or synchronization indicate that the player is not supplying the needed capability or timing information.

[Verified support](SUPPORT.md) · [Privacy](PRIVACY.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)
