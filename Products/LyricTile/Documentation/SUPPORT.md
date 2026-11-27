# 支持范围与证据 · Support and evidence

更新：2026-11-27。LyricTile 是 HOLDSNOW 的独立 macOS 歌词伴侣。**当前正式版为 1.0.0 / build 49**，可从[正式 Release](https://github.com/haohongfei2001-png/nearpane/releases/tag/lyrictile-v1.0.0-build49)下载。本页说明实际跑通的使用路径及其边界；精确源码与发行记录见 [STATUS](../STATUS.md)。

本页对应正式版 **1.0.0 / build 49**，源码 `b95b6f5ed7680cbde1427a4ed1a904bd5875e17b`，[原生 CI49 / run 46024615269](https://github.com/haohongfei2001-png/nearpane/actions/runs/46024615269)。各条证据保留实际运行归属。

## 平台与播放器

首发目标是 **Apple silicon、macOS 27 或更新版本**。本轮原生运行环境为 macOS 27.0.1 arm64；没有据此承诺 Intel 或 macOS 14–26。

| 播放器 | 已有原生运行证据 | 可以据此使用和理解的范围 |
| --- | --- | --- |
| Apple Music **1.7 / build 1.7.0** | [CI49](https://github.com/haohongfei2001-png/nearpane/actions/runs/46024615269)：普通 App 的 24 项检查通过；两首原创本地 WAV、导入文件 hash、实际 persistent ID 与时长一致 | 自动识别、紧凑态、本地歌词、逐行推进、seek、暂停/恢复、hover/按钮命中、真实 next/previous、切歌清除旧词，以及返回原曲后自动恢复已有本地绑定；不是订阅曲库整体认证 |
| QQ 音乐 **11.11.1 / build 73285** | [CI49](https://github.com/haohongfei2001-png/nearpane/actions/runs/46024615269)：单首原创本地 WAV，普通 App 的 18 项检查通过 | 自动识别、本地歌词、逐行推进、seek、暂停/恢复、真实指针交互和面板显隐；暂停时遇到矛盾旧进度锚点不展示虚构进度。该测试没有验证 QQ 播放队列切歌或商业曲库 |
| 网易云音乐 **3.1.14 / build 3459** | [CI49](https://github.com/haohongfei2001-png/nearpane/actions/runs/46024615269)：官方客户端实际下载、安装并运行，单曲本地核心与 18 项普通 App 检查通过 | 单曲本地音轨的识别、歌词、逐行推进、seek、暂停/恢复与真实指针交互；未验证网易云队列切歌或商业曲库。各条支持结论以对应的真实运行记录为依据 |
| Spotify 桌面版 | 适配器存在，尚无已登录实际播放的通过记录 | **未实测**，不列为已通过的首发播放器；Connect、广告、播客和远端输出也没有被认证 |

这些本地测试使用真实安装的播放器、真实解码音频和普通 LyricTile App，未使用音乐账号。原创测试录音与歌词不随产品打包。“无需账号”仅说明这些本地路径可行，音乐服务自身的订阅和登录要求仍由对应服务决定。

播放器适配器依据实际能力显示控制。QQ/网易云通过当前系统播放源工作；不属于当前播放源时不会向其他播放器盲发命令。暂停 seek 等不受支持的操作保持不可用。未知或过期进度不会被补成已验证的时间值。

## 歌词、自动匹配与同步

在线来源为可关闭的 **LRCLIB**，默认开启并在欢迎页告知。真实接口、生产 provider/repository、中英文样本、缓存和离线恢复有单独的网络验收记录。**接口抽样、本地 LRC 播放和真实歌曲自动取词是不同的检查**。

CI49 的完整自动在线路径为 **PASS_REAL_ONLINE_SONG**：Apple Music 实际播放 Jonathan Coulton 公开提供的《Code Monkey》原录音，导入文件 hash 与官方字节一致、原始 tags 未修改、真实 current persistent ID 匹配。普通 LyricTile App 未启用原生验证模式、未注入歌词，从空缓存约 **1.382 秒**自动取得 LRCLIB **332580**，绑定到实际歌曲。8 次原生观察中，2 次完成不同当前句的严格 AX 内容 hash 与前后真实 Music 进度核对；其余观察如实保留，没有被改成通过。因此这证明单曲自动获取、绑定及原生逐行显示，不证明 seek 后即时逐帧一致、全曲库匹配率或独立声学精度。

在线测试的音频、歌词正文和第三方歌词截图均未保留或打包；清理报告确认临时数据移除、原应用数据和偏好恢复。来源、署名及权利边界保存于原始 `source-provenance.json`。公开提供的录音或 API 可访问性不被描述为不受限制的商业内容许可。

歌词能否找到以及是否适合当前录音，取决于提供方覆盖、曲名/歌手/专辑/时长等元数据、地区与版本。现场、翻唱、remix、重制等版本可能需要手动选择；没有合适歌词时保留紧凑摘要，并可导入用户自己的歌词。当前没有“全曲库”“所有播放器官方歌词”或已测错误匹配率的承诺。

首发实测以 **逐行同步** 为主。真实逐字时间标记可以被解析，但连续逐字扫光还要求与当前来源匹配的时间精度证据。逐字原生夹具不等于独立声学时钟验证；没有把每首歌曲或每个播放器的逐字准确度记为已通过。

本地导入支持 LRC/增强 LRC、TTML 和纯文本等已实现格式，可在关闭在线服务时使用。歌词内容权利归原权利人，API 接口条件和开源代码许可各有适用范围。LyricTile 不提供音乐订阅，也不代表这些播放器或歌词提供方。详见[隐私说明](PRIVACY.md)与[第三方说明](THIRD_PARTY_NOTICES.md)。

## 安装与权限

从 [LyricTile 官网](https://nearpane.com/lyrictile/) 获取 **1.0.0 / build 49** 的正式 DMG，拖入“应用程序”后启动，完成欢迎页。连接 Apple Music 或 Spotify 时，macOS 会按需请求 Automation；如果之前拒绝，可在“系统设置 → 隐私与安全性 → 自动化”允许对应播放器。LyricTile 不需要自己的登录账号。

日常使用不要求 LyricTile 获得“辅助功能”或“屏幕录制”权限。云端测试助手的原生指针和截图能力属于验收环境，并没有变成用户的安装步骤。具体安装、升级及权限恢复操作见[安装说明](INSTALL.md)。

## 如何理解验收证据

- **真实 macOS 运行**：生产编译、App 启动、实际播放器与文件 hash、控制 trace/readback、源进度、原生窗口、OS 指针事件和资源采样。OS 事件是原生命中证据，没有声称测试了实体鼠标硬件。
- **原生夹具**：真实 AppKit/SwiftUI 布局与渲染，配合原创样词覆盖长句、英文、深浅色和不同窗口宽度；它们不替代真实播放源。
- **实际壁纸**：[CI44 保存的原图与像素复核](Verification/2026-11-27-release-candidate/ci44-regression/README.md) 已确认浅色 App 在浅色、深色、繁忙壁纸上的实际可读性，来自同一 WindowServer 面板、1× 显示。CI49 的三壁纸矩阵因公开桌面 API 未读回请求壁纸而 BLOCKED，没有产生该矩阵截图；原壁纸与 QQ 窗口状态已恢复，不能把它写成本轮三壁纸通过。没有把深色壁纸当成深色 App，也没有把可列举的显示模式写成已测 2×。
- **网络与浏览器**：歌词服务请求、官网及下载入口各自保存证据；网页结果不作为 macOS 播放或原生 UI 通过的依据。

## 正式发行与验收记录

**1.0.0 / build 49** 的正式 ZIP、DMG 和 [SHA256SUMS](https://github.com/haohongfei2001-png/nearpane/releases/download/lyrictile-v1.0.0-build49/SHA256SUMS) 见[同一 Release](https://github.com/haohongfei2001-png/nearpane/releases/tag/lyrictile-v1.0.0-build49)。正式安装包已使用 Developer ID 签名并通过 Apple 公证。DMG SHA-256：`a6813cbebc59ae465e215d2ab5053d7591bb0fef8e89644a1723f58ed6e58329`。

原生播放、网络、签名、公证和升级各自保留对应原始记录，详见 [STATUS](../STATUS.md)。近期空闲及逐行运行采样有各自真实测值；没有据短时结果宣称新八小时或独立逐字精度通过。

首发依据已实际通过的播放器与路径，不要求四个播放器同时通过、每首歌完美逐字或重复所有历史长稳实验。实际缺陷和明确未测范围仍按原始记录处理。

## English

LyricTile is an independent HOLDSNOW companion for **Apple silicon Macs running macOS 27 or later**. The native cloud environment is macOS 27.0.1 arm64. The current release is **1.0.0 / build 49**, source `b95b6f5ed7680cbde1427a4ed1a904bd5875e17b`, from [CI49](https://github.com/haohongfei2001-png/nearpane/actions/runs/46024615269). [STATUS](../STATUS.md) records the complete run result and signing state; the rows below identify each actual verification run.

| Player | Observed native scope |
| --- | --- |
| **Apple Music 1.7 / build 1.7.0** | CI49 passed 24 ordinary-app checks using two authored local recordings: identification, local lyrics, line progression, seeking, pause/resume, native hover/button events, next/previous, lyric replacement and automatic recovery of the original local binding. Actual imported hashes, track IDs and durations were verified. |
| **QQ Music 11.11.1 / build 73285** | CI49 passed 18 ordinary-app checks using one authored local recording: identification, local lyrics, line progression, seek, pause/resume, native pointer input and panel visibility. Queue switching and the commercial catalog were not tested. |
| **NetEase 3.1.14 / build 3459** | CI49 downloaded, installed and ran the actual official client, then passed the corresponding single-track local core and 18 ordinary-app checks. Queue switching and the commercial catalog were not tested. The support statement is based on this actual client run. |
| **Spotify desktop** | The adapter is implemented, but actual signed-in playback remains unverified. Spotify, Connect, ads, podcasts and remote outputs are not listed as qualified paths. |

These local tests used actual players and audio without an account. They do not establish whole-catalog coverage, subscription playback, every recording version or independent word-level timing. Online LRCLIB service probes and full automatic lookup during real playback are recorded separately. Lyrics availability depends on provider coverage and metadata; local imports remain available when online lookup is disabled or no suitable lyrics are found.

CI49's separate **PASS_REAL_ONLINE_SONG** result used Jonathan Coulton's publicly offered original recording of *Code Monkey* in actual Apple Music. The ordinary app used neither verification mode nor injected lyrics. Starting with an empty cache, it automatically resolved LRCLIB **332580** in **1.382 seconds** and bound it to the real track ID. Two of eight native observations strictly matched two distinct current-line hashes to actual Music position readbacks; other observations remain recorded as unmatched. This verifies that one recording's automatic lookup and native line display worked, without certifying every frame immediately after seeking or independent acoustic accuracy. The original audio hash and unchanged tags were checked. Test audio, lyric bodies and third-party lyric screenshots were not retained or distributed, and cleanup restored prior app data and preferences. Public availability is not treated as unrestricted commercial content licensing.

The first release is qualified primarily for line-level synchronization. Word-level parsing and authored rendering fixtures do not certify acoustic timing accuracy. The historical CI44 light-app/three-wallpaper/1× desktop check remains distinct from current native screenshots, browser and service tests. CI49's wallpaper matrix was BLOCKED when the public desktop API did not read back the requested wallpaper; no matrix captures were produced, and the original desktop and QQ window state were restored.

Download the signed and notarized **1.0.0 / build 49** DMG from the LyricTile product page, drag the app into Applications, and complete onboarding. Grant Automation for the chosen Music or Spotify connection when requested. Normal use does not require Accessibility or Screen Recording access, and LyricTile has no account requirement of its own. Online lookup is disclosed during onboarding and can be disabled in Settings; see [installation](INSTALL.md) and [privacy](PRIVACY.md).

**The consumer release is Developer ID signed and Apple notarized.** Download its ZIP or DMG and [SHA256SUMS](https://github.com/haohongfei2001-png/nearpane/releases/download/lyrictile-v1.0.0-build49/SHA256SUMS) from [the build 49 Release](https://github.com/haohongfei2001-png/nearpane/releases/tag/lyrictile-v1.0.0-build49). The DMG SHA-256 is `a6813cbebc59ae465e215d2ab5053d7591bb0fef8e89644a1723f58ed6e58329`. [STATUS](../STATUS.md) links the actual release and upgrade evidence. Native playback, service checks and short resource samples retain their measured scope; they are not described as a new eight-hour or independent word-timing qualification.
