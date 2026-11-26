# HOLDSNOW · LyricTile

## 独立歌词板产品设计、技术研究与开发路线裁决

**版本：设计与架构定稿 1.0｜研究基线：2026年11月26日，北京时间**

本轮交付设计、源码审计、实现契约和后续执行指令。已完成真实源码读取、公开接口探测和高保真原型渲染；没有运行 macOS27 产品，也没有将设计样句、网页原型或源码声明记作播放器实测。下文用「已验证」「源码支持」「待实机」明确区分证据。

## 1. 最终裁决

**值得做，但必须以“安静、可靠、固定在手边的一张词页”赢得用户。悬浮歌词本身已经是成熟品类，不能作为首创卖点。**

产品工作名保留 **LyricTile**，中文描述名为“歌词板”，母品牌为 **HOLDSNOW（握雪）**。独立版不依赖 Nearpane、不要求安装其他 HOLDSNOW 软件。它自动跟随已有播放器，显示正在演唱的歌词；悬停出现封面与控制；离开恢复阅读。首版以免费独立工具验证使用价值，不加入账号、推荐、社区、歌单管理或AI助手。

核心技术确定为 **Swift + AppKit 窗口与歌词排版 + SwiftUI 配置和控制**。Apple Music、Spotify使用定向Apple Events；QQ音乐、网易云音乐使用独立MediaRemote兼容桥。歌词系统与播放器分开：播放器只负责“哪首歌、什么时间、能做什么”，歌词源负责“哪个版本、真实时码与文本”。

视觉只落地 **A「雾白词页」**。面板悬停不改变外框，当前歌词不移位，控制在预留区域内出现。封面只在控制层显示，最多提供很轻的环境色。这样保证与 Saytile、Riftlet 共列时不跳动，也保留独立产品的安静感。

轻量TileKit只做布局、NSPanel壳和同品牌进程间占位；不做统一播放器、账户、网络、截图、语音或插件平台。Nearpane未来直接加载同一领域核心和LyricView。独立产品首发不等待Nearpane窗口管理引擎完成。

## 2. 独立价值与差异化

目标场景是用户一边写作、编程、与AI对话或处理资料，一边用原有软件听歌。用户要的是一瞥能看懂当前歌词、手移过去就能暂停或切歌，而不是把音乐软件缩小后常驻桌面。

产品的价值顺序：**选对歌 → 跟对时间 → 字读得清 → 操作确实控制正确播放器 → 长期放着不烦 → 与其他组件排列一致。** 外观只有在前四项成立后才有竞争力。不能用更漂亮的错歌词取代较朴素的正确版本，也不能把平滑动画当作同步准确。

| 参照产品 | 已核实的主要优势 | 本产品应吸收 | 本产品的不同取舍 |
|---|---|---|---|
| Apple Music | 原生歌词、当前行聚焦、支持有歌词时的时间同步；具体歌曲可退全文文本 | 阅读层级、自然过渡、原文可读性 | 陪伴现有多播放器，不新建完整播放界面 |
| Lyrimuse | 当前v1.14，广播放器/歌词源、逐字、多种展示面、翻译/听歌记录；实际Swift+Go多组件 | 来源分级、歌曲版本、非激活hover、局部刷新 | 单一窄词页、极少设置、稳定同列；不做功能数量竞赛 |
| LyricsX | 原生桌面歌词、LRCX、按下一句边界调度、CoreText遮罩经验 | 成熟格式与低频调度思路 | 主线已久未更新，窗口/解析/网络不能直接当2026底座 |
| Lyric Fever | 菜单栏、卡拉OK、全屏、翻译、缓存；定向ScriptingBridge | Apple/Spotify接口映射、整合复杂度低的体验 | 不要求用户提供Spotify网页登录cookie；不复制固定时间补偿 |
| Lyrics-Plus | MIT，Provider健康、匹配、多个展示面、控制读回 | 版本冲突规则、有限请求、错误分类 | 不搬Tauri/React整套运行时；保留未来原生Host嵌入能力 |

这些判断来自实际仓库源码和原仓库界面图；没有引用竞品自称的CPU降幅作为本产品指标。竞品视觉图仅作内部研究，没有把上游歌词、艺人肖像或封面复制进本产品设计稿。[Apple歌词说明](https://support.apple.com/en-us/guide/music/musf438ffc97/mac) · [Lyrimuse](https://github.com/Yudaotor/lyrimuse) · [LyricsX](https://github.com/ddddxxx/LyricsX) · [Lyric Fever](https://github.com/aviwad/LyricFever) · [Lyrics-Plus](https://github.com/afeibukaixin/Lyrics-Plus)

建议的成败指标是“无需修正即可持续显示正确同步歌词的会话比例”，其次是第一次有效歌词出现时间、控制读回成功率、错版本/错播放器次数和静止资源成本。首版不默认上报听歌历史；开发验收可以本地聚合这些指标。

## 3. 设计已经收敛到什么程度

交互原型 `design/LyricTile-Design.html` 包含三个实质不同的视觉方向、最终桌面场景、悬停播控、明暗与复杂背景、暂停/间奏/纯音乐/缺词/断连/未播放、长歌词与多语言、首次使用、设置和独立/宿主两种生态布局。它能在本地切换状态并查看菜单；所有示例都标为原创视觉样句，不模拟真实音乐接入。

完整实施规范在 `docs/DESIGN_SPEC.md`，结构化数值在 `contracts/design-tokens.json`。生成的图标材质概念、确定性SVG符号与图标母版一并提供。HTML、PDF与PNG稿用于评审；Swift实现应使用原生材质和真实字形排版，不直接包一层WebView交付。

### 三个方向的裁决

- **雾白词页：最终选择。** 常态强调文字，悬停显控制，和语音/截图共享窄列。复杂桌面与缺封面情况下仍可保持一致。
- **封面回声：不进入1.0。** 情绪表现力强，但更像常驻小播放器；封面会抢走歌词与工作内容的注意力。
- **双行字幕：不进入1.0。** 单独用很轻，横向宽度却破坏共同列，完整播控容易拥挤。保留其简洁文字层级，不再维护第二套窗形。

### 几个不能在开发时改掉的决定

默认宽为 `clamp(176,224,4×round(visibleWidth/32))` pt，高272pt，圆角22pt，右/上边距16pt，列间距10pt。这里的1/8以逻辑可见桌面宽计算，不是4K物理像素。Nearpane嵌入后服从Host宽度，不能让独立列规范反过来改坏Host。

当前歌词18–20pt，较大档22pt；上下文12pt。浅色墨字、深色灰白字，正文目标对比≥4.5:1。阅读底层使用标准雾面材质，Liquid Glass只少量用于控制。苹果也明确区分了内容层的标准材质与控件层的Liquid Glass。[Apple Materials](https://developer.apple.com/design/human-interface-guidelines/materials)

指针进入140ms确认，控件160ms淡入；离开280ms后180ms淡出。正在拖动进度、操作菜单或保有键盘/读屏焦点时不收起。行切换220ms，位移不超过8pt，不弹跳。词级填充按真实媒体时间线性推进，没有词时码不做假逐字，没有行时码不做假同步。

返回播放器独立为箭头按钮；点击带下拉指示的曲名打开歌词版本、校准、导入、来源。正常播放也能修正错配。校准页面只影响当前录音与歌词文件；主面板不堆数据源和调试参数。

### 首次使用与权限

一个欢迎页，按钮“开始使用”。发现已运行播放器后按需请求Apple Music/Spotify自动化许可；不为了探测授权启动所有播放器。默认不要求辅助功能、录屏、麦克风、完全磁盘访问。网络查词清楚说明会发送歌曲名称、艺人、专辑和时长等匹配信息。没有账号注册前置步骤。

首版不读取Apple Music/Spotify/QQ/网易私有缓存或浏览器cookie。高级失焦控制若将来确需AX菜单，再按需要增加单独开关，不把它变成所有用户的基础权限。

## 4. 当前生态与集成依据

本轮刷新了用户项目，不能沿用记忆中的旧版本：

| 仓库 | 固定审阅提交 | 当前与歌词板有关的事实 |
|---|---|---|
| Nearpane PR15 | 6ac5eb63c97b7597e662770bac485be61f571bb8 | 已直接嵌入Saytile/Riftlet域模块；1470pt屏默认宽240pt，已不是严格1/8 |
| Saytile main | f3baa0a255931dbb16291690699790e3d54f8bde | 默认visibleFrame×1/8，原生非激活面板，浅玻璃；正式v1.0.0 |
| Riftlet main | 2b270aec5cf57d2b4165acd52bcc730fa1052a02 | 已正式v1.0.11；托盘按屏宽1/8，多NSPanel构成，有自身定位与展开语义 |

三者目前没有共同跨App排列协议。自动协作需要各产品做一层小更新，不能承诺LyricTile单方面排列所有旧版本。现有自有代码的复用得到用户任务授权，但第三方依赖的许可证仍分别遵守。逐文件证据在 `research/ecosystem/ECOSYSTEM-AUDIT.md`，包含窗口level、collectionBehavior、材质、显示器恢复与域锁文件的固定链接。

## 5. 开源审计总表与真正的复用清单

HEAD均为本轮读取的固定快照，后续更新必须重新评估差异，不用moving main当可重现依赖。维护情况以默认分支实际提交和release为准，不能把GitHub `pushed_at`当默认分支更新时间。

| 项目 | 固定HEAD短码 / 当前版本 | 许可与维护 | 最终用途 |
|---|---|---|---|
| Yudaotor/lyrimuse | 9d74d785 / v1.14.0 | GPL-3.0；近期活跃 | 研究行为、边界与踩坑；主线不链接/翻译其代码 |
| afeibukaixin/Lyrics-Plus | a6f5a328 / v2.2.20 | MIT；2026-09-30主线，仍有维护活动 | 选择性移植匹配、健康管理、AppleEvents、读回策略 |
| ungive/mediaremote-adapter | 2ef957c7 / v0.9.0 | BSD-3-Clause；11月23日更新 | **固定版本直接复用兼容桥**，自行构建/嵌套签名 |
| ungive/media-control | 507575ce / v0.9.0 | 脚本/README声明BSD-3-Clause，但顶层LICENSE链接缺失 | 开发诊断；不再给产品套多一层CLI |
| ddddxxx/LyricsX | c16b6a41 / v1.6.3 | MPL-2.0；默认HEAD 2022-05-03 | 调度与CoreText历史实现参考，不用整App |
| ddddxxx/LyricsKit | 8a61b97c | MPL-2.0；默认HEAD 2022-04-28 | 隔离fork LRC/LRCX核心，移除旧provider/评分器 |
| amll-dev/applemusic-like-lyrics | f3297962 | 相关包AGPL-3.0-only；2026-11-22 | 交互/格式行为参考；不引入DOM/WebGL渲染器 |
| amll-dev/amll-ttml-db | 533e9c52 | 根CC0，外来内容保留原条款；2026-11-20 | 可选精确平台ID数据源；不能把整库权利认定为CC0 |
| lrclib.net | 当前docs.txt+实际HTTP200 | 公开API；新增注册/限流/逐字字段 | 主网络客户端，按条款标识客户端并尊重429 |
| 补充：ttml-processor-rs | 4b01f5ab / 0.4.0 | MIT；2026-10-31 | 移植语义到Swift XMLParser；优先于AGPL JS parser |
| 补充：Lyric Fever | 20a44f0f | MIT；本轮精读两播放器/歌词provider/视图 | 适当接口参考；排除固定偏移和主动play纠漂 |

完整SHA、许可证位置和源码符号位于 `contracts/source-lock.json` 与三份审计附录。

### 四个会实质改变实施的源码发现

1. **MediaRemote定向读取不等于定向控制。** v0.9的`get --bundle-id`能读指定源；`send/seek`仍作用于系统当前媒体。上游定向控制尝试已明确撤回全局override方案。产品不得临时改系统Now Playing归属来伪装定向控制。[adapter send](https://github.com/ungive/mediaremote-adapter/blob/2ef957c736256cee7905c9f3f1c7e279087bf195/src/adapter/send.m) · [issue41更正](https://github.com/ungive/mediaremote-adapter/issues/41)
2. **不使用默认整数秒时间戳。** `helpers.m`默认日期序列化丢小数，必须启用`--micros`，再建立单调时钟。微秒单位不提高上游实际精度。adapter seek用微秒，而media-control seek用秒。[helpers](https://github.com/ungive/mediaremote-adapter/blob/2ef957c736256cee7905c9f3f1c7e279087bf195/src/utility/helpers.m)
3. **LyricsKit旧匹配公式存在反向趋势。** dt=0、5、9秒分别给0.5、0.875、0.995，≥10又回0.5。不能沿用这个排序；版本冲突必须先否决，时长差越大不应获得更多支持。[固定公式](https://github.com/ddddxxx/LyricsKit/blob/8a61b97cfc853858537e4ff0890d0ba16f20ebc9/Sources/LyricsService/Lyrics%2BQuality.swift#L85-L94)
4. **TTML必须是真正解析。** Lyrics-Plus手工find标签，AMLL parser也不是完整通用TTML；首版实现明确定义的Apple/AMLL profile，未知时制返回unsupported，不能变成0。[Lyrics-Plus parser](https://github.com/afeibukaixin/Lyrics-Plus/blob/a6f5a32814fee2f3914414fd7fdfe0aeea4d2917/src-tauri/src/lyrics/parser/ttml.rs) · [MIT替代解析器](https://github.com/apoint123/ttml-processor-rs/tree/4b01f5ab8ce040b4b26413c414654d8b9833a293)

## 6. 四播放器的最终路线与支持范围

**四个平台都进入首版实施，不因为QQ/网易没有同等接口就提前放弃。但本轮没有任何平台取得“本产品实机已支持”的资格。** Apple Music和Spotify完整路径是首发硬目标；QQ/网易按真实时钟及命令能力发布可用子集，绝不把未测控件标成成功。

| 平台 | 信息/进度主线 | 控制主线 | 实机待确认 |
|---|---|---|---|
| Apple Music | ScriptingBridge currentTrack/playerPosition/playerState，通知+低频校准 | 发向Music实例的AppleEvents：play/pause/前后曲/position | sdef单位、流媒体/本地曲、广告/广播、签名后TCC、音频路由延迟 |
| Spotify桌面版 | ScriptingBridge，duration毫秒与position秒分开 | 发向Spotify实例的AppleEvents | 本地/Connect/广告、暂停/seek、后台状态与封面 |
| QQ音乐Mac | adapter真实系统会话与按需定向get | 当前系统源身份和能力均吻合时才允许全局控制 | 进度量化/抖动、暂停seek是否自动开播、失焦能否安全发命令 |
| 网易云音乐Mac | 同上 | 同上；失焦seek不预先承诺 | 媒体会话冷启动、位置质量、后台会话消失、命令执行读回 |

Apple当前官方 `SystemMusicPlayer` availability没有列原生macOS；不能把“MusicKit能控制Music”泛化为本产品现成通路。Apple Music `hasLyrics`只是存在性标记，不能当歌词全文/TTML接口；ScriptingBridge `lyrics`文本属性也不能证明订阅歌曲有可取的同步词。[SystemMusicPlayer](https://developer.apple.com/documentation/musickit/systemmusicplayer.md) · [Song.hasLyrics](https://developer.apple.com/documentation/musickit/song/haslyrics)

Spotify Web API不作为桌面伴随主线，避免引入帐号OAuth、Premium/配额/远端设备路由等额外条件；没有可据此承诺的公开歌词全文接口。若将来支持跨设备Spotify Connect，再作为独立功能设计。[Spotify Web API](https://developer.spotify.com/documentation/web-api/reference)

### 多播放器仲裁

仅把四个目标原生App作为首版候选，不把浏览器视频自动当歌词源。自动模式优先稳定的当前音乐会话；两个播放器都在播时，以用户明确选择优先，再用当前系统音乐源和最近可信开始事件决策，短暂元数据变化不抖动切换。固定模式可查看指定音乐源，但不因此获得全局MediaRemote定向控制权。

命令包含来源bundle/PID/启动身份、track generation、预期状态和能力版本。发送前重读身份与能力；AppleEvents按定向实例发送；MediaRemote必须确认选中源仍为系统当前源。发送后读回实际结果；exit0不当成功。不确定是否执行的next/previous不自动重试，防止双跳。非原子全局通路仍有竞态，实测报告写“观察到0次误控”，不能宣称数学意义绝不误控。

兼容桥异常时，Apple/Spotify定向主线继续可用；QQ/网易显示明确连接状态并返回原播放器，不改用无声失败的假按钮。AX菜单定向控制保留为必要时的后续备选，首版默认无AX权限。

## 7. 歌词来源、版本匹配和内容授权

请求顺序定为：**用户绑定文件 → 已确认本地缓存 → 启用来源的精确平台ID → LRCLIB精确get → 一次受限search → 用户选版本/导入。** 有词级数据不优先于正确录音身份。整体最多两条独立来源并发，各provider自身串行，切歌取消旧generation。

匹配同时保留标题、主艺人、专辑、时长、版本标志、平台ID和可取得的ISRC。不能剥光括号而把live/remix/伴奏/重录/变速版当同歌。metadata回退下，时长差≤2秒为优先自动接受范围；2–5秒需更多一致证据或人工选择；>5秒不自动接受。这是产品阈值，须用真实样本校准，不是概率准确率。

LRCLIB本轮真实请求HTTP200，响应含`hasWordSync`和`lyricsfile`，不再只有传统LRC；保留稳定`syncedLyrics/plainLyrics`回退。Lyricsfile 1.0仍draft，按版本严格读取；未知offset语义不猜；缺end只显示已知词起点，不生成假持续时间。客户端用可识别User-Agent，可注册公开App ID提升配额，secret API key不得放入Mac客户端，429尊重Retry-After。[LRCLIB当前文档](https://lrclib.net/docs.txt) · [Lyricsfile规范](https://github.com/tranxuanthang/lyricsfile/blob/348cd04b9d002fac8f5f67694064605026f9d030/SPECIFICATION.md)

本地导入先完整支持LRC/LRCX、Enhanced LRC、受限TTML、纯文本；已解密QRC/YRC与Lyricsfile reader并行实现并按解析验收开关。没有权限或时间时不靠抓缓存、解密平台密文、录音OCR来补齐产品承诺。

### 授权必须分成三层

**代码许可证、接口准入、歌词内容权利不是同一件事。** MPL的文件级义务可以隔离履行；GPL/AGPL允许商业发行但会带来组合程序相应源码义务，当前保留Nearpane许可证自由度的主线不直接采用。AMLL数据库根CC0并不覆盖所有外来歌词；README明确外来数据遵循原提供方协议。LRCLIB开放API也不能自动替用户证明所有歌词商业展示权利。[Mozilla MPL FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/) · [AMLL数据库条款](https://github.com/amll-dev/amll-ttml-db#共享协议)

实际执行方式是每个provider单独保存访问依据、内容依据、缓存/归属要求、适用地区与可发布状态；客户端按需取词、有限本地缓存，不镜像整库或建立中央歌词转售服务。工程继续完成所有层；发布前核对网络源允许的展示范围，必要时同接口换入有明确授权的服务，不重写产品。

**本轮不能替权利方授予许可，也没有证据把社区数据写成“完整授权曲库”。** 这是尚需外部事实解决的发行问题，和已经裁决的工程路线分开。只含本地导入的版本可以作为独立工具，但不能冒充已经满足本任务的完整自动找词首版。

## 8. 可直接实施的软件架构

| 模块 | 职责 | 明确不依赖 |
|---|---|---|
| LyricCore | RecordingIdentity、Selection、快照、能力、歌词文档/lanes/tokens、时间投影纯规则 | NSWindow、具体音乐App、HTTP |
| LyricPlayback | AppleEvents adapters、MediaRemote bridge、snapshot reducer、source仲裁、命令读回 | 歌词渲染、产品设置页面 |
| LyricServices | Provider、格式parser、版本匹配、缓存/用户绑定、来源记录 | 桌面坐标、NSPanel |
| LyricUI | 原生歌词布局、字形遮罩、常态/hover/菜单、状态与读屏 | 直接启动helper、直接发送音乐控制 |
| LyricTileApp | App生命周期、菜单栏、Settings、独立窗口、会话组合与更新 | Nearpane窗口管理引擎 |
| TileGeometry/Window/Coordination | 几何、非激活壳、进程占位/拥有者契约 | 音乐/歌词/语音/截图业务 |
| NearpaneLyricsModule（以后） | 注入会话、Host size/theme、嵌入LyricView、独立版交接 | 独立NSPanel嵌套/进程截图 |

`contracts/LyricDomainContracts.swift` 是Swift6类型与协议蓝图，不是已编译的App。`player-capabilities.schema.json`定义支持资格、当前可用性、控制路由与前置条件。`lyric-model-contract.json`保留格式/时间/来源语义，`design-tokens.json`固定设计数字。

### 关键运行规则

1. **会话与版本。** 每个播放器实例有启动身份；选中源更换/录音变化才递增track generation。seek只重置anchor sequence，不重新搜歌词。metadata晚到先核对同一provisional recording，不把补全字段错误地当切歌。歌词/封面/网络结果提交前核对generation。
2. **状态归约。** adapter NDJSON `diff=false`完整替换，`diff=true`按key合并，null删除字段。重启必须等新完整快照；不能把旧position、旧封面或旧supportedCommands留到新源。
3. **时钟。** 保留上游timestamp精度，以接收时配对wall/monotonic校准，运行时只用单调钟。`media = anchorPosition + rate × (nowMono − anchorMono)`，暂停冻结；唤醒/跳转/异常重锚。平稳播放没有stream事件不等于失联，低频实际health读取负责确认；失准/源不供position转静态，不从0计时。
4. **偏移。** `lookupMS=mediaMS+sourceAdvanceMS+userAdvanceMS`；正值表示歌词提前。原始LRC/TTML规则由parser归一，不把Lyricsfile未定义offset套进来。展示ease不改变真实媒体时间。
5. **帧与布局分离。** 内容、字号、宽度变更才重新CoreText布局；活动token mask可随屏幕帧更新。网络、AppleEvents和完整SwiftUI树不能每帧运行。逐行按下一边界调度；暂停/隐藏不跑帧。
6. **命令。** UI传意图给会话actor，控制路由与校验集中处理。拖动slider显示独立目标预览，读回确认后提交真实歌词位置；失败回真实进度并轻提示。play/pause优先明确期望状态，不能用盲toggle重试恢复。
7. **helper边界。** 固定源码构建并捆绑framework/脚本；stream `--micros --no-artwork`，封面另按需读取；有界NDJSON、并发读stdout/stderr、超时与指数退避，退出杀子进程。不能要求消费者安装Homebrew或下载运行代码。
8. **缓存。** 本地SQLite索引+按hash存歌词/封面；总磁盘目标≤200MiB，用户绑定文件单独保护。正文hash/parser版本/provider/recording组成键。404短期负缓存，429/网络错误不永久记“无歌词”。封面到达只更新同一recording，不用标题猜替代封面。
9. **格式安全。** XML禁DTD/外部实体/网络；解压后歌词≤2MiB、层级≤32、cue≤10,000、token≤100,000。YAML拒绝重复key、自定义tag与无界alias。未知时制返回可恢复错误，真实end和展示hold边界分离。
10. **线程。** MainActor只处理UI。AppleEvents在串行受控适配边界执行并限制超时，非Sendable桥对象不跨actor随意传；解析/解码/缓存I/O在后台。记录错误类型，不把所有失败吞成“没歌词”。

## 9. TileKit与Nearpane后续集成

v1协议在 `docs/TILEKIT_PROTOCOL.md`，只有几何、窗壳、登记三个小模块。共享用户目录的固定inode锁保护小JSON，原子rename提交计划；系统通知只做提示，事实来自持久计划。不需要常驻daemon或网络服务。

必须承认多进程没有“同时setFrame”原语。仅用同一个generation仍可能在换槽时相撞。明确重排时先撤下冲突窗，确认旧占位消失后再显示新位置；正常hover、暂停、切歌不触发重排。失联TTL不能证明窗口消失，卡住的旧面板仍占位。只有有变化的组件参与，日常不闪烁整列。

Nearpane承载的顺序：把LyricCore/Playback/Services/UI作为源码或SwiftPM固定域加入→Host传入size/theme/storage并构建但不显示LyricView→旧owner停止控制、撤下独立窗口并释放歌词会话锁→Host获取唯一会话拥有权并从真实播放器重读→显示Host内LyricView。退出Host再交还。进程锁保证一个活跃owner派发新命令，但不能撤销已经发到外部播放器的旧命令。

独立版先完整发布；Saytile和Riftlet分别接入占位登记，再宣传三App自动排列。Nearpane支持整列时作为固定Host占位，不让内部每个模块再次创建独立窗。对旧版保持可拖动的独立模式，不能靠AX遥控旧产品冒充协作。

## 10. 首个正式版本范围与验收

首发认证组合为 **macOS27 + Apple Silicon**，主验收机使用实际可用的Apple Silicon Mac并记录型号；不预先承诺旧系统、Intel和所有播放器历史版本。未来覆盖旧系统可以复用标准材质回退，不把它变成当前阻塞项。

首版包含：四播放器适配；可靠来源选择；同步歌词/真实逐字；完整状态；悬停播控；真实seek及返回；版本修正/单曲偏移；本地LRC/TTML；缓存；明暗/降低透明度/减少动态/VoiceOver；多屏位置；轻Tile协议；Developer ID签名、公证和更新。逐字是逐歌曲+逐时钟的能力，不是每个平台/每首歌必有。

首版不包含：歌词编辑器、AI翻译、推荐、社区、账号、歌单管理、音频播放引擎、频谱、桌面全部歌词样式、Touch Bar/灵动岛多形态、浏览器扩展、iCloud听歌历史、私有缓存收集。明确去掉这些有助于保持产品完成度，不代表它们技术上都不可做。

### 可量化目标（待测）

| 类别 | 发布要求/设计目标 |
|---|---|
| 真实样本 | 合计120条真实播放会话，四平台各30；含版本混淆、多语言、缺词、控制与故障 |
| 正确性 | 已接受歌词不混录音；切歌不显示旧词；任何真实误控阻止受影响控制路径发布 |
| 时钟 | 逐字资格目标P95≤250ms，逐行≤750ms；独立参考不足写unknown，不以自身读数证明自身准确 |
| 静止CPU | 主App+所有helper，10min均值<0.3%单核 |
| 逐行CPU | 10min均值<1%单核 |
| 逐字CPU | 10min均值<3%单核；短时切歌/hover峰值单列 |
| 内存 | 同工况总RSS median<120MiB，1Hz采样peak<180MiB；这是目标，不是测量结果 |
| 长期运行 | 一次8小时含暂停与唤醒，检查内存/句柄/helper/网络/日志增长 |
| 视觉 | 实机176/184/208/224宽、浅深/明暗复杂壁纸、多语言和长句，无文字裁切/焦点窃取 |
| 组合（分里程碑） | 三App六种启动顺序、重排/崩溃/唤醒/双屏是协作排列功能的发布门槛；Host交接是Nearpane集成的门槛。均验证无可观察重叠与双控制，不阻塞独立歌词板首发 |
| 发行 | 最终签名公证安装包复核，实际官网下载包与验收SHA一致 |

详细方法在 `docs/MACOS27_ACCEPTANCE.md`。外部播放器暂不提供的能力应在能力表如实降级；不可用seek显示只读进度、未知时间显示不供进度/重连，不画可操作假控件。QQ/网易可以凭明确的逐行和当前源控制子集取得正式支持，不能统称与Apple/Spotify完全等价。

采用官网分发：Developer ID + Hardened Runtime +公证。MediaRemote是私有API，所以当前不以Mac App Store为目标；私有API不等于必定无法macOS公证，苹果明确公证不同于App Review。不得要求关闭SIP或修改系统签名来实现基础功能。[App Review 2.5.1](https://developer.apple.com/app-store/review/guidelines/#software-requirements) · [macOS公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## 11. 已经确认与仍必须验证的边界

| 证据等级 | 本轮实际完成/未完成 |
|---|---|
| 已验证：研究环境 | 固定仓库HEAD/license/source读取；发现具体算法/解析/路由问题；LRCLIB一次HTTP200字段探测；高保真HTML实际渲染与交互/布局检查；JSON结构检查 |
| 源码支持 | Apple/Spotify脚本接口、MediaRemote helper、逐字数据解析、播放同步、原生嵌入边界、多产品当前窗口机制 |
| 待macOS27实机 | Swift完整编译、TCC、最终签名helper运行、播放器真实时钟/控制、WindowServer显示/焦点/跨屏、原生材料与字体、性能和8小时稳定性 |
| 待外部权利事实 | 网络歌词来源对目标发行模式/地域/缓存的具体授权范围；不能靠开源许可证推导 |

没有把普通工程难题继续留作“研究待定”。后续Codex应按给定接口、尺寸、状态、路线与验收实施。只有实机证据推翻这些前提，才写简短ADR调整相应局部，不重新开一轮无边界路线研究。

## 12. 交接阅读顺序

1. 本报告：锁定产品与技术裁决。
2. `design/LyricTile-Design.html` + `docs/DESIGN_SPEC.md`：外观/状态/动作的唯一主线。
3. `contracts/`：来源锁、设计tokens、领域类型、provider/媒体能力契约。
4. `docs/TILEKIT_PROTOCOL.md` 与 `docs/MACOS27_ACCEPTANCE.md`：协作和真实发布资格。
5. `docs/CODEX_BUILD_INSTRUCTIONS.md`：完整可执行指令。
6. `research/*/*AUDIT.md`：按当前模块需要查固定源码证据，避免一次把整个第三方仓库装进上下文。

若文档冲突，产品与视觉以本报告和DESIGN_SPEC为准；媒体资格以MACOS27_ACCEPTANCE为准；跨进程互斥/占位以TILEKIT_PROTOCOL为准；研究附录中的早期建议不覆盖本轮最终裁决。可调参数须记录原因，不能通过删失败项或伪造演示让结果看起来通过。
