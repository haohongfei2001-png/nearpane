# LyricDomain：Swift 6 接口蓝图

`LyricDomainContracts.swift` 是可开发接口草案，定义领域类型与协议，**没有**播放器实现、联网实现、窗口实现或演示数据。它不表示产品已经运行。命名空间使用 `LyricDomain`，便于与 Media / Tile 契约同时放入一个 target。

本研究环境没有 Swift 编译器，因此没有宣称 typecheck 通过。Codex 进入 macOS 工程后先执行：

```sh
swiftc -swift-version 6 -strict-concurrency=complete -typecheck contracts/LyricDomainContracts.swift
```

随后按项目 package 布局分文件即可，不得借“只是蓝图”忽略编译错误。源码初始化器只赋值；合法性检查属于 parser、provider 与 adapter 入口，不通过构造空数据绕过。

## 模块边界

| 契约 | 实施位置 | 固定语义 |
|---|---|---|
| RecordingIdentity / Selection / Request | LyricDomain | ID 按平台/必要时 storefront 分域；session/generation 随切源或切歌改变 |
| PlaybackAnchor / MonotonicStamp | 媒体适配器 → 时间轴 | 本地单调时钟；可信度、位置误差与缺失位置明确表达 |
| SourceTiming / UserTimingAdjustment | 解析器 / 用户偏移存储 | 原始偏移与用户偏移分离；用户偏移绑定录音 fingerprint + 内容 hash |
| Document / Lane / Cue / Token | LyricDomain | sourceEndMS 为真实或未知；多语、和声、重叠段保留 |
| PresentedCue / Frame | 时间轴 → 渲染器 | displayHoldUntilMS 仅用于显示，不能写回原始时间 |
| UTF16Span | parser → Core Text layout | 引用 cue 原文，检查字素边界；不把 String.count 当 UTF-16 长度 |
| RightsEvidence / ProviderDescriptor | provider 注册表 | 软件许可、API 使用依据、歌词内容依据各自记录 |
| LyricSourceProviding | actor | 串行遵守各源限流；取消旧 Task 后仍检查 generation |
| LyricDocumentParsing / LyricMatching | 无状态 Sendable 值类型或 actor | 格式安全与身份判断独立，不让动画等级决定录音身份 |
| LyricTimelineProjecting | 时间轴模块 | 真实锚点外推；pause/seek/wake 重置规则，不累加帧 dt |

`Frame.selection` 可为空，首次没有任何播放时用nil与noPlayback表达；此时lookupMS为空、presentedCues为空，不能虚构录音、会话或预置歌曲。非空歌词/同步状态必须关联真实Selection。

`Frame.playbackState` 与 `Frame.phase` 分开：暂停时仍可显示逐字歌词的静止状态，不应把暂停变成缺词。`Document.instrumental == true` 只能来自来源明确标记或用户设定，不能由 404 推断。

`sourceAdvanceMS` / `userAdvanceMS` 正数均表示歌词提前；lookup = media + sourceAdvance + userAdvance。`SourceTiming.interpretation == unresolved` 时，sourceAdvanceMS 必须为 nil，不能猜测 Lyricsfile draft 的 offset_ms。零偏移与未知偏移是不同状态。

`RightsEvidence.territories == []` 表示未记载地域范围，不能理解为全球；cacheMaxAgeSeconds == nil 表示未记载许可/缓存约束，不能理解为无限缓存。`ProviderReleaseDisposition` 是发行政策的结果，不由 SDK key、HTTP 200、代码开源或用户勾选自动推导。

## 从现在到公开发行：具体处理

**工程主线照常完成**：4 个播放器适配、原生歌词板、时钟与渲染、本地导入、LRCLIB 客户端、TTML 读取、匹配器、缓存和来源显示并行推进。代码中的 provider 独立开关使某一词源的问题不会拖住整款应用或其他来源。

| 来源 | 现在可以确定的动作 | 公开默认启用条件 |
|---|---|---|
| 用户本地文件 | 完成导入、按录音绑定、离线显示；不上传、不再分发 | 不内置第三方整库；“用户提供”不等于已核验版权 |
| LRCLIB | 使用自身 User-Agent；实现 429/Retry-After、按需客户端缓存、字段回退；准备正式应用注册 | 保存注册/公开条款版本，核对 API authorization 是否确实覆盖本产品的全文歌词展示、商业模式、地域与缓存；不能把仅 API 访问许可填成内容许可 |
| AMLL TTML DB | 实现按平台 ID 定位、贡献者/来源展示、ETag 更新；工程内可检查格式与匹配 | 逐条遵守外来数据原许可，不把仓库 CC0 扩大为全部歌词；发布政策不清楚时只关闭这个 provider |
| 获授权商业词源 | 同一协议实现替换 adapter；无需更换歌词模型或 UI | 实际合同或适用公开条款覆盖所需展示/同步/缓存/地域，不以注册了 key 代替合同范围 |

公开源码和试验客户端不是免除歌词权利的办法；“用户主动开启”也不是许可替代品。相应地，不应因为一个社区源尚无明确内容依据，就停止其他来源和整个工程。

对外首发的具体推荐是：**先争取至少一个能明确覆盖全文歌词展示的网络来源作为默认源，保留社区源独立发布资格，本地导入始终可用。** LRCLIB 是技术上已核验可连接、成本最低的首要集成目标；其授权说明若不覆盖内容，就向 [Musixmatch 官方开发入口](https://developer.musixmatch.com/) 请求适合 macOS 桌面伴随面板的方案。官方 SDK 明确提供 licensed lyrics，但具体产品权益仍以所选方案条款为准。[官方说明](https://github.com/musixmatch/musixmatch-sdk/blob/master/README.md)

需要向来源方取得明确答案的内容只有五项：桌面第三方播放器伴随展示是否允许；免费/买断/订阅是否覆盖；全文、逐行/逐字及译文哪些可用；发行地域和归属展示；本地缓存时长及是否允许离线。把答复、条款 URL/版本、日期记录到 RightsEvidence；这属于一次明确的发行资格工作，不应转成无限期技术研究。未经用户明确授权不代发邮件或接受付费合同。

若到打包日仍没有满足条件的在线来源，**可以交付播放器控制与本地歌词版本，并如实限定能力；不能把它冒充本任务要求的完整自动歌词首版。** 更合理的是让所有确定性工程提前结束，最后只补入已批准 provider 凭据/策略，不为此重写应用。

## 与研究文件的关系

- `research/lyrics/LYRICS_AUDIT.md`：固定源码、许可证、关键缺陷和路线依据。
- `research/lyrics/lyric-model-contract.json`：跨语言字段契约。Swift 文件将持久 Document 与显示 Frame 更严格拆开；研究 JSON 不应当成自动代码生成 schema。
- `research/lyrics/lyric-acceptance-cases.json`：未来测试设计，原创 parser fixtures 不进入正式产品展示。
- `research/lyrics/lrclib-live-probe.json`：真实 API 字段检查；不代表播放器或 macOS 27 同步已通过。
