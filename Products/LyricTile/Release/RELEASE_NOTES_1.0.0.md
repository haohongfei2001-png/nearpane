# LyricTile 1.0.0 · build 49

## 中文

LyricTile 是 HOLDSNOW 的独立 macOS 歌词伴侣。音乐播放时，歌词自然出现在桌面；暂停后移开指针，面板便自动收起。适用于 **Apple silicon Mac，macOS 27 或更新版本**，无需安装 Nearpane。

### 随音乐出现，随手控制

- 歌词居中显示，当前句突出，上下文逐级弱化；长句自动换行。
- 悬停即可查看封面、曲名、歌手、播放控制和进度。
- 没有合适歌词时，保留紧凑的歌曲摘要。
- 中文、英文界面，支持深浅色；欢迎页与设置保持简洁。

### 安装

1. 下载下方附件 **`LyricTile-1.0.0-49-arm64.dmg`**。
2. 打开 DMG，把 LyricTile 拖入“应用程序”，再从“应用程序”启动并推出安装磁盘。
3. 完成欢迎页，在支持的播放器中播放音乐。macOS 按需询问时，允许 LyricTile 控制相应播放器。

本次正式安装包使用 Developer ID 签名，并已通过 Apple 公证。`SHA256SUMS` 提供本次 ZIP 和 DMG 的校验值。已有用户可以使用应用内的更新入口，也可以退出 LyricTile 后从新 DMG 替换应用，无需删除偏好或本地歌词。

### 播放器与歌词

**Apple Music 1.7、QQ 音乐 11.11.1、网易云音乐 3.1.14** 已实测本地音轨的自动识别、逐行歌词、进度跳转、暂停与恢复、悬停控制和自动显隐。Apple Music 还验证了两首歌曲之间的切换，以及返回原曲后恢复已导入歌词。

自动在线查词已在 Apple Music 播放 Jonathan Coulton 的 *Code Monkey* 时完成实际验证。歌词覆盖率和同步效果会随歌曲、录音版本及播放器提供的信息而变化；现场、翻唱和重制版本可能需要另选歌词。**Spotify 尚未完成实际播放验证**。这些结果不代表订阅曲库整体覆盖，也不承诺每首歌的逐字精度。

在线歌词通过 **LRCLIB** 查找，默认开启，会发送当前歌曲的曲名、歌手等匹配信息；可在欢迎页或设置中关闭。也可从歌曲菜单导入 LRC、TTML、Lyricsfile 或纯文本。没有时间标记的文本不会自动同步。LyricTile 无需注册账号。

[官网与下载](https://nearpane.com/lyrictile/) · [使用帮助](https://nearpane.com/lyrictile/help.html) · [隐私说明](https://nearpane.com/lyrictile/privacy.html)

---

## English

LyricTile is an independent macOS lyrics companion from HOLDSNOW. Lyrics appear on your desktop while music plays; after you pause and move the pointer away, the panel tucks itself away. Requires an **Apple silicon Mac running macOS 27 or later**. Nearpane is not required.

### Lyrics and controls, close at hand

- Centered lyrics emphasize the current line and gently fade the surrounding context. Long lines wrap to fit.
- Hover to see artwork, track details, playback controls and progress.
- A compact track summary stays available when suitable lyrics cannot be found.
- Chinese and English interfaces, light and dark appearances, and a simple welcome screen and settings.

### Install

1. Download **`LyricTile-1.0.0-49-arm64.dmg`** from this release's assets.
2. Open the DMG, drag LyricTile into Applications, launch that installed copy, and eject the installer disk.
3. Complete the welcome screen and play music in a supported player. Allow macOS Automation access to that player when requested.

The consumer packages in this release are Developer ID signed and Apple notarized. Use `SHA256SUMS` to verify the ZIP or DMG. Existing users can use the app's update menu, or quit LyricTile and replace the app from the new DMG. Keep your saved preferences and local lyrics.

### Players and lyrics

**Apple Music 1.7, QQ Music 11.11.1 and NetEase Cloud Music 3.1.14** have been tested with local recordings for track identification, line synchronization, seeking, pause/resume, hover controls and automatic visibility. Apple Music also passed switching between two tracks and restoring the original track's imported lyrics on return.

Automatic online lookup was verified during actual Apple Music playback of Jonathan Coulton's *Code Monkey*. Lyrics availability and synchronization depend on the song, recording version and information supplied by the player. Live, cover and remastered recordings may need another lyric version. **Spotify playback remains unverified.** These results do not establish subscription catalog coverage or precise word timing for every song.

Online lookup uses **LRCLIB** and is initially enabled. It sends the current song's title, artist and other matching details; you can turn it off during onboarding or in Settings. The song menu also accepts local LRC, TTML, Lyricsfile and plain text files. Text without time tags does not synchronize automatically. LyricTile does not require an account.

[Website and download](https://nearpane.com/lyrictile/en/) · [Help](https://nearpane.com/lyrictile/en/help.html) · [Privacy](https://nearpane.com/lyrictile/en/privacy.html)

---

### Version and verification · 版本与验收

- **Version / 版本:** 1.0.0 · **Build / 构建号:** 49
- **Source / 源码:** [`b95b6f5ed7680cbde1427a4ed1a904bd5875e17b`](https://github.com/haohongfei2001-png/nearpane/commit/b95b6f5ed7680cbde1427a4ed1a904bd5875e17b)
- **Native verification / 原生验收:** [macOS CI49](https://github.com/haohongfei2001-png/nearpane/actions/runs/46024615269)
- **Checksums / 校验文件:** `SHA256SUMS` in this release's assets / 见本次发行附件。
