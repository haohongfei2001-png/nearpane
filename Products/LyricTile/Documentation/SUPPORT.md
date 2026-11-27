# 支持范围与证据 · Support and evidence

更新：2026-11-27。LyricTile 是 HOLDSNOW 的独立 macOS 歌词伴侣。**当前候选、精确源码、整体验收与正式包状态见 [STATUS](../STATUS.md)**。本页说明已经实际跑通的路径及其边界；某个子项通过，不代表整个运行或正式签名已经完成。

## 平台与播放器

首发目标是 **Apple silicon、macOS 27 或更新版本**。本轮原生运行环境为 macOS 27.0.1 arm64；没有据此承诺 Intel 或 macOS 14–26。

| 播放器 | 已有原生运行证据 | 可以据此使用和理解的范围 |
| --- | --- | --- |
| Apple Music **1.7 / build 1.7.0** | [CI46](https://github.com/haohongfei2001-png/nearpane/actions/runs/46012637087)：普通 App 的 24 项检查通过；两首原创本地 WAV、导入文件 hash、实际 persistent ID 与时长一致 | 自动识别、紧凑态、本地歌词、逐行推进、seek、暂停/恢复、hover/按钮命中、真实 next/previous、切歌清除旧词，以及返回原曲后自动恢复已有本地绑定；不是订阅曲库整体认证 |
| QQ 音乐 **11.11.1 / build 73285** | [CI46](https://github.com/haohongfei2001-png/nearpane/actions/runs/46012637087)：单首原创本地 WAV，普通 App 的 18 项检查通过 | 自动识别、本地歌词、逐行推进、seek、暂停/恢复、真实指针交互和面板显隐；暂停时遇到矛盾旧进度锚点不展示虚构进度。该测试没有验证 QQ 播放队列切歌或商业曲库 |
| 网易云音乐 **3.1.14 / build 3459** | [CI45](https://github.com/haohongfei2001-png/nearpane/actions/runs/46009188167)：单曲本地核心与 18 项普通 App 检查通过；CI45 与 CI46 的生产 `Sources` 无差异 | 单曲本地音轨的识别、歌词、逐行推进、seek、暂停/恢复与真实指针交互已有证据。CI46 官方 DMG 下载触及时间边界，未运行该客户端；不能把下载 BLOCKED 写成该轮播放 PASS。未验证网易云队列切歌或商业曲库 |
| Spotify 桌面版 | 适配器存在，尚无已登录实际播放的通过记录 | **未实测**，不列为已通过的首发播放器；Connect、广告、播客和远端输出也没有被认证 |

这些本地测试使用真实安装的播放器、真实解码音频和普通 LyricTile App，未使用音乐账号。原创测试录音与歌词不随产品打包。“无需账号”仅说明这些本地路径可行，音乐服务自身的订阅和登录要求仍由对应服务决定。

播放器适配器依据实际能力显示控制。QQ/网易云通过当前系统播放源工作；不属于当前播放源时不会向其他播放器盲发命令。暂停 seek 等不受支持的操作保持不可用。未知或过期进度不会被补成已验证的时间值。

## 歌词、自动匹配与同步

在线来源为可关闭的 **LRCLIB**，默认开启并在欢迎页告知。真实接口、生产 provider/repository、中英文样本、缓存和离线恢复有单独的网络验收记录。**接口抽样、本地 LRC 播放和真实歌曲自动取词是不同的检查**；完整自动在线路径的结果以 STATUS 所列的独立原始报告为准。

歌词能否找到以及是否适合当前录音，取决于提供方覆盖、曲名/歌手/专辑/时长等元数据、地区与版本。现场、翻唱、remix、重制等版本可能需要手动选择；没有合适歌词时保留紧凑摘要，并可导入用户自己的歌词。当前没有“全曲库”“所有播放器官方歌词”或已测错误匹配率的承诺。

首发实测以 **逐行同步** 为主。真实逐字时间标记可以被解析，但连续逐字扫光还要求与当前来源匹配的时间精度证据。逐字原生夹具不等于独立声学时钟验证；没有把每首歌曲或每个播放器的逐字准确度记为已通过。

本地导入支持 LRC/增强 LRC、TTML 和纯文本等已实现格式，可在关闭在线服务时使用。歌词内容权利归原权利人，API 接口条件和开源代码许可各有适用范围。LyricTile 不提供音乐订阅，也不代表这些播放器或歌词提供方。详见[隐私说明](PRIVACY.md)与[第三方说明](THIRD_PARTY_NOTICES.md)。

## 安装与权限

正式包发布后，从 [LyricTile 官网](https://nearpane.com/lyrictile/) 获取对应 DMG，拖入“应用程序”后启动，完成欢迎页。连接 Apple Music 或 Spotify 时，macOS 会按需请求 Automation；如果之前拒绝，可在“系统设置 → 隐私与安全性 → 自动化”允许对应播放器。LyricTile 不需要自己的登录账号。

日常使用不要求 LyricTile 获得“辅助功能”或“屏幕录制”权限。云端测试助手的原生指针和截图能力属于验收环境，并没有变成用户的安装步骤。具体安装、升级及权限恢复操作见[安装说明](INSTALL.md)。

## 如何理解验收证据

- **真实 macOS 运行**：生产编译、App 启动、实际播放器与文件 hash、控制 trace/readback、源进度、原生窗口、OS 指针事件和资源采样。OS 事件是原生命中证据，没有声称测试了实体鼠标硬件。
- **原生夹具**：真实 AppKit/SwiftUI 布局与渲染，配合原创样词覆盖长句、英文、深浅色和不同窗口宽度；它们不替代真实播放源。
- **实际壁纸**：[CI44 保存的原图与像素复核](Verification/2026-11-27-release-candidate/ci44-regression/README.md) 已确认浅色 App 在浅色、深色、繁忙壁纸上的实际可读性，来自同一 WindowServer 面板、1× 显示。没有把深色壁纸当成深色 App，也没有把可列举的显示模式写成已测 2×。
- **网络与浏览器**：歌词服务请求、官网及下载入口各自保存证据；网页结果不作为 macOS 播放或原生 UI 通过的依据。

## 当前发行与历史结果

当前云端安装包是 **ad-hoc 工程候选**。Developer ID 签名、Apple 公证和同一最新签名包的升级结果，须由其对应的正式发行记录证明；在此之前，官网保持正式下载准备中。工程 Release 草稿用于保存候选及证据，不会自动成为正式下载或更新 feed。

旧 **build 4** 的实机 Apple Music/QQ 播放、八小时运行、公证及 **build 2→4** Sparkle 升级属于历史同一包基线。它们不替代当前界面、当前源码、最新安装包或 build 4→最新包的升级验证。近期空闲和逐行运行采样有各自真实测值，没有被描述为新八小时或逐字性能资格。

首发依据已实际通过的播放器与路径，不要求四个播放器同时通过、每首歌完美逐字或重复所有历史长稳实验。实际缺陷和明确未测范围仍按原始记录处理。

## English

LyricTile is an independent HOLDSNOW companion for **Apple silicon Macs running macOS 27 or later**. The native cloud environment is macOS 27.0.1 arm64. [STATUS](../STATUS.md) identifies the exact candidate, source, complete run result and signing state.

| Player | Observed native scope |
| --- | --- |
| **Apple Music 1.7 / build 1.7.0** | CI46 passed 24 ordinary-app checks using two authored local recordings: identification, local lyrics, line progression, seeking, pause/resume, native hover/button events, next/previous, lyric replacement and automatic recovery of the original local binding. Actual imported hashes, track IDs and durations were verified. |
| **QQ Music 11.11.1 / build 73285** | CI46 passed 18 ordinary-app checks using one authored local recording: identification, local lyrics, line progression, seek, pause/resume, native pointer input and panel visibility. Queue switching and the commercial catalog were not tested. |
| **NetEase 3.1.14 / build 3459** | CI45 passed the corresponding single-track local core and 18 ordinary-app checks. Its production Sources are unchanged in CI46, but CI46's official installer download timed out before NetEase could run. That BLOCKED download is not a fresh playback pass. |
| **Spotify desktop** | The adapter is implemented, but actual signed-in playback remains unverified. Spotify, Connect, ads, podcasts and remote outputs are not listed as qualified paths. |

These local tests used actual players and audio without an account. They do not establish whole-catalog coverage, subscription playback, every recording version or independent word-level timing. Online LRCLIB service probes and full automatic lookup during real playback are recorded separately. Lyrics availability depends on provider coverage and metadata; local imports remain available when online lookup is disabled or no suitable lyrics are found.

The first release is qualified primarily for line-level synchronization. Word-level parsing and authored rendering fixtures do not certify acoustic timing accuracy. Current native screenshots and the explicitly scoped light-app/three-wallpaper/1× desktop check remain distinct from browser and service tests.

When the signed consumer release is available, download its DMG from the LyricTile product page, drag the app into Applications, and complete onboarding. Grant Automation for the chosen Music or Spotify connection when requested. Normal use does not require Accessibility or Screen Recording access, and LyricTile has no account requirement of its own. Online lookup is disclosed during onboarding and can be disabled in Settings; see [installation](INSTALL.md) and [privacy](PRIVACY.md).

**The signed consumer package is being prepared.** Current engineering packages have ad-hoc signatures. An unpublished engineering draft does not publish the consumer download or update feed. Build 4's notarization, eight-hour run and build 2→4 update are historical evidence for that build; the latest signed package needs its own release and upgrade verification.
