# LyricTile 歌词系统源码审计与实施裁决

审计日期：2026-11-26（Asia/Shanghai）。本报告的“已验证”仅指实际拉取源码、读取固定提交及一次公开 API 调用；没有在 macOS 27 运行产品，没有声称歌词覆盖率或逐字同步已通过实机验收。引用的完整源码位于本目录 repos，最终交接可只包含本报告与契约文件，避免将第三方仓库全部打包。

## 1. 结论

选择原生 Swift 的歌词领域模型、时间轴与 Core Text/AppKit 渲染。歌词服务以本地绑定/缓存、LRCLIB 公开 API、可按平台 ID 读取的社区 TTML 数据源组成分层回退。歌词来源和播放器来源必须分离：用户在 QQ 音乐播放，不等于一定从 QQ 的未公开接口取词。

直接复用应集中在边界明确的代码：LyricsKit 的 MPL-2.0 LRC/LRCX 核心可做隔离 fork；Lyrics-Plus 的 MIT 匹配证据与版本标签逻辑可移植并保留许可；TTML 可依据 W3C 规范与 MIT ttml-processor-rs 的语义模块实现原生适配。不要把 LyricsKit 的旧网络 provider、旧质量分数、LyricsX 整个 App 或 AMLL 的 AGPL DOM 渲染器整体带入新产品。

逐字是数据能力，不是动画设置：实际获取的歌词只有行时间戳时，只做逐行显示；有真实词/音节时间戳时才启用逐字遮罩。纯音乐、未找到歌词、只有纯文本、没有播放进度是四种独立状态。

## 2. 固定基线与维护判断

| 项目 | 本次默认分支 HEAD | HEAD 时间 UTC | 许可 / 发行情况 | 裁决 |
|---|---|---|---|---|
| ddddxxx/LyricsX | c16b6a413dda7bc0b793b897522e0c4ee0ffc716 | 2022-05-03 | MPL-2.0；latest release v1.6.3，2022-04-29 | 有价值的历史行为样本；不作为现代主程序底座 |
| ddddxxx/LyricsKit | 8a61b97cfc853858537e4ff0890d0ba16f20ebc9 | 2022-04-28 | MPL-2.0；无 GitHub Release | 隔离复用 LRC/LRCX 核心；新 provider 与匹配器自行实现 |
| amll-dev/applemusic-like-lyrics | f3297962e138038c8f14ec83580bc21b1e2f9beb | 2026-11-22 | core 0.7.2、lyric 1.1.0、ttml 1.0.1 的 package.json 均为 AGPL-3.0-only | 活跃维护；作为行为与格式参考，主线不依赖其实现 |
| amll-dev/amll-ttml-db | 533e9c52796db48f8bbde4394aee2b7d9db5d068 | 2026-11-20 | 根 CC0-1.0；README 对外来内容另作保留；无 Release | 活跃社区数据；精确 ID 读取可行，内容权利不能一概视为 CC0 |
| 补充：tranxuanthang/lyricsfile | 348cd04b9d002fac8f5f67694064605026f9d030 | 2026-07-23 | 规范 CC0-1.0；1.0 draft | LRCLIB 新逐字格式；feature detection，版本严格识别 |
| 补充：apoint123/ttml-processor-rs | 4b01f5ab8ce040b4b26413c414654d8b9833a293 | 2026-10-31 | MIT；crate 0.4.0 | 比 AGPL JS parser 更适合许可受控的语义复用；仍是 Apple/AMLL profile，不是通用 TTML |

GitHub 的 `pushed_at` 不能作为默认分支近期维护证据。LyricsX metadata pushed_at 为 2026-07-22，但默认 HEAD 仍是 2022；LyricsKit 同样有 2024 的 push 元数据但 2022 的 HEAD。AMLL 的 GitHub release 列表有历史 main-player-dev 标签，不能用它推断现有 packages 不活跃。完整 API 元数据保存于 `repository-evidence.json`。

## 3. 实际源码发现

### LyricsKit：可复用解析，不可原样复用匹配

`Sources/LyricsCore/Lyrics.swift` 能展开同一行的多时间标签，排序并用二分查找查当前行；`LyricsLineAttachment.swift` 包含 LRCX 的词时序、翻译、注音与音译附件。`Package.swift` 的核心与网络服务已经拆为 LyricsCore/LyricsService，但产品打包项仍同时包含两者，fork 应单独暴露 LyricsCore，减去无关 CXShim/CXExtensions/Gzip 网络依赖。[源码](https://github.com/ddddxxx/LyricsKit/tree/8a61b97cfc853858537e4ff0890d0ba16f20ebc9/Sources/LyricsCore)

发现一个能影响自动错配的确定问题：`Lyrics+Quality.swift:85–94` 中时长分公式对差值 dt=0 给出 0.5，dt=5 给出 0.875，dt=9 给出 0.995，dt>=10 又回到 0.5。在小于 10 秒的区间，离正确时长越远反而加分。本次用独立算式复核了这些值；没有运行整个 Swift 库。这一分数不得继承。[固定源码](https://github.com/ddddxxx/LyricsKit/blob/8a61b97cfc853858537e4ff0890d0ba16f20ebc9/Sources/LyricsService/Lyrics%2BQuality.swift#L85-L94)

`Provider/Group.swift` 是并行 flatMap 所有 provider，并非有预算、可解释的分层回退；多处将网络/解析错误吞成 `Never`。NetEase.swift 仍使用 HTTP 的旧 `/api/search/pc` 和 `/api/song/lyric`，QQMusic.swift 使用未公开的 QQ web endpoint、Referer 与 JSONP 固定切片；它们的代码开放许可不意味着平台 API 商业授权，也不证明 2026 可用。[网易源](https://github.com/ddddxxx/LyricsKit/blob/8a61b97cfc853858537e4ff0890d0ba16f20ebc9/Sources/LyricsService/Provider/NetEase.swift) · [QQ 源](https://github.com/ddddxxx/LyricsKit/blob/8a61b97cfc853858537e4ff0890d0ba16f20ebc9/Sources/LyricsService/Provider/QQMusic.swift)

### LyricsX：原生同步与低频调度可参考，形态不继承

`AppController.scheduleCurrentLineCheck()` 计算下一行边界再安排定时，播放状态改变重新调度，避免为了逐行歌词持续高频刷新。`SelectedPlayer.swift` 依赖另一个仓库 ddddxxx/MusicPlayer，播放时以一秒间隔补读状态；LyricsX 本身不包含完整播放器适配代码。其 Package.resolved pin MusicPlayer 0.8.2 / 50904bac7aec79c5842f2ec3d1a1d858496dd6fe。[控制器](https://github.com/ddddxxx/LyricsX/blob/c16b6a413dda7bc0b793b897522e0c4ee0ffc716/LyricsX/Component/AppController.swift) · [播放器选择](https://github.com/ddddxxx/LyricsX/blob/c16b6a413dda7bc0b793b897522e0c4ee0ffc716/LyricsX/Component/SelectedPlayer.swift)

`KaraokeLabel.swift` 用 Core Text 布局并以 CALayer 遮罩 / CAKeyframeAnimation 显示词进度，但源码明确 TODO multi-line，实际只取第一个 CTLine；不能当作长歌词、RTL、换行后遮罩已经正确。其 KaraokeLyricsController 使用覆盖整个 screen visibleFrame 的透明窗口，也不适合 LyricTile 的紧凑命中区域。[标签](https://github.com/ddddxxx/LyricsX/blob/c16b6a413dda7bc0b793b897522e0c4ee0ffc716/LyricsX/View/KaraokeLabel.swift) · [窗口](https://github.com/ddddxxx/LyricsX/blob/c16b6a413dda7bc0b793b897522e0c4ee0ffc716/LyricsX/Controller/KaraokeLyricsController.swift)

### AMLL：优秀行为参考，不能简单称为轻量原生库

已读 `packages/core/src/lyric-player/base/{timeline,focus,seek-detector}.ts`、DOM 遮罩动画、歌词 types、QRC/YRC/LRC parsers、`packages/ttml/src/parser.ts`。其 Timeline 将正在唱、仍保留高亮、滚动焦点分开；FocusController 在用户滚动时冻结自动对齐；WebMaskAnimator 以真实媒体时间设置已创建的动画。这些是应吸收的产品语义。[时间线](https://github.com/amll-dev/applemusic-like-lyrics/blob/f3297962e138038c8f14ec83580bc21b1e2f9beb/packages/core/src/lyric-player/base/timeline.ts) · [焦点](https://github.com/amll-dev/applemusic-like-lyrics/blob/f3297962e138038c8f14ec83580bc21b1e2f9beb/packages/core/src/lyric-player/base/focus.ts)

但它是 DOM/Web Animations/WebGL 的实现，不应为了复制 Apple Music 流光背景引入 WKWebView 常驻整套运行时。SeekDetector 的 150ms / 800ms 等常量服务于其浏览器推送节奏，不能直接当作 MediaRemote 的测量精度。[遮罩](https://github.com/amll-dev/applemusic-like-lyrics/blob/f3297962e138038c8f14ec83580bc21b1e2f9beb/packages/core/src/lyric-player/dom/animation/mask/animator-web.ts)

AMLL 的 TTML parser 支持多语译文、音译、对唱/背景人声，但 `parseTime` 只处理十进制秒、冒号时间、末尾 s；例如 200ms 不会正确处理，未知值会变成 0。没有完整实现 TTML frame/tick/timeContainer 语义；不能声称通用 TTML 兼容。XML 安全行为依赖注入的 DOMParser，入口没有显式 DTD / 实体 / 长度限制。[解析器](https://github.com/amll-dev/applemusic-like-lyrics/blob/f3297962e138038c8f14ec83580bc21b1e2f9beb/packages/ttml/src/parser.ts#L481-L513)

### TTML DB：平台 ID 是最强入口，版本仍需核验

已读 `scripts/rebuild-folder/src/main.rs` 与审核 bot 的 validator。重建脚本读取原始 TTML 元数据，按 ncmMusicId、qqMusicId、spotifyId、appleMusicId 建索引并拷贝 TTML；也存 ISRC。多个原始文件的同平台 ID 在任务映射中会由后条目覆盖，因此客户端应缓存文件 hash / ETag 与来源版本，不把 ID 当成内容永不变化的承诺。[重建](https://github.com/amll-dev/amll-ttml-db/blob/533e9c52796db48f8bbde4394aee2b7d9db5d068/scripts/rebuild-folder/src/main.rs)

validator 检查 metadata、非零时间戳、行尾不早于行首、音节时间次序；这些检查不能保证歌词匹配当前录音，也不是专业权利链验证。支持路径为 `am-lyrics/{id}.ttml`、`spotify-lyrics/{id}.ttml`、`qq-lyrics/{id}.ttml`、`ncm-lyrics/{id}.ttml`。若只有标题/歌手，可本地检索下载后的轻量 metadata index；禁止每次切歌下载整库或遍历 GitHub tree。[校验器](https://github.com/amll-dev/amll-ttml-db/blob/533e9c52796db48f8bbde4394aee2b7d9db5d068/scripts/lyric_checker_bot/src/validator.rs)

### 新增可复用 TTML 备选：MIT ttml-processor-rs

0.4.0 使用 quick-xml 事件解析，model 保留多语译文、词、背景人声、agent、platform IDs；实体解析仅接受数字字符引用与 XML 预定义实体，未知实体报错。仍需产品入口限制 DTD/大小/深度，且标签匹配和时间格式是 Apple/AMLL profile，不能原样覆盖任意 namespace 前缀及 TTML 全规范。可保留 MIT 声明移植语义至 Swift XMLParser；若要直接编译 Rust，使用静态 C ABI 并仅在读文件时调用，作为次选，不引入运行中的 CLI 解析进程。[model](https://github.com/apoint123/ttml-processor-rs/blob/4b01f5ab8ce040b4b26413c414654d8b9833a293/crates/processor/src/model.rs) · [parser](https://github.com/apoint123/ttml-processor-rs/blob/4b01f5ab8ce040b4b26413c414654d8b9833a293/crates/processor/src/parser/mod.rs) · [实体](https://github.com/apoint123/ttml-processor-rs/blob/4b01f5ab8ce040b4b26413c414654d8b9833a293/crates/processor/src/parser/utils.rs#L155-L170)

## 4. LRCLIB：本次真实接口检查与接入约束

2026-11-26 02:52 CST，通过已标识的研究 User-Agent，对官方文档示例 GET 发出一次只读请求，HTTP 200，ID 3396226，确实返回 `plainLyrics`、`syncedLyrics`、`hasWordSync` 与 `lyricsfile`。只保存字段/长度摘要，不把歌词下载当成播放同步能力。详情见 `lrclib-live-probe.json`。

当前公开文档要求标识客户端；可选注册客户端用公开 App ID，secret API key 只用于服务器。429 必须尊重 Retry-After 并加 jitter；请求串行，批操作间隔 200–500ms。公开的额度是近似动态值，不能硬编码成无限。`/api/get` 建议传标题、歌手、专辑、时长，时长匹配约 ±2 秒；`/api/search` 为宽搜索，要由客户端再做版本判定。v2 search 是 beta，不作为 1.0 必需依赖。[官方文档](https://lrclib.net/docs.txt)

`lyricsfile` 是新增 YAML 格式，可包含真实 word timings。官方 1.0 仍是 draft：未知版本不能当 1.0；offset_ms 语义未定；缺少 end_ms 不能写回臆造的结束时间；允许重叠行/词。1.0 首发实现严格受限 reader 是可行的：安全 YAML parser、拒绝重复 key / custom tag / alias expansion，未知版本退回 syncedLyrics，再退 plainLyrics。只存在真实 word start 时可按词进入高亮；缺失 end 时不要伪造持续扫字。[规范](https://github.com/tranxuanthang/lyricsfile/blob/348cd04b9d002fac8f5f67694064605026f9d030/SPECIFICATION.md)

## 5. 确定的歌词检索与匹配决策

### 请求链

1. 为选中播放器产生 recording generation token；同一 track ID、版本、时长构成录音身份，进度变化不触发重新检索。
2. 先读用户明确绑定的本地歌词；随后读该 recording 的已确认缓存。
3. 有可信平台 ID 时，查询被启用的数据源的精确 ID 路径；有 ISRC 可查索引，但 ISRC 相同也检查时长和版本。
4. 以完整 metadata 请求 LRCLIB get；未命中后才做一次 search。各 provider 自己串行、整体最多两个独立来源并发，切歌立刻取消旧 generation。
5. 优先选择“录音身份正确”，再在同等身份中选择逐字、译文等能力。不得让漂亮的逐字版本覆盖正确的逐句版本。
6. 低置信度显示新歌曲信息与“选择歌词”，候选界面只出现一次简短标题/歌手/专辑/时长/来源；用户选择绑定当前 recording，不把结果推广给同名所有版本。

### 自动接受门槛（产品设计值，尚未测得覆盖率）

- 精确平台 ID + 没有冲突可自动接受；数据里明确的歌手/版本/时长冲突仍需检查，不能只信 URL。
- metadata fallback：主歌手相符、标题核心相符、无 live/remix/acoustic/clean/explicit/sped-up 等冲突；已知时长差 <=2 秒优先自动接受，2–5 秒需要额外专辑/版本或用户确认，>5 秒不自动接受。
- 标题中没有 live 不证明一定 studio；不能剥去所有括号后就认作同一录音。
- 默认不通过音频录制、OCR、麦克风或屏幕读取找歌词；首版不需要这些权限。
- 匹配分不是准确率概率。记录候选特征与拒绝原因，发布前使用包含翻唱/现场/重制/同名曲的真实歌曲集核验。

缓存键至少包含 provider、provider record ID、recording fingerprint、document hash、parser schema version。正缓存用来源版本/ETag 刷新，缺词负缓存短期保留；用户手动选词与 offset 永久优先。只改变输出设备不重新匹配歌词，也不破坏用户偏移。

## 6. 统一模型与同步

完整字段约束见 `lyric-model-contract.json`。模型必须具备：`LyricDocument` 的来源/权利状态/原格式/语言/元数据；多个独立 `LyricLane`（主唱、和声、译文、音译、注音）；每个 cue 的真实 start 与可选真实 end、稳定 ID、演唱者；可选词/音节 timing；独立的显示保留边界。使用整数毫秒作持久格式，播放器 clock 使用单调时间与浮点秒再统一转换；不要每帧累加 dt。

显示位置 = 已确认的媒体锚点位置 + 单调时钟差 × playbackRate，仅在 playing 且锚点可信时外推。暂停固定位置；seek 和切歌立即重置，不从旧行慢慢滚过去。恢复唤醒先重新读取状态再继续动画。外推是以真实锚点为依据的显示插值，失去可信位置后不得继续让进度看似正常流动。

偏移统一约定：用户点“歌词提前”会增加 advanceMS，查询时间 `lookupMS = mediaMS + sourceAdvanceMS + userAdvanceMS`；UI 使用“提前/延后”文字而不是暴露难懂正负号。原始 LRC offset 经 parser 独立归一；Lyricsfile draft 的 offset_ms 不擅自继承 LRC 约定，保留诊断并降级。用户偏移绑定歌词文件 hash + 当前录音，换版本不沿用。

渲染时保留 Unicode 原文；匹配可用规范化副本。不要以 Swift Character 数直接当 Core Text UTF-16 offset。将每个 token 映射至 grapheme-safe UTF-16 range，缓存 CTLine/CTRun 分段与实际换行位置。逐字遮罩对各行/各 bidi run 独立推进；CJK、连字、emoji、阿拉伯文混排不能用整行宽度比例代替字形映射。

`instrumental` 必须来自来源明确标记或用户设定；404 只表示没找到。LRC 通常没有真实行结束，无法从长句间隔确信是间奏：保留上句/轻提示“等待下一句”，不捏造有规律的节拍。TTML 明确前句结束到后句开始有空白时，可显示静态或低频 dots；不做假音频可视化。

## 7. 格式范围与安全边界

| 格式 | 1.0 处理 | 不做的推断 |
|---|---|---|
| 普通 LRC / LRCX | 多 timestamp、offset、常见编码；LRCX 词标签/翻译按字段解析 | 不把整行时长均分为伪逐字 |
| Enhanced LRC | 读 `<mm:ss.xxx>` 的真实词起点；缺尾点保持未知 | 不改写原始 timing |
| TTML Apple/AMLL profile | namespaces、body/div/p/span、begin/end、译文/音译、agent、背景人声 | 不宣称支持任意字幕 TTML |
| QRC / YRC | 已解密文本文件，真实行起点+时长、词起点+时长 | 首版不要求平台密文破解/抓取 |
| Lyricsfile 1.0 draft | 严格 version，字/行时点，明确无词状态；不支持字段安全保留或回退 | 不猜未知 version 与 offset 语义 |
| 纯文本 | 手动浏览，不自动“同步” | 不自动估计整曲歌词时间 |

TTML 使用真正 XML 解析器，禁止 DTD、外部实体和网络加载；2 MiB 解压后上限、层级 <=32、cue <=10,000、token <=100,000，越界报告可恢复错误。支持十进制秒、标准 clock、s/ms/min/h 的 offset 表达；遇到 f/t/frameRate/tickRate、seq/复杂父时序而未实现时必须返回 unsupported timing profile，不得变成 0。这里的上限与 profile 是 LyricTile 设计约束，非上游承诺。W3C TTML2 提供时间表达与继承语义依据。[规范](https://www.w3.org/TR/ttml2/)

## 8. 许可、歌词内容和发布路线

MPL-2.0 允许和其他独立文件组成闭源 larger work，但所分发的 MPL 文件及修改要提供对应源码、保留声明与获取方式；移植/改写含 MPL 代码的新文件仍属于 covered software。建议建立单独 `Vendor/LyricsCoreMPL` 模块并在关于页提供来源。应用其他代码不必因此全部公开。[Mozilla FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/) · [条款 3.1–3.3](https://www.mozilla.org/en-US/MPL/2.0/)

AMLL 各包是 AGPL-3.0-only。将其嵌入 WKWebView 或翻译为 Swift，不会自动消除许可证义务；若形成结合程序，发行时不能把整体继续按闭源产品处理。可以选择完整兼容 AGPL 的产品路线或另获授权，但会直接影响未来 Nearpane 集成，因此本轮主线不选。只借鉴公开交互思想与依据独立规范重新实现，不复制受限表达。[AMLL package license](https://github.com/amll-dev/applemusic-like-lyrics/blob/f3297962e138038c8f14ec83580bc21b1e2f9beb/packages/core/package.json) · [GNU FAQ](https://www.gnu.org/licenses/gpl-faq.html)

代码许可、API 使用许可、歌词著作权分别记录。TTML DB README 明确外来数据继续遵守原提供方协议，只有提交者自主编写部分 CC0。LRCLIB 文档开放 API 给应用，不构成整库歌词权利保证；仓库 issue #134 的商业歌词授权询问截至本轮仍没有维护者答复，不能用其他用户评论作为法律结论。注册返回的 API authorization 文档应核对具体范围，不能自行升级为词曲版权授权。[DB 条款](https://github.com/amll-dev/amll-ttml-db/blob/533e9c52796db48f8bbde4394aee2b7d9db5d068/README.md#共享协议) · [LRCLIB #134](https://github.com/tranxuanthang/lrclib/issues/134) · [CC0 的权利范围](https://creativecommons.org/publicdomain/zero/1.0/legalcode.en)

工程可直接完成公开 API 客户端、按需缓存、来源信息与手动导入。正式对外宣传不写“拥有完整授权曲库”或“所有歌曲可用”。公开默认网络歌词服务的发布资格应由真实授权范围与产品发行地区决定；若发行需要明确内容许可，应接获授权的商业服务，合同是这里唯一不能由代码推导出来的事项。免费发布也不自动免除歌词权利问题。无需因此阻塞原生界面、播放器控制或本地导入开发。

具体实施不再留作泛泛的“版权待研究”：每个 provider 分别记录 API 许可和内容依据、条款日期/版本、地域、缓存与归属要求，并用独立发行开关控制。先完成 LRCLIB 客户端和正式注册准备，核对其授权文档是否包含本产品全文歌词展示；若仅批准 API 访问，按同一接口接入明确授权的商业源。需要来源方明确的五个问题及发布顺序见 `../../contracts/README-LyricDomain.md`。本地导入版可以独立交付，但不得被描述为已经满足完整自动歌词产品目标。

## 9. 验收与本机待验证清单

本轮已验证：四个指定仓库 HEAD/许可/源码；额外 Lyricsfile 与 MIT TTML parser 固定源码；LyricsKit 时长公式反向问题；LRCLIB 一次真实 HTTP 200 的响应字段。仅源码支持：TTML 多语言/背景声模型、QRC/YRC 解析、媒体状态变化触发重新调度等。尚未验证：macOS27 编译、4 个播放器实际字段/时钟质量、真实歌词覆盖、长期耗能与 Glass/Core Text 实际渲染。

Codex 必须完成：

- 以自有/许可测试歌词建立解析回归：多标签 LRC、跨小时、重复起点、错序、负 offset、emoji/组合字符/RTL、多行长句、TTML namespace/实体/DTD/损坏/限额、重叠唱段、零长词、缺 end、Lyricsfile 未知版本与重复 key。真实歌曲歌词不得直接提交公共测试仓库。
- 使用至少 120 个真实 recording，包含中文/英文/日文/韩文及至少 30 个版本混淆样本；报告实际自动接受率、接受结果正确率、错版本次数、来源命中率与逐字占比，不把覆盖率伪装成准确率。
- 错误候选、旧 generation、同名换版本不得进入当前界面；未知进度不能假同步；未命中与纯音乐不能混淆。
- 实机测 pause/resume、连续 seek、切歌后旧请求晚到、断网、唤醒、媒体源切换、输出至 AirPlay/蓝牙造成的音频延迟。把“源位置误差”“歌词时轴误差”“UI 响应误差”分开记录。
- UI 性能只对当前可见 cue/token 做动画；暂停、隐藏、纯文本、无播放时停掉高频刷新。Core Text 布局缓存随内容/宽度/字体变化更新，不能每帧重新排全部歌词。

这些是发布验收要求，不是本轮已经达到的结果。

## 10. 可供总报告引用的检索来源

- LRCLIB docs：web ref `turn245580675view0` / `turn472206610search0`。
- Lyricsfile spec：`turn140624425search3`；仓库规范固定提交见上文。
- MPL FAQ / 正文：`turn472206610search2` / `turn472206610search3`。
- GNU combined-program FAQ：`turn472206610search4`。
- TTML2：`turn140624425view0`。
- CC0 legal code：`turn140624425view1`。
- TTML DB README：`turn245580675view1`。
- LRCLIB commercial-use issue #134：`turn456493039view1`。
- ttml_processor 的 docs.rs latest 搜索缓存显示的是旧 0.2.0，不可当成当前 0.4.0；当前版本由 crates.io live API 和本地 git fixed HEAD 交叉确认。

总报告根代理引用这些 web ref 前应自行 open；永久 GitHub 源码链接可直接用于开发交接。
