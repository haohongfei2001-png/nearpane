# HOLDSNOW 生态与两个歌词产品源码审计

日期：2026-11-26（北京时间）。这是 Linux 环境中的 GitHub API + 实际源码审阅；未运行任何 macOS 窗口、播放器、TCC 或签名安装验证。本文所有「源码支持」都不等于已在目标 macOS 27 实测。

TileKit 的最终协议以 ../../docs/TILEKIT_PROTOCOL.md 为准；下文为初步架构分析。最终协议明确使用两阶段撤下/呈现与媒体服务生命周期锁；租约过期本身不能回收可见窗口或抢夺活进程的控制权。

## 一、固定快照

| 仓库 | 已审阅提交 | 提交日期（北京时间） | 正式发行与维护观察 |
|---|---|---|---|
| Nearpane PR #15 | `6ac5eb63c97b7597e662770bac485be61f571bb8` | 2026-11-25 22:54 | 当前开发分支 codex/r4-native-candidate-20261120；main 仍 e3f26bbaa1ba4da87da56b475f5fa6fa5daa8766，不能以 main 代表现开发 |
| Saytile main | `f3baa0a255931dbb16291690699790e3d54f8bde` | 2026-11-24 01:02 | 最新正式 v1.0.0，2026-11-24 00:56 北京时间发布 |
| Riftlet main | `2b270aec5cf57d2b4165acd52bcc730fa1052a02` | 2026-11-25 18:35 | 已是正式 v1.0.11；不可沿用 1.0.8 旧基线。另有私有 QA draft，不算正式 |
| Lyrimuse main | `9d74d785be00faca056bc9b5b1575abe7b7820ea` | 2026-11-19 18:19 | 正式 v1.14.0，11-19 发布；11-25 pushed_at 不等于 main 更新；近几次正式 v1.12/1.13/1.14 在 11 月，持续维护 |
| Lyrics-Plus main | `a6f5a32814fee2f3914414fd7fdfe0aeea4d2917` | 2026-09-30 18:16 | 正式 v2.2.20，9-30 发布；11-20 有透明度 PR #5，不能称废弃，也不把 PR 日期算进 main |

元数据另见 repository-snapshot.json。上述自有仓库 GitHub 返回 license=null；这是仓库公开许可证元数据状态，不妨碍用户授权在其自有产品内复用自有代码，也不能据此把所有第三方依赖认作自有。

## 二、现有三个产品真正的桌面契约

### 2.1 Saytile

- `WindowPlacement.initialPanel` 默认宽度是 **visibleFrame.width × 0.125**，高按 VoiceRailProportions 推导，贴可见桌面右上角；344×234 是构造中临时初值，不是真正上屏默认尺寸。不要根据该常量制作错误稿。
- 主窗口是 `.borderless + .resizable + .nonactivatingPanel` 的 NSPanel；level=.floating，canJoinAllSpaces + fullScreenAuxiliary。能成为 key 以允许编辑，不能成为 main；拖动/缩放和文本命中有分区。
- `VoicePanel` 使用 200 ms smoothstep 展开；拖跨屏时由指针选显示器；断屏恢复按相交面积、距离找最近有效屏。尊重 Reduce Motion。
- `ReferencePanelMaterial` 使用 NSVisualEffectView.popover + behindWindow；透明度与减少透明度另有处理。
- 批准界面强调：半透明浅面板、连续文字流、紫蓝环境、轻状态、复制/编辑/唯一暂停恢复。主面板不放 Logo、品牌字或长条多按钮工具栏。
- `PanelCoexistenceController` 是辅助功能驱动的**普通应用窗口与语音板避让**；它不是跨 HOLDSNOW App 的自动 Tile 排列服务，不能复用其名称就声称已解决多个 Tile 的协调。

证据：

1. [WindowPlacement.swift](https://github.com/haohongfei2001-png/saytile/blob/f3baa0a255931dbb16291690699790e3d54f8bde/Sources/SaytileKit/WindowPlacement.swift) 31–60、67–116。
2. [SaytileApp.swift](https://github.com/haohongfei2001-png/saytile/blob/f3baa0a255931dbb16291690699790e3d54f8bde/Sources/SaytileApp/SaytileApp.swift) 656–708。
3. [VoicePanel.swift](https://github.com/haohongfei2001-png/saytile/blob/f3baa0a255931dbb16291690699790e3d54f8bde/Sources/SaytileApp/VoicePanel.swift) 7–16、82–114、126–172。
4. [ReferencePanelStyle.swift](https://github.com/haohongfei2001-png/saytile/blob/f3baa0a255931dbb16291690699790e3d54f8bde/Sources/SaytileVoiceUI/ReferencePanelStyle.swift) 30–40。
5. [批准设计约束 AGENTS.md](https://github.com/haohongfei2001-png/saytile/blob/f3baa0a255931dbb16291690699790e3d54f8bde/AGENTS.md) 17–19。
6. [PanelCoexistenceGeometry.swift](https://github.com/haohongfei2001-png/saytile/blob/f3baa0a255931dbb16291690699790e3d54f8bde/Sources/SaytileKit/PanelCoexistenceGeometry.swift)。

### 2.2 Riftlet

- 真正 tray 布局在 `RiftTrayLayout.make`：宽度 **displayFrame.width / 8**（先按 backing scale 对齐到像素）；参考宽 246，最大参考高 212，单行参考高 115。最多四个槽；相机菜单展开时两槽。不是统一固定 246 pt。
- tray 默认垂直位置按整屏中心向下偏移，不是 Saytile 的贴右上；top/bottom/middle 可配置。
- 采用多个原生 panel：托盘材质、截图行、装饰等；各 panel 是 borderless + nonactivatingPanel，通常 floating；全 Spaces、fullScreenAuxiliary、stationary、ignoresCycle。
- canBecomeKey 默认 false，仅特定编辑/菜单场景允许。装饰窗 ignoresMouseEvents=true。
- 捕获期间临时 level=statusBar+1；常态玻璃层比截图层低一级。LyricTile 不应复制捕获专用高层级。
- 当前截图托盘某些状态高度变化，缩略图布局具有产品特定语义。TileKit 应保留核心与 UI，外部只领取「占用区域」，不能重写其截图流。
- 代码明确不将 sharingType=.none 当作已证明的截图排除承诺；LyricTile 同样不要空口宣称截图中隐身。

证据：

1. [RiftTrayLayout.swift](https://github.com/haohongfei2001-png/Riftlet/blob/2b270aec5cf57d2b4165acd52bcc730fa1052a02/Sources/RiftletUI/RiftTrayLayout.swift) 40–91。
2. [RiftPanelController.swift](https://github.com/haohongfei2001-png/Riftlet/blob/2b270aec5cf57d2b4165acd52bcc730fa1052a02/Sources/RiftletUI/RiftPanelController.swift) 62–83、1194–1214。
3. [正式 v1.0.11](https://github.com/haohongfei2001-png/Riftlet/releases/tag/v1.0.11)。

### 2.3 Nearpane

- `EdgePanel` 仍是 AppKit nonactivating NSPanel + 原生 SwiftUI/NSView 内容。floating，canJoinAllSpaces，常态 fullScreenNone；按模式启用 fullScreenAuxiliary。不能以一个固定 collectionBehavior 等同全部全屏语义。
- 默认宽度已**不严格等于八分之一**：
  `min(W×0.25, max(W×0.125, min(360, max(240, W×0.16)))).rounded()`
  例如 1470 pt 屏上默认为 240 pt，而 Saytile/Riftlet 约 184 pt；1920 pt 上是 307 pt。这是真实的跨产品尺寸不一致，需要新统一规范明确迁移，不是本轮假装已经一致。
- PanelGlassMaterial 是 NSVisualEffectView，玻璃 mask 只作用于背景兄弟层，不把交互树整体遮罩；有浅深模式与减少透明度适应。
- 现架构已经把 SaytileKit/SaytileVoiceUI、RiftletCore/RiftletCapture/RiftletAdapters/RiftletUI 按固定域源码引进 Nearpane 的 SwiftPM target。用 domains.lock.json 固定来源；VoiceSurface 与 TrayModule 直接在 Host 内渲染/工作。
- 所以 LyricTile 的未来集成路径已经有明确范式：新增 LyricCore/LyricServices/LyricUI 域 → NearpaneLyrics 桥 → host 内的一块 View；不要把 standalone LyricTile.app 窗口放进 Nearpane 的空洞里。
- Nearpane 的窗口管理引擎、普通窗口安全边界和 StageGroup 资格不应成为独立歌词软件的前置依赖。

证据：

1. [EdgeWindowController.swift](https://github.com/haohongfei2001-png/nearpane/blob/6ac5eb63c97b7597e662770bac485be61f571bb8/Sources/NearpaneUI/EdgeWindowController.swift) 79–96、190–193、303–308。
2. [DisplayPresentation.swift](https://github.com/haohongfei2001-png/nearpane/blob/6ac5eb63c97b7597e662770bac485be61f571bb8/Sources/NearpaneCore/DisplayPresentation.swift) 138–147。
3. [PanelGlassMaterial.swift](https://github.com/haohongfei2001-png/nearpane/blob/6ac5eb63c97b7597e662770bac485be61f571bb8/Sources/NearpaneUI/PanelGlassMaterial.swift)。
4. [Package.swift](https://github.com/haohongfei2001-png/nearpane/blob/6ac5eb63c97b7597e662770bac485be61f571bb8/Package.swift) 68–100。
5. [VoiceSurface.swift](https://github.com/haohongfei2001-png/nearpane/blob/6ac5eb63c97b7597e662770bac485be61f571bb8/Sources/NearpaneVoice/VoiceSurface.swift)、[TrayModule.swift](https://github.com/haohongfei2001-png/nearpane/blob/6ac5eb63c97b7597e662770bac485be61f571bb8/Sources/NearpaneTray/TrayModule.swift)。

## 三、Lyrimuse 深审裁决

### 实际组成与成熟经验

这是 Swift 原生 UI + LyrimuseCore + Go 歌词引擎 + media-control 的复合产品，不是一个拿来即用的 Swift 歌词组件。LyrimuseCore 含播放源、歌词时序/解析/本地缓存；主 App 有桌面、灵动岛、菜单栏、完整歌词窗口等多种呈现；Go 引擎处理歌词检索、平台匹配、翻译等。

`shared/players.json` 是播放器注册唯一源，生成两端元数据。当前列出 22 个内置播放器。它给 QQ/网易配置 noisyFloored 进度等级；QQ/网易的非当前系统会话 transport 使用 AX 菜单，网易失焦 seek 不支持；这些是上游源码/注释陈述，需要自己的 macOS27验收复核。不把上游全盘权限需求照搬：完全磁盘访问主要由读各家本地缓存/歌词等能力引入，不是基础 Now Playing 必然要求。

`LocalPlaybackSource` 真实区分「还未得到歌词」「搜索完未找到」「已知纯音乐」；这一点应进入 LyricTile 核心状态模型。它有 track/play sequence、anchor sequence、source-specific lyric version 与正文指纹，避免同歌不同母带强行共享偏移。

`LyricsMiniPanel` 使用 nonactivatingPanel；最小内容宽 300 pt，整体是可缩放的小播放器窗，不能直接收窄到 184–224pt 还保持其三颗胶囊工具条。mini 关闭时释放 SwiftUI 树，停止播放订阅/逐帧时钟。hover 用 NSTrackingArea.activeAlways，并重同步指针，以免 App 失焦后 hover 失效；这比只依赖某个 SwiftUI onHover 成功的 demo 更可靠。

`LyricsOverlayView` 已对按帧文字填充进行粒度隔离，注释记录整体 SwiftUI WrapLayout 每帧重建的成本；可借鉴工程策略，但上游注释中的 CPU 数字不是 LyricTile 的资源预算证据。

### 可以怎样复用

- **选闭源或未来希望 Nearpane 不被 GPL 约束：不复制/翻译 Lyrimuse 源码，不链接 LyrimuseCore。** 阅读它的实际接口现象、形成独立需求与测试案例；真正可复用的 BSD media-control 应回到其原仓库取代码。不能把 GPL Swift 改写成 Swift 或 Rust 就说免责。
- **若有意将 LyricTile 整体 GPL3 发行：** 可 fork/裁剪并履行对应源码、修改说明、许可证等义务；但不是无成本近路，Go 引擎、庞大设置与多层 UI 会抬高精简难度，且后续与 Nearpane 链接的许可证边界也需一起决定。
- 首版建议：独立原生小产品，借鉴其错误分类与非激活窗行为，取 upstream media-control 为组件；不采用其完整应用框架、用户数据、歌词库、品牌图/字体/专辑图等素材。

### 维护/风险判断

Lyrimuse 当前活跃，有 macOS27 的上游使用记录与构建适配，但没有因此证明我们的版本/签名/播放器版本兼容。未解决 issue #102 指向锁定桌面歌词重启后位置上移：这恰好说明恢复布局仍需本机测试，不宜把「成熟」解释成免验证。

证据：

- [LICENSE](https://github.com/Yudaotor/lyrimuse/blob/9d74d785be00faca056bc9b5b1575abe7b7820ea/LICENSE)、[THIRD_PARTY_LICENSES](https://github.com/Yudaotor/lyrimuse/blob/9d74d785be00faca056bc9b5b1575abe7b7820ea/THIRD_PARTY_LICENSES)。
- [Package.swift](https://github.com/Yudaotor/lyrimuse/blob/9d74d785be00faca056bc9b5b1575abe7b7820ea/lyrimuse/Package.swift)。
- [players.json](https://github.com/Yudaotor/lyrimuse/blob/9d74d785be00faca056bc9b5b1575abe7b7820ea/shared/players.json)。
- [LocalPlaybackSource.swift](https://github.com/Yudaotor/lyrimuse/blob/9d74d785be00faca056bc9b5b1575abe7b7820ea/lyrimuse/Sources/LyrimuseCore/Local/LocalPlaybackSource.swift)。
- [PlaybackStateFile.swift](https://github.com/Yudaotor/lyrimuse/blob/9d74d785be00faca056bc9b5b1575abe7b7820ea/lyrimuse/Sources/LyrimuseCore/Local/PlaybackStateFile.swift)。
- [PlayerLyricsVersion.swift](https://github.com/Yudaotor/lyrimuse/blob/9d74d785be00faca056bc9b5b1575abe7b7820ea/lyrimuse/Sources/LyrimuseCore/Lyrics/PlayerLyricsVersion.swift)。
- [LyricsMiniPanel.swift](https://github.com/Yudaotor/lyrimuse/blob/9d74d785be00faca056bc9b5b1575abe7b7820ea/lyrimuse/Sources/lyrimuse/UI/LyricsMiniPanel.swift)。
- [LyricsWindowHoverFade.swift](https://github.com/Yudaotor/lyrimuse/blob/9d74d785be00faca056bc9b5b1575abe7b7820ea/lyrimuse/Sources/lyrimuse/UI/LyricsWindowHoverFade.swift)。
- [v1.14.0](https://github.com/Yudaotor/lyrimuse/releases/tag/v1.14.0)、[位置 issue #102](https://github.com/Yudaotor/lyrimuse/issues/102)。

## 四、Lyrics-Plus 深审裁决

### 实际技术

React/TypeScript 前端 + Tauri 2.11.5 Rust 后端。Cargo 启用 macos-private-api，media-remote 精确锁 0.3.8；自带 mediaremote-adapter 0.3.8 tar.gz，不能当成已升级至最新适配器。它是 MIT，且依赖 lyrics-crypto 来自 Lyrics-Helper（当前 lock e5721f5635f04727443d54bb19b22c159d3bf89e；依赖仓库根为 Apache-2.0，集成时仍逐组件带 NOTICE/许可证）。

播放器层 `player/automation/apple_music.rs` / spotify.rs 使用 objc2 Scripting Bridge/AppleEvents，Apple Music duration scaling=1000，Spotify scaling=1；可借鉴并抽测真实单位，不让两家 milliseconds/seconds 混用。通用系统媒体另有 stream+refresh+artwork+presentation 四线程，refresh 默认 750ms，接收线程不做图片解码。指定播放器 JXA 有 3s 子进程超时、256KiB元数据/8MiB封面界限，并发读 stdout 避免管道阻塞。

歌词层已有 provider_registry 健康/缓存/查找，runtime/ranking 区分 identity conflict、可自动采用、时序质量、分数与稳定顺序；这些 MIT 逻辑可选择性移植。不要把分数当真实匹配概率。版本字段应先否决冲突，功能丰富度只能在相近置信范围内打破平局。

### 一个不可直接继承的缺陷

`lyrics/parser/ttml.rs` 实际通过 `find("<p")`、`find("</p>")`、`find("<span")`手拆字符串，不是完整 XML 解析。嵌套 span、namespace prefix、相对 timing、不同 timebase、多声部等容易丢语义。**不得原样移植成为 LyricTile 标准 TTML 解析器**。应使用 XML parser、关闭外部实体、明确支持 subset 并保留未支持警告；格式转换不能凭空补齐逐字时间。

前端位置 hook 使用 Date.now 100ms timer 外推。我们应改 monotonic clock、明确 sleep/wake 重新锚定，并将渲染时钟与系统轮询分离。Tauri 页面/动态岛/复杂资料库不是本项目需要，整个搬迁会扩大包体和维护面，且破坏 Nearpane 内直接嵌入 Swift View 的路线。

### 推荐复用清单

| 模块 | 裁决 |
|---|---|
| Rust 纯数据类型、provider结果与quality判定 | 可有选择地移植/重用，保留 MIT 版权与改动记录 |
| provider_registry 健康、负缓存、稳定排序结构 | 借用设计/移植合适小块；删掉面向大资料库的过度配置 |
| AppleMusic/Spotify AppleEvent 单位与属性映射 | 可作为一手实现证据，最终以本机 sdef 和实际回读验收 |
| targeted JXA / 0.3.8 adapter 封装 | 不直接冻结为长期主线；与 ungive 最新版本合并评估 |
| TTML 字符串 parser | 不采用 |
| React/Tauri 全套 UI | 不采用 |
| 歌词、封面与缓存样本 | 许可证与代码分离，不因 MIT 自动获得商业内容授权 |

证据：

- [LICENSE](https://github.com/afeibukaixin/Lyrics-Plus/blob/a6f5a32814fee2f3914414fd7fdfe0aeea4d2917/LICENSE)、[Cargo.toml](https://github.com/afeibukaixin/Lyrics-Plus/blob/a6f5a32814fee2f3914414fd7fdfe0aeea4d2917/src-tauri/Cargo.toml)、[Cargo.lock](https://github.com/afeibukaixin/Lyrics-Plus/blob/a6f5a32814fee2f3914414fd7fdfe0aeea4d2917/src-tauri/Cargo.lock)。
- [automation/apple_music.rs](https://github.com/afeibukaixin/Lyrics-Plus/blob/a6f5a32814fee2f3914414fd7fdfe0aeea4d2917/src-tauri/src/player/automation/apple_music.rs)、[automation/spotify.rs](https://github.com/afeibukaixin/Lyrics-Plus/blob/a6f5a32814fee2f3914414fd7fdfe0aeea4d2917/src-tauri/src/player/automation/spotify.rs)。
- [system/runtime.rs](https://github.com/afeibukaixin/Lyrics-Plus/blob/a6f5a32814fee2f3914414fd7fdfe0aeea4d2917/src-tauri/src/player/system/runtime.rs)、[system/targeted.rs](https://github.com/afeibukaixin/Lyrics-Plus/blob/a6f5a32814fee2f3914414fd7fdfe0aeea4d2917/src-tauri/src/player/system/targeted.rs)。
- [runtime/ranking.rs](https://github.com/afeibukaixin/Lyrics-Plus/blob/a6f5a32814fee2f3914414fd7fdfe0aeea4d2917/src-tauri/src/lyrics/runtime/ranking.rs)。
- [parser/ttml.rs](https://github.com/afeibukaixin/Lyrics-Plus/blob/a6f5a32814fee2f3914414fd7fdfe0aeea4d2917/src-tauri/src/lyrics/parser/ttml.rs)。
- [position.ts](https://github.com/afeibukaixin/Lyrics-Plus/blob/a6f5a32814fee2f3914414fd7fdfe0aeea4d2917/src/features/player/playback/position.ts)。
- [overlay geometry](https://github.com/afeibukaixin/Lyrics-Plus/blob/a6f5a32814fee2f3914414fd7fdfe0aeea4d2917/src-tauri/src/overlay_placement/geometry.rs)、[v2.2.20](https://github.com/afeibukaixin/Lyrics-Plus/releases/tag/v2.2.20)。

## 五、轻量 TileKit 的落地方案（设计裁决，未实现）

### 范围

一个很小的 Swift package，三个层次：

1. **TileGeometry**：Foundation/CoreGraphics 纯几何；DisplayID、TileID、槽位、尺寸、padding、spacing、排序、约束、布局计划；无业务服务。
2. **TileWindow**：AppKit NSPanel shell、hover跟踪、拖动/屏幕恢复、统一材质tokens；业务 View 作为注入内容。
3. **TileCoordination**：仅 standalone 时的本机同用户 slot注册/租约/计划分发；Nearpane host 模式直接使用 TileGeometry，不启动 IPC，也不创建独立panel。

不放音乐适配、歌词网络、ASR、截图、数据库、账户、扩展市场、远程插件动态加载、自动更新进 TileKit。

### 可靠而不庞大的协作

直接分发非沙盒版本可使用固定的用户目录 `Application Support/HOLDSNOW/TileCoordination/v1`：

- 单个 advisory lock（flock）串行修改 registry + plan；每次写临时文件再原子替换，计划单调 generation。不要以 DistributedNotificationCenter 广播本身作为真相。
- 每个运行实例注册 bundleID、instanceUUID、PID与进程起始身份、显示器UUID、min/ideal/max footprint、位置模式、稳定orderKey、租约截止。没有歌词/转写/截图内容。
- 进程内 actor 串行协调；文件锁只覆盖短的读取/计算/落盘，持锁时不等异步回调、UI、网络。所有参与进程都可以在锁下更新计划，因此没有必须常驻的单独 daemon，也没有两台 leader 同时抢位置的窗口。
- DistributedNotificationCenter 只是「generation可能变了」的提示；收件方读取并核对 plan。启动、唤醒、显示器变更主动对账；活动App可低频5s续租、15s租约，进程退出通知可提早回收。这是初始参数，不是性能实测结论。
- PID复用要校验启动身份；磁盘损坏时保留本App最后有效位置并重新登记，不去移动其他普通应用窗口。
- 这些消息不能执行任意命令/路径/AX操作。协议不涉及私密内容；不要为了几何协调先做一套账户鉴权系统。
- 用户正式签名团队若已可配 App Group，未来可将容器转至同团队AppGroup；当前无需把共享容器签发作为独立版发布阻断。

### 空间不跳动的真正条件

- **hover绝不改变外部占位高度**：控制层在同一footprint内显隐；不能边出现控制键边将下方Riftlet推来推去。
- 歌曲长短不改变窗口外框；当前行必要换行、内部行区更新，长句模式另有确定性排版。
- 新App初次加入放到最近可用槽/已保存槽；不要每秒按活跃度重排；用户手动拖动才改变顺序。
- 原则优先级：用户固定位置 > 已在交互的tile > 已可见稳定槽 > 新加入tile。空间不足按既定compact footprint降级/提供展开，不把某组件移出屏幕。
- 对确定要reflow的多窗口，在同一generation共同应用最终非重叠位置；默认不对跨越别人槽位的移动做穿越动画。不要声称任意两个合法端点之间的插值都不相撞。
- 不能强行控制未升级的旧Saytile/Riftlet。旧版不登记时，LyricTile只对自身定位，提供手动位置；正式宣称「多产品自动排列」前，应完成三产品最小接入更新和组合验收。
- 共同宽度由产品规范统一；不要同时使用Saytile旧12.5%、Riftlet整屏12.5%、Nearpane当前16%/240-360pt三种公式。我的建议是统一逻辑点基准并有窄屏夹紧，具体数值由本轮最终高保真稿冻结。
- 多屏按稳定displayUUID保存位置，计算均用AppKit logical points；backing scale只用于像素对齐。断屏迁到最近可用屏，连接恢复时不自动把正在操作的tile拖走。全屏默认跟当前任务政策，要实测不同Spaces设置。

### Nearpane 承载与独立版互斥

独立版应有 `LyricSession`（媒体/歌词/时钟 actor）和 `LyricTileView`（纯呈现）。`LyricTileApp` 只是它们的生命周期 + standalone面板壳。Nearpane引入同一版本的核心与View，建 `NearpaneLyricsModule`，由host管理显示器、布局、暂停、设置入口。

同一用户仅一个该模块的活跃呈现owner；Nearpane已启用歌词模块时，独立版收到明确host注册后收起自身panel，服务所有权通过版本化handoff移交或host直接重建，不能两个歌词板叠加。模块退出/host崩溃后独立版恢复须经有效租约失效并回读状态。不要把「给独立App发隐藏指令」当作 Nearpane 已完成内嵌。

## 六、必须做的目标实机核验

以下没有被本轮Linux阅读验证：

1. 每种播放器受支持版本、原生/商店来源、前后台切换时的metadata/playing/rate/duration/elapsed回读。
2. 浏览器视频占据系统Now Playing时，QQ/网易仍显示锁定源且控制不误发；seek能力不明确时不显示可拖进度。
3. fresh install中非激活panel第一次hover/第一次点击不抢原应用焦点；编辑设置/歌词搜索时才key；面板关闭后焦点可恢复。
4. macOS27两个显示器、不同缩放、负坐标、断开重连、合盖外接；「显示器具有单独的空间」开/关、全屏/退出全屏。
5. TileKit参与的三App所有启动顺序、退出/崩溃、同时hover/展开/拖动、睡眠唤醒、协议版本不一致、旧版App共存。
6. 真正目标桌面的玻璃效果、Reduce Transparency/Contrast/Motion，桌面强纹理、纯白/纯黑背景；不能以CSS预览代替原生材质验证。
7. 活跃词60fps局部绘制、行级歌词只按换行更新，隐藏/暂停状态动画停止；Instruments量测CPU/内存/energy，不能复述上游注释的CPU为本产品结果。
8. Developer ID nested code签名、公证、下载隔离属性下安装/更新，以及helper目录相对路径完整性。

## 七、差异化建议

「支持四家播放器 + 悬浮歌词」已经存在，不能宣称品类首创。Lyrimuse和Lyrics-Plus还覆盖逐字、多源、灵动岛、桌面、菜单栏等广泛功能。LyricTile胜负点是 **读歌词的安静小面板、hover才出现播控、严谨匹配与时间、同一HOLDSNOW列的空间稳定、未来原生嵌入Nearpane**。保持这条承诺，比追上上游22播放器/16歌词源/大资料库更可能形成清晰可发布的产品。

