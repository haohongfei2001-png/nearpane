# LyricTile · HOLDSNOW

**歌词，自然在旁。** LyricTile 是 HOLDSNOW 的独立 macOS 歌词伴侣，使用你已有的音乐播放器，无需启动 Nearpane。

**LyricTile 1.0.0 · build 49 已发布。** [下载 Mac 版 DMG](https://github.com/haohongfei2001-png/nearpane/releases/download/lyrictile-v1.0.0-build49/LyricTile-1.0.0-49-arm64.dmg) · [发行说明与校验文件](https://github.com/haohongfei2001-png/nearpane/releases/tag/lyrictile-v1.0.0-build49)。正式安装包使用 Developer ID 签名并通过 Apple 公证。

本版源码为 `b95b6f5ed7680cbde1427a4ed1a904bd5875e17b`，[原生 CI49](https://github.com/haohongfei2001-png/nearpane/actions/runs/46024615269) 与 [STATUS](STATUS.md) 保存实际验收范围和发行记录。DMG 的 SHA-256 为 `a6813cbebc59ae465e215d2ab5053d7591bb0fef8e89644a1723f58ed6e58329`；也可核对同一 Release 的 [SHA256SUMS](https://github.com/haohongfei2001-png/nearpane/releases/download/lyrictile-v1.0.0-build49/SHA256SUMS)。

适用于 **Apple silicon、macOS 27 或更新版本**。[中文产品页](https://nearpane.com/lyrictile/) · [English website](https://nearpane.com/lyrictile/en/) · [安装说明](Documentation/INSTALL.md) · [真实支持范围](Documentation/SUPPORT.md) · [隐私说明](Documentation/PRIVACY.md)

## 日常使用

- 开始播放音乐，歌词自然出现；暂停后离开面板，或没有播放内容时，面板收起并释放桌面空间。
- 当前句居中突出，上下文逐级弱化。长句会换行并调整上下文，特别长的内容可在原生视图内滚动。
- 鼠标移到面板，查看封面、曲名、歌手、播放控制和可用进度；没有歌词时保留紧凑的音乐摘要。
- 可选在线查词，也可导入自己的 LRC、增强 LRC、TTML 或纯文本歌词。设置页提供外观、字号、歌词来源和桌面排列选项。

## 已实际验证的播放器

以下是有原始 macOS 运行证据的具体路径。播放器版本、实际运行记录与未覆盖范围详见 [SUPPORT](Documentation/SUPPORT.md)。

| 播放器 | 已验证的使用路径 |
| --- | --- |
| Apple Music 1.7 / build 1.7.0 | 两首原创本地音轨；自动识别、本地歌词、逐行推进、seek、暂停/恢复、真实 hover/按钮事件、next/previous、返回原曲自动恢复已绑定歌词；[CI49 的 24 项原生检查](https://github.com/haohongfei2001-png/nearpane/actions/runs/46024615269) |
| QQ 音乐 11.11.1 / build 73285 | 一首原创本地音轨；自动识别、本地歌词、逐行推进、seek、暂停/恢复和实际指针交互；[CI49 的 18 项原生检查](https://github.com/haohongfei2001-png/nearpane/actions/runs/46024615269) |
| 网易云音乐 3.1.14 / build 3459 | 一首原创本地音轨；自动识别、本地歌词、逐行推进、seek、暂停/恢复和实际指针交互；[CI49 的 18 项原生检查](https://github.com/haohongfei2001-png/nearpane/actions/runs/46024615269) |
| Spotify 桌面版 | 适配器已经实现，尚无已登录实际播放的通过记录，不列为已实测支持 |

这些本地播放检查使用真实客户端、真实音频和普通 LyricTile App，无需音乐账号。它们不代表订阅曲库、广告、Connect、每个录音版本或所有歌曲都有歌词。在线接口抽样与“实际歌曲播放后自动取词”的完整路径分别记录，不互相替代。

**实际歌曲的自动取词也已跑通。** CI49 使用 Apple Music 播放 Jonathan Coulton 公开提供的《Code Monkey》原录音，普通 LyricTile App 从空缓存约 **1.38 秒**自动取得对应 LRCLIB 歌词；两个不同的原生当前句与真实 Music 进度读回相符。该单曲结果不代表全曲库覆盖、seek 后每帧即时一致或独立逐字精度。测试音频、歌词正文及其截图不随产品或宣传资料分发，详见支持说明中的范围。

## 安装与首次使用

1. [下载正式 DMG](https://github.com/haohongfei2001-png/nearpane/releases/download/lyrictile-v1.0.0-build49/LyricTile-1.0.0-49-arm64.dmg)，把 `LyricTile.app` 拖入“应用程序”，再从那里打开并推出安装磁盘。详见[安装说明](Documentation/INSTALL.md)。
2. 在欢迎页了解在线查词的数据使用方式，完成开始使用。LyricTile 不要求注册自己的账号；音乐服务的账号要求由所用播放器决定。
3. 打开音乐播放器并播放歌曲。连接 Apple Music 或 Spotify 时，按需允许系统“自动化”提示；权限被拒绝时，可在“系统设置 → 隐私与安全性 → 自动化”重新开启对应播放器。
4. 没有合适歌词时，使用菜单栏的本地导入或来源选择。没有有效进度时，界面不会编造一个同步时钟。

日常使用无需为 LyricTile 开启“辅助功能”或“屏幕录制”权限。云端验收的指针和截图助手使用的是测试主机已有权限，不是软件安装要求。

在线查词通过 LRCLIB 完成，默认开启并在欢迎页说明；设置中可随时关闭。查词会发送曲名、歌手、专辑及可用时长等匹配信息。本地导入可独立使用。歌词覆盖和准确匹配取决于来源、元数据及录音版本；歌词内容权利属于原权利人，API 可访问性不等同于每首歌词的内容授权。详情见[隐私与数据流](Documentation/PRIVACY.md)和[第三方说明](Documentation/THIRD_PARTY_NOTICES.md)。

**首发实际核验以逐行同步为主。** 连续逐字扫光还需要真实逐字时码和对应的时间精度证据；目前不承诺所有歌曲逐字，也不把原生夹具当作独立逐字准确度验收。本版运行及发行记录分别保留实际测试条件；短时资源采样不作为新的八小时或逐字精度证明。

## English overview

LyricTile is an independent HOLDSNOW app for **Apple silicon Macs running macOS 27 or later**. Lyrics appear while music plays, keep the current line centered, and make room for long lines. Hover reveals artwork, track details, controls and available progress. Tracks without lyrics use a compact summary. Local imports work independently of optional LRCLIB lookup.

**LyricTile 1.0.0 · build 49 is available.** [Download the Mac DMG](https://github.com/haohongfei2001-png/nearpane/releases/download/lyrictile-v1.0.0-build49/LyricTile-1.0.0-49-arm64.dmg) · [Release notes and checksums](https://github.com/haohongfei2001-png/nearpane/releases/tag/lyrictile-v1.0.0-build49). The consumer packages are Developer ID signed and Apple notarized. The exact source is `b95b6f5ed7680cbde1427a4ed1a904bd5875e17b`; [native CI49](https://github.com/haohongfei2001-png/nearpane/actions/runs/46024615269) and [STATUS](STATUS.md) preserve the verification and release records. The DMG SHA-256 is `a6813cbebc59ae465e215d2ab5053d7591bb0fef8e89644a1723f58ed6e58329`.

CI49 passed 24 ordinary-app checks with Apple Music 1.7 and two authored local recordings, plus 18 checks each with QQ Music 11.11.1/build 73285 and NetEase 3.1.14/build 3459 using one local recording. The [support matrix](Documentation/SUPPORT.md) records the exact scope and limitations. Spotify remains unverified. These results do not qualify an entire commercial catalog, every song version or independent word-level timing.

CI49 also verified automatic lyrics during real Apple Music playback of Jonathan Coulton's publicly offered original recording of *Code Monkey*. With an empty cache, the ordinary app found the LRCLIB document in about **1.38 seconds**, and two distinct native current lines matched actual player-position readbacks. This is one observed recording, without a claim of whole-catalog coverage, immediate accuracy on every frame after seeking, or independent word timing. The test recording, lyric text and lyric screenshots are not distributed with the app or its promotional materials.

Download LyricTile 1.0.0 (49) from its product page, drag the app into Applications and complete the welcome screen. Allow Automation for the selected Apple Music or Spotify connection when macOS asks. Normal operation does not require Accessibility or Screen Recording permission. LRCLIB lookup is disclosed during onboarding and can be disabled in Settings. See the bilingual [installation](Documentation/INSTALL.md), [support](Documentation/SUPPORT.md) and [privacy](Documentation/PRIVACY.md) pages.

## Development and release references

The independent app is maintained under `Products/LyricTile`, with its own Swift package, bundle identifier (`com.holdsnow.lyrictile`), lifecycle, settings, updater and package pipeline. Future Nearpane integration uses the native view and service modules directly.

- [Current status and exact next step](STATUS.md): latest implementation, validation, remaining work and the small set of files to read next; no prior conversation retrieval is needed.
- [Complete product/design/source research](Research/2026-11-26/README_START_HERE.md): 54 archived deliverables, three high-fidelity directions, selected design, interaction specification, source pins and macOS acceptance cases.
- [Actual implementation architecture](Documentation/ARCHITECTURE.md): module boundaries, lifecycle and where earlier research was refined.
- [Native UI implementation](Documentation/UI_IMPLEMENTATION.md), [media implementation](Documentation/MEDIA_IMPLEMENTATION.md), [lyrics implementation](Documentation/LYRICS_IMPLEMENTATION_STATE.md).
- [Release continuation checklist](Documentation/LOCAL_ONLY_HANDOFF.md): the retained procedure for signing, notarizing and verifying future builds; consult STATUS before repeating any completed work.
- [Third-party notices](Documentation/THIRD_PARTY_NOTICES.md).
- [Chinese/English installation](Documentation/INSTALL.md), [privacy](Documentation/PRIVACY.md), [release checks](Documentation/RELEASE.md), and [product page](Website/README.md).

## Independent build

Use Xcode with Swift 6 on a Mac. The first distribution target is **macOS 27, Apple silicon**. Reusable sources have a macOS 14 API floor to keep the package modular; this is not a public support promise for macOS 14–26.

```sh
git switch codex/lyrictile-standalone-20261126
cd Products/LyricTile
swift test --parallel
bash Scripts/build-app.sh
open dist/LyricTile.app
```

The default build is a release-optimized, ad-hoc signed arm64 **candidate**. It includes the real pinned media helper and Sparkle framework. It produces `dist/LyricTile.app`, ZIP, DMG, checksums and bundle verification. This does not notarize or publish anything. `LYRICTILE_ARCH=x86_64` is available for host diagnostics; no Intel support qualification is claimed.

For a native UI loading check with no player, network lookup or fabricated track:

```sh
python3 Scripts/run-native-smoke.py dist/LyricTile.app --output dist/evidence
```

Tests use clearly authored fixtures under `Tests/`; production startup has no demo playlist, synthetic elapsed time or preset lyrics. The timeline projects only a real, sufficiently fresh source anchor.

## What the application does

The panel appears automatically only while an identified song is playing. Its 192-point lyric surface centers the current cue and softens surrounding context. Ordinary cues show up to two cues above and below; long cues reduce context to allow three or four complete text rows, with native scrolling for exceptionally long lines. Songs without lyrics use a 104-point summary. Hover reveals artwork, title, artist, transport, and progress in the same outer frame while retaining the current lyric. Missing artwork uses a neutral symbol; unknown fields stay unknown. No playback leaves no desktop panel. A paused song retains an already-visible panel only during interaction. Connection status, local import, and settings remain in the menu bar.

| Player | Implemented route | Route boundaries |
|---|---|---|
| Apple Music | Process-targeted ScriptingBridge metadata, progress, artwork and commands | On-demand Automation consent; cloud tracks and sleep/wake require their own evidence |
| Spotify desktop | Process-targeted ScriptingBridge and bounded official artwork download | Actual playback remains unverified; ads, podcasts, Connect and remote outputs are not qualified |
| QQ Music | Isolated MediaRemote stream/snapshot helper | Actual source participation; global commands only while the intended source owns Now Playing; paused seek disabled |
| NetEase Music | Same isolated helper, independent adapter capability state | Actual client version's timestamp/capability behavior and current-source ownership |

An installed/running player is not sufficient evidence for every control. Capabilities are derived from the actual route and observations. Commands are sent once and checked against fresh state; a successful process exit is not reported as successful playback control.

LRCLIB lookup is real and runs from the device. It is enabled by default, disclosed on the welcome screen, and can be switched off; local imports work independently. LRC/enhanced LRC/LRCX, TTML, LRCLIB Lyricsfile, and plain text normalize into one model with source provenance. Automatic matching rejects ambiguous recording versions and offers explicit candidates. API access does not establish copyright authorization for every lyric. The app contains no third-party lyric catalog. See [privacy and data flows](Documentation/PRIVACY.md).

Fresh unmeasured position anchors support ordinary line synchronization. Continuous word sweep additionally requires real token timestamps and a matching, evidence-backed position qualification; unknown precision never becomes zero. No physical qualification profile is bundled by this remote implementation. See `MEDIA_IMPLEMENTATION.md` for the exact evidence format.

## Desktop and future Nearpane integration

TileKit coordinates cooperating apps through short locked transactions and explicit withdrawal acknowledgements. A missing heartbeat never authorizes drawing over a visible window. Shared width is 176–224 points; margins are 16 points and spacing is 10 points. LyricTile reserves its actual 104/192-point height. Shrinking is briefly coalesced; expansion withdraws through the existing coordination barrier before occupying the larger slot. No playback unregisters the slot. Hover does not resize or reorder the panel.

Legacy Saytile and Riftlet versions do not yet implement that protocol. LyricTile reads only their public window geometry and avoids recognizable component windows, without moving them or requiring Accessibility/Screen Recording. This is compatibility avoidance, not a claim that old apps now negotiate reordering. Dragging in coordinated mode requests column order/display changes. Turning coordination off gives explicit local placement.

Nearpane can depend on `NearpaneLyricsModule`, embed its pure SwiftUI view and own the geometry. Explicit handoff withdraws the old surface before its module lease is released. There is one active lyrics service owner, not multiple floating apps assembled into a host UI.

## Build and release variables

| Variable | Meaning |
|---|---|
| `LYRICTILE_ARCH` | `arm64` default; native or cross build |
| `LYRICTILE_CONFIGURATION` | `release` default or `debug`; neither fabricates data |
| `LYRICTILE_VERSION`, `LYRICTILE_BUILD_NUMBER` | Bundle/display version and monotonically increasing build |
| `LYRICTILE_OUTPUT` | Generated output directory; defaults to this package's `dist` |
| `LYRICTILE_SIGN_IDENTITY` | Owner's installed Developer ID identity; defaults to ad-hoc `-` |
| `LYRICTILE_UPDATE_FEED`, `LYRICTILE_UPDATE_PUBLIC_KEY` | HTTPS appcast and real Ed25519 public key, supplied together |
| `LYRICTILE_NOTARY_PROFILE` | Existing local Keychain notary profile, used only by explicit notarization script |

Missing update configuration is shown honestly as an unconfigured candidate channel, never “up to date.” Keys, credentials, signing identities and private diagnostics are not committed. Default builds do not publish releases, enable telemetry or create an account service.

