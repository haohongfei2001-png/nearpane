# LyricTile 媒体适配源码审计与技术裁决

核查日：2026-11-26（Asia/Shanghai）。本报告来自 GitHub API 当前元数据、固定提交实际源码、Apple/Spotify 一手文档；**没有在用户 macOS 27 本机运行，所有兼容性结果均不得标为本轮实测通过**。

## 1. 决策摘要

1. 原生 macOS 主实现使用 Swift + AppKit/SwiftUI；Apple Music、Spotify 使用定向 Apple Events/ScriptingBridge 读取与控制。两者拥有公开给自动化使用的脚本接口，现有独立源码已有可核对实现。不要把 MusicKit `SystemMusicPlayer` 当成原生 macOS 接口——Apple 当前文档 availability 无 macOS，仅有 Mac Catalyst 等平台。
2. QQ 音乐、网易云音乐使用独立进程的 MediaRemote 兼容适配器读取系统媒体。优先固定 `ungive/mediaremote-adapter` v0.9.0 的 BSD-3-Clause 源码，不需要完整套用 `media-control` CLI。需要本机核对应用版本、媒体会话和控制行为。
3. 首版四播放器均应实现适配与验证；Apple Music/Spotify 完整控制作为硬目标。QQ/网易的同步等级、是否可以拖进度、失去系统媒体焦点后的控制，按实机结果发布能力矩阵，不能整体宣传等价的精准逐字体验。
4. **定向读取不是定向控制。** adapter v0.9.0 的 `get --bundle-id` 可读后台客户端，但 `send`/`seek` 仍发给系统当前媒体。禁止用临时更改全局 Now Playing override 的方式伪装定向控制。
5. `send` 返回成功、helper exit 0、私有 API 返回 true 都不是播放器执行完成的证据。必须读回歌曲身份/播放态/进度确认。QQ/网易失焦后不支持的动作隐藏或禁用，并可返回原播放器；不能悄悄控制另一个 app。
6. 正式分发选择 Developer ID + Hardened Runtime + Apple 公证的官网安装包。包含 MediaRemote 私有框架路线的版本不按 Mac App Store 方案设计；公证和 App Review 是不同机制，不能据私有 API 就断言不能公证，也不能保证一定通过。
7. 默认不需要录屏、麦克风或完全磁盘访问权限。Apple Music/Spotify 自动化按实际选用的播放器分别申请。QQ/网易可选的 AX 菜单控制需要辅助功能，若首版不做失焦菜单控制，则不申请。Lyrimuse 的完全磁盘访问需求与其读播放器缓存的更多能力有关，不能照搬到 LyricTile。

## 2. 固定审计基线与维护状态

| 项目 | 默认分支 HEAD | 最近提交 / 最新 release（UTC） | 许可证与实际裁决 |
|---|---|---|---|
| ungive/mediaremote-adapter | `2ef957c736256cee7905c9f3f1c7e279087bf195` | 2026-11-23 18:30:43；v0.9.0，2026-11-23 18:39:01 | 完整 BSD-3-Clause LICENSE，保留版权/条款/免责声明；适合直接作为第三方组件固定版本复用 |
| ungive/media-control | `507575ce288a9238372b7f39fde44988612700d4` | 2026-11-24 11:19:41；v0.9.0，2026-11-24 11:21:35 | `bin/media-control` 文件头和 README 明确 BSD-3-Clause，但仓库顶层缺少所链接 LICENSE，API `license=null`；这是许可材料缺项，不是“完全未声明许可”。用作开发诊断工具；产品直接复用 adapter 更简单 |
| ddddxxx/MusicPlayer（补充审计） | `f2090c48cecf12b86ddb3fc98f2fe90ed4dbb82f` | 2024-10-08 最近默认分支提交 | MPL-2.0，含 Apple Music/Spotify ScriptingBridge 适配。作为接口证据与可选独立组件；若复制/修改其受许可文件，分发时提供对应源文件与修改并保留许可证，不应直接当 MIT 文件混入 |
| Yudaotor/lyrimuse（交叉核对） | `9d74d785be00faca056bc9b5b1575abe7b7820ea` | 由生态审计提供固定克隆 | GPL-3.0，研究其真实播放器行为与已踩坑；不复制 GPL 实现进拟闭源集成产品 |
| afeibukaixin/Lyrics-Plus（交叉核对） | `a6f5a32814fee2f3914414fd7fdfe0aeea4d2917` | 由生态审计提供固定克隆 | MIT；可参考/移植 Apple Events 适配、身份校验、读回控制、超时与资源限制机制。它内嵌 adapter 0.3.8，不能把旧依赖版本作为本轮新基线 |

两份 ungive release 当前均无预构建 GitHub assets；发布工程必须自行固定源码编译并签名，不应要求消费者自行装 Homebrew。repo 仍开放维护。mediaremote-adapter 当前开放议题包括：#48 定向控制、#50 控制成功/失败反馈、#24 字段不一致修正。最新 v0.9.0 新增 supportedCommands 及 send 的发送前能力校验，但这些未填平定向控制与执行确认缺口。

## 3. 已读源码与关键发现

### 3.1 MediaRemote Adapter

固定提交永久链接前缀：
`https://github.com/ungive/mediaremote-adapter/blob/2ef957c736256cee7905c9f3f1c7e279087bf195/`

| 文件 / 符号 | 实际实现与用途 | LyricTile 决策 |
|---|---|---|
| `bin/mediaremote-adapter.pl` 123、299–301；`src/private/MediaRemote.m` 92、119–152 | `/usr/bin/perl` 中 DynaLoader 动态载入自带 framework，再从系统 PrivateFrameworks/MediaRemote.framework 取函数指针；不是常规 app 直接 link 私有库 | 独立兼容进程，绝不把它称为 Apple 公共/稳定 API；runtime availability 与升级后退路必须存在 |
| `CMakeLists.txt` 38、72–77 | 构建 x86_64+arm64 framework；上游仅做 ad-hoc signing | 自己用发行证书签嵌套代码，核对最低系统版本、lipo 后再签、签名与公证后再做最终包的运行验证 |
| `src/adapter/get.m` `internal_get_for_bundle` / `adapter_get` | 查询本地 origin 的所有 clients，以自身或 parent bundleID 匹配；返回数组，可有多个结果；2s 超时 | 不把单个 bundleID 等于单个会话；native 四播放器只接受注册 bundle，出现歧义不任取第一个 |
| `src/adapter/stream.m` `createDiff`、`printData` | NDJSON 包含 type/diff/payload；diff 中 null 表示字段删除，非 diff 表示完整替换；切歌/换进程输出完整快照 | 使用明确 reducer，不能把每行都当完整状态，也不能只合并不删除；重启第一条非 diff 前不使用旧状态 |
| `src/adapter/keys.m` 65–95 | 真实必要字段为 processIdentifier、playing、可选要求的 title；README 的 mandatory keys 描述与当前实现不完全同步；identity 只比较 PID/bundle/parent/title/artist/album | 所有非必要字段 optional；LyricTile 自己强化 track generation、provider ID、duration/version，不能仅用 helper diff 标志认切歌 |
| `src/adapter/stream.m` 348–387 | 同身份时封面短暂消失会保留旧图 | 可利用，但自己的封面异步结果仍须按 track generation 校验，防同名不同版与迟到结果污染 |
| `src/adapter/now_playing.m` `getElapsedTimeNow` | 基于 elapsed、timestamp、playbackRate 外推；源码自己称便利估算 | 应读取原始时间锚点，自建单调时钟；`--now` 不是高精度承诺 |
| `src/utility/helpers.m` 118–128 | 默认 NSDate 序列化成秒级 `yyyy-MM-dd'T'HH:mm:ss'Z'`，丢失小数秒 | **强制 `--micros`**，保留 `timestampEpochMicros`、`elapsedTimeMicros`、`durationMicros`；微秒单位不代表上游精度 |
| `src/adapter/send.m` 18–102 | 查询 supportedCommands；若接口缺失/超时只告警并继续；未支持/disabled 则失败；调用全局 sendCommand；TODO 明确缺定向与成功结果 | 产品自己采用 capability + source identity 双校验；不使用 `--force`；不得把 validation fallback 当作已证实支持 |
| `src/adapter/seek.m` 15–23 | 仅拒负数，调用全局 setElapsedTime(position/1_000_000)，没有 seek 能力验证与明确执行回执 | adapter seek 入参是**微秒**；传前 clamp 到已知时长且 finite；seek 需独立验证，不能因 send 支持就亮出 slider |
| `src/adapter/now_playing.m` 13–23 | waitForCommandCompletion 实际等待另一个 GetNowPlayingApplicationPID callback，最长2s | 不是状态执行成功验证；必须查询播放器实际结果 |
| `src/adapter/test.m` 87 起；`src/test/NowPlayingTest.m` | 无真实媒体时 test helper 用 MPNowPlayingInfoCenter 发布测试媒体 | 仅隔离诊断使用；不在正常开机/idle 高频运行，更不能把测试曲目算正式功能或媒体证据 |

### 3.2 media-control

`bin/media-control` 是 Perl CLI，解析友好命令、秒数，再转调同目录树的 adapter；`CMakeLists.txt` 将 bin、lib/media-control、Frameworks 一起安装。它本身不是比 adapter 更强的播放器引擎。

`media-control seek 22.4` 使用秒，而 adapter `seek 22400000` 使用微秒。这是可造成灾难性跳转的接口差异，Swift wrapper 必须使用 typed Duration，禁止散落数值倍率。

其 README 演示含与本产品无关的广告跳过脚本，LyricTile 不复用；本产品遇广告/播客应展示诚实非歌词状态并遵循播放器的禁跳标志。

### 3.3 Apple Music / Spotify 原生自动化

`ddddxxx/MusicPlayer/Sources/LXMusicPlayer/Players/LXPlayerAppleMusic.m` 通过 `MusicApplication.currentTrack/playerState/playerPosition` 读取，调用 resume/pause/playpause/nextTrack/previousTrack，并可写 `playerPosition`；使用 `com.apple.iTunes.playerInfo` 通知触发刷新。

`.../LXPlayerSpotify.m` 相同方式读取 Spotify，使用 `com.spotify.client.PlaybackStateChanged`；控制发到已选 app。`.../LXScriptingMusicPlayer.m` 监听 NSWorkspace 启停且避免对未运行 app 读取。应保留这个模式，重建更小的 Swift/ObjC 适配而不引入它的旧 CombineX/SystemMedia 依赖。

特别注意：旧 Spotify bridging header 的 duration 注释写 seconds，但现代 Lyrics-Plus/lyrimuse 实现按毫秒处理 Spotify duration，Music duration 按秒。**用户本机 .sdef+实际值必须核对；API 注释不能代替单位实测。** Apple Music 的 `lyrics` 字符串属性仅证明可读歌曲文本属性，不证明可取订阅曲库的 Apple 逐字同步歌词，更不能承诺取得 TTML。

Lyrics-Plus 的 `src-tauri/src/player/automation/mod.rs` 是更现代的 MIT 参考：按运行 PID 建立 ScriptingBridge，设置 3s AppleEvent timeout，映射 -1743 授权拒绝 / -1712 超时，duration 单位明确，控制和 seek 路由独立。不必把整个 Rust/Tauri 运行时引入 Swift 产品。

### 3.4 QQ / 网易云的证据边界

Lyrimuse `shared/players.json` 明确注册 `com.tencent.QQMusicMac` 和 `com.netease.163music`。其作者报告两者没有 sdef/NSAppleScriptEnabled，读数存在整秒量化；QQ 还报告 ±1~1.5s 抖动，网易可能冷启动时撤回仍在发声的媒体会话。以上属于**上游实测报告 + 对应防御代码存在**，不是我们在目标 macOS27 的测量。

`MusicPlaybackController.controlRoute` 1336–1365 确实对失焦 QQ/网易采用定向 AX 菜单的三项动作，并对不具备通路的动作返回 withheld；`seek` 1244–1285 还处理 QQ 暂停 seek 导致自动播放的问题。产品不能把这些现象写成 macOS27 每个版本必然发生，但必须列入验收。

Lyrimuse 的 `ProgressClock.extrapolatedPositionMs` 可不限龄外推；本产品不要原样照搬。是否仍有效必须由新的播放器状态、helper 健康状态与读数误差界决定。若上游只给粗时间，动画可以平滑，**精度不能由平滑产生**。

### 3.5 Lyric Fever 交叉核对

额外精读本地固定提交 `20a44f0fc18a39f28824bf288dc8f368b17b9a99` 的 `LyricFever/Players/AppleMusic/AppleMusicPlayer.swift` 和 `LyricFever/Players/Spotify/SpotifyPlayer.swift`：二者均是定向 ScriptingBridge，而非 MusicKit 接管原播放器。MIT 许可允许保留声明后复用适当接口代码，但**不整包照搬**。

不复用的具体实现：Apple Music `currentTime` 无条件加400ms，动画再加400ms，AirPlay直接减2000ms；Spotify把界面动画补偿也混进媒体时间；`fixSpotifyLyricDrift()` 延时2秒后主动调用 `play()`。这些修补会把展示动画、声音设备延迟与播放器真实位置混在一起，也会让纯歌词观察者主动影响播放。LyricTile 的渲染提前量若需要，应独立且经测量，时钟模型保存原始真实时间；不得为修歌词漂移偷偷调用播放命令。

## 4. 定向媒体控制最终裁决

主证据：

- https://github.com/ungive/mediaremote-adapter/issues/41 及其 2026-09-30 作者更正；
- https://github.com/ungive/mediaremote-adapter/issues/48（当前开放）；
- https://github.com/ungive/mediaremote-adapter/issues/50（当前开放）。

早期 #41 报告在 macOS 27.0 `(26A5425a)` 用 Perl helper 可定向读取。后来作者尝试设置 Now Playing application override 后发全局命令，又明确撤回：它改变系统全局状态、可误导其他进程控制，进程被杀可能留下 override。**这是他人特定 build 的证据，不等于用户 macOS27/build 的通过。**

v0.9.0 现有源码与开放议题不能支持“可靠通用定向控制已经完成”的结论。Lyrics-Plus 的 `system-media-targeted.js` 也只实现 query/artwork，不含播放控制；`system/service.rs` 在全局控制前读取实际当前媒体，比较身份，发送后读回，设计方向可复用，但读与发之间仍非原子操作，不能宣称数学上彻底消除系统焦点变化的竞态。

LyricTile 具体行为：

| 情况 | 读数 | 控制 |
|---|---|---|
| Apple Music / Spotify，面板跟随此播放器 | 定向 Apple Events | 始终定向该 PID/bundle 的 Apple Events；异步反馈 |
| QQ / 网易是系统当前媒体 | MediaRemote stream + 必要刷新 | capability 判断 + 发前核对 + 明确 play/pause + 发后读回；seek 单独能力开关 |
| QQ / 网易仍播放但系统媒体已被别的 app 占用 | `get --bundle-id` 可行则保留歌词 | 可选已验证 AX 菜单通路；无通路的动作 unavailable；不得发给当前系统媒体 |
| 用户固定播放器 A，而 B 播放 | 保持 A；显式显示 A 状态 | 只能定向 A 的通路；绝不转发给 B |
| 未知 app/网页视频/语音消息成为系统媒体 | 不自动替换成歌词对象 | 维持已选音乐来源或清晰 idle；不按任何系统媒体都当歌曲 |

初版无需做完整的所有播放器同时 streaming；当前 adapter 也没有已完成的 `stream --all-apps`。在已安装四 app 的进程集合上做有界轮询并结合事件足够。

## 5. 原生架构建议与接口边界

### PlayerSession

`PlayerIdentity(bundleID, pid, processLaunchIdentity, adapterKind)`、`TrackIdentity(providerID?, contentItemID?, title, artists, album, duration, editionHints)`、`generation`、`PlaybackState`、`PlaybackCapabilities`、`PositionSample` 分开建模。不要把歌名作为缓存主键，不能让旧 lyric/artwork 请求的迟到结果改写新 generation。

### PositionSample 与可信外推

至少保留：`samplePosition: Duration?`、`sampleWallTimestamp?`、`receivedMonotonic`、`playbackRate?`、`isPlaying`、`sourceResolution`、`uncertainty`、`sequence/generation`。外推以经过验证的真锚点为起点，用本机 monotonic elapsed；墙钟仅用于接入一次上游 epoch timestamp。系统时间改变、唤醒、切歌、seek、source 切换均重锚。

正常播放在两个真实观察之间按播放速率外推，是媒体时钟插值，不是假进度。没有 position 的歌曲不可造零点开始走；暂停即冻结；失去可信状态不能无限播放动画。事件流一段时间没变化也不等于故障，歌曲稳定时本来可能不发事件，因此使用低频 health snapshot 和 helper 退出事件判断健康，而不是“5秒无事件必然断开”。

建议 initial tuning（待实测优化）：Apple Events 播放中 1Hz，通知到来立即刷新；暂停 0.2Hz 并保留事件；MediaRemote 常驻 stream，3–5s health get 不带封面；仅目标不在全局媒体时做定向读取。UI 的 30/60Hz 只用于可见逐字渲染，不驱动播放器 IPC 或网络请求。

对于粗时间源，先去掉已知量化偏差，再评估 residual；严禁直接硬编码“QQ永远提前1秒”此类未经目标版本验证的修补。逐字高亮需要**歌词有真实逐字时间 + 位置源达到对应精度**两条件。否则降为逐行，文字样式仍可同样精美。

### CommandReceipt

状态 `pending → confirmed | rejected | unavailable | timedOut`。命令串行但观测不堵 UI。传入 expected player/session/generation；结果读回只接受一致身份。快速 play/pause 以明确目标状态合并，避免两次 toggle 相互抵消。seek 拖动时可显示明确的预览 thumb，松开后不伪报成功，收到新位置再确认；超时回到真实位置并给轻量提示。

### ArtworkService

优先播放器自己提供的封面；Apple Music artwork data、Spotify artworkURL、MediaRemote artworkData。下载/解码离主线程，按固定图片最大字节与像素上限处理，只按曲目变更或封面变更请求；不要每帧重复 base64 解码。持久 key 包含 provider ID 或完整版本身份；封面迟到必须检查 generation。缺图用中性色材质，不能以任意相似专辑替代。

### Helper supervisor

主 app Process 封装独立 stdin/stdout/stderr，固定 bundle 内绝对路径，NDJSON 上限、缓冲拆包和超时明确。故障退回 AppleScript 或显式 unavailable；确定不兼容不重启风暴；短暂崩溃只做有界重启和 backoff。应用退出必须结束自己的子进程。无需系统常驻 daemon 或 root 权限。

## 6. 权限、签名与分发

| 项目 | 要求 |
|---|---|
| Apple Music / Spotify | `NSAppleEventsUsageDescription`；Hardened Runtime 的 Apple Events entitlement；用户针对对应播放器批准自动化。按需解释，不一次弹四份 |
| QQ / 网易普通系统读取 | 不需要“读取其他 app 所有文件”；本路线不读取其沙盒数据库，不申请 Full Disk Access |
| 可选后台菜单控制 | 仅在实际启用此功能时请求辅助功能；无 AX 时保留读数/系统当前媒体可控能力，不把权限缺失伪装为播放器不存在 |
| 主 App/内部 framework | Developer ID 签嵌套代码；上游 ad-hoc 签名不能作为正式发行签名 |
| macOS 公证 | Apple 明确这是恶意内容/签名自动检查，不是 App Review；成功票据与最终安装包运行都要验证 |
| Mac App Store | Review 2.5.1 要求 public API；当前兼容 helper 私有 API 路线不适合作为 MAS 版本。若未来要上架，需另裁公共接口子集 |
| Entitlements | 不添加 Apple-private entitlement、不修改系统 binary、不要求关 SIP、不靠关闭系统安全机制建立产品能力 |

正式包装前必须实测“下载后带 quarantine 的新安装副本”，不能只运行开发目录的未隔离 app。helper 在 App Translocation/包含空格路径、签名后的 bundle 中都应可定位。不需要把每个安全技术细节暴露在消费级 UI。

## 7. 首版媒体支持与验收建议

产品计划层：四个播放器都包含。营销层：写实际通过的能力，不写“全平台完美兼容”。主线先保证 Apple Music + Spotify；QQ/网易保留质量达标后晋级的同步/控制能力，不能因为尚未实测就删掉研究范围，也不能依据源码就宣称四个全通过。

本轮证据级别：

- **已核查事实**：HEAD/release/LICENSE；源代码存在上述接口/分支；Apple 官方平台 availability/权限/分发规则。
- **源码与外部报告支持**：Apple Music/Spotify 自动化、MediaRemote 系统/定向读取、QQ/网易行为和时间质量风险。
- **必须本机验证**：macOS27 用户 build、播放器版本、SIP开启环境、四平台真实曲目全流程、签名公证之后的 helper 可用性、性能与长时间稳定性。

推荐本机验收集合：

1. 记录 macOS 产品版本/build、SIP、硬件、四播放器 version/build、实际 .sdef/脚本支持、应用签名；不修改播放器 app。
2. 每播放器真实播放至少10首（中文/英文/多艺人/同名不同版/本地文件或无元数据各覆盖），记录字段与单位、provider ID、封面、时长、状态。
3. 每播放器暂停/恢复20次；前后跳转20次；拖动中切歌；暂停后 seek；前后切歌20次；App退出/重开；睡眠/唤醒。保存原始轨迹，不用 UI 自报“PASS”。
4. 两音乐播放器同时运行，浏览器视频抢系统媒体焦点，用户 pin A 后 B 播放，QQ/网易失焦；全程核对实际控制对象。未知/失败不假报成功。
5. 词级歌词只在有真实词时间的文件上验收。用可合法测试的已知时码音轨/原播放器位置录制测时钟，不能拿歌词作者时码误差当播放器时钟误差；分别报告 source position error、lyric alignment error、display latency。
6. 精确源目标：连续10分钟 position error P95≤250ms；普通逐行源目标 P95≤750ms，若未达标就不得宣传精准同步。数字是工程验收目标，**本轮未测得**。QQ/网易若实际始终1s以上抖动，不以补间掩盖，应限制词级高亮或展示同步能力说明。
7. 正确暂停后 UI 不继续前进；失去 timing 显示歌词文本但不自造播放头；seek 读回无成功时不保持虚构新位置；相同标题不同版本不沿用旧歌词。
8. 安装版连续8小时，覆盖屏幕关闭/低电量/网络断开；记录主 app + helper 合计 CPU/RSS、进程数和网络请求；静止/暂停时渲染计时器停止，封面每曲不重复请求。具体资源预算由整套视觉方案确定后在 M5 目标机校准。
9. 未取得自动化权限、用户拒绝、之后设置中授权，恢复流程无需重装；退出 LyricTile 后没有遗留 helper。

## 8. 不采用的路线与原因

- 原生 macOS `SystemMusicPlayer`：当前官方 availability 不含原生 macOS；不是现有 Music.app 状态通用解。
- Spotify Web API 作为桌面首选：当前开发模式最多5个授权用户且需 allowlist，控制接口有 Premium/政策约束；为本机面板增加账号授权和远程状态延迟，价值不足。以后做 Spotify Connect 再独立评估，不以它保证当前桌面音频在本机播放。
- 每帧跑 osascript/media-control：进程开销过高；用事件+低频实际采样+本地时钟。
- 直接链接旧 LyricsX MusicPlayer.SystemMedia：该实现是旧直接 MediaRemote 路线，现代权限变化风险已被当前 helper 的存在说明；不能无条件当 macOS27 支持。
- 用全局 Now Playing override 进行“定向控制”：上游已经因系统级竞态撤回。
- 使用 AX 抓歌词/OCR/录屏识别作为主线：增加权限、易受 UI/语言变化影响；用户需求不要求，也不是可靠同步源。
- 把任何取得的 provider lyric 当已获版权授权：播放器能力与歌词版权是独立问题，必须交由歌词服务层的授权策略控制。

## 9. 一手资料索引

### 固定源码（无需依赖滚动 README）

- [adapter 固定 HEAD](https://github.com/ungive/mediaremote-adapter/tree/2ef957c736256cee7905c9f3f1c7e279087bf195)
- [adapter get.m](https://github.com/ungive/mediaremote-adapter/blob/2ef957c736256cee7905c9f3f1c7e279087bf195/src/adapter/get.m)
- [adapter send.m](https://github.com/ungive/mediaremote-adapter/blob/2ef957c736256cee7905c9f3f1c7e279087bf195/src/adapter/send.m)
- [adapter seek.m](https://github.com/ungive/mediaremote-adapter/blob/2ef957c736256cee7905c9f3f1c7e279087bf195/src/adapter/seek.m)
- [adapter stream.m](https://github.com/ungive/mediaremote-adapter/blob/2ef957c736256cee7905c9f3f1c7e279087bf195/src/adapter/stream.m)
- [adapter 时间格式化](https://github.com/ungive/mediaremote-adapter/blob/2ef957c736256cee7905c9f3f1c7e279087bf195/src/utility/helpers.m)
- [adapter 时间估算](https://github.com/ungive/mediaremote-adapter/blob/2ef957c736256cee7905c9f3f1c7e279087bf195/src/adapter/now_playing.m)
- [adapter build](https://github.com/ungive/mediaremote-adapter/blob/2ef957c736256cee7905c9f3f1c7e279087bf195/CMakeLists.txt)
- [adapter LICENSE](https://github.com/ungive/mediaremote-adapter/blob/2ef957c736256cee7905c9f3f1c7e279087bf195/LICENSE)
- [media-control CLI](https://github.com/ungive/media-control/blob/507575ce288a9238372b7f39fde44988612700d4/bin/media-control)
- [MusicPlayer Apple Music](https://github.com/ddddxxx/MusicPlayer/blob/f2090c48cecf12b86ddb3fc98f2fe90ed4dbb82f/Sources/LXMusicPlayer/Players/LXPlayerAppleMusic.m)
- [MusicPlayer Spotify](https://github.com/ddddxxx/MusicPlayer/blob/f2090c48cecf12b86ddb3fc98f2fe90ed4dbb82f/Sources/LXMusicPlayer/Players/LXPlayerSpotify.m)
- [Lyrimuse 播放器注册](https://github.com/Yudaotor/lyrimuse/blob/9d74d785be00faca056bc9b5b1575abe7b7820ea/shared/players.json)
- [Lyrimuse 控制路由](https://github.com/Yudaotor/lyrimuse/blob/9d74d785be00faca056bc9b5b1575abe7b7820ea/lyrimuse/Sources/LyrimuseCore/Local/MusicPlaybackController.swift)
- [Lyrics-Plus 自动化](https://github.com/afeibukaixin/Lyrics-Plus/blob/a6f5a32814fee2f3914414fd7fdfe0aeea4d2917/src-tauri/src/player/automation/mod.rs)
- [Lyrics-Plus 控制读回](https://github.com/afeibukaixin/Lyrics-Plus/blob/a6f5a32814fee2f3914414fd7fdfe0aeea4d2917/src-tauri/src/player/system/service.rs)
- [Lyrics-Plus 定向读取](https://github.com/afeibukaixin/Lyrics-Plus/blob/a6f5a32814fee2f3914414fd7fdfe0aeea4d2917/src-tauri/resources/system-media-targeted.js)

### 官方文档

- [Apple SystemMusicPlayer（含 availability）](https://developer.apple.com/documentation/musickit/systemmusicplayer.md)
- [Apple Events usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)
- [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events.md)
- [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime.md)
- [macOS Notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution.md)
- [App Review 2.5.1](https://developer.apple.com/app-store/review/guidelines/)
- [Spotify quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)
- [Spotify seek API](https://developer.spotify.com/documentation/web-api/reference/seek-to-position-in-currently-playing-track)
- [MPL FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/)

## 10. 可追溯素材

`evidence-metadata.json` 保存本轮 GitHub API repo/commit/release/tree 元数据；`sources/` 保存实际深读的两份 ungive 源码及补充 MusicPlayer 文件，供复核。不需要将这些第三方源码全文打包到面向用户的设计交付中；开发时按明确许可与固定提交重新引入即可。
