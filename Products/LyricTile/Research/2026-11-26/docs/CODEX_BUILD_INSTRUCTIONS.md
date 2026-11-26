# HOLDSNOW — LyricTile 1.0 原生开发、实机验证与发行指令

把本文件与完整交接包一起交给有用户本机macOS权限的Codex。以下是后续实施任务；本研究会话没有据此创建仓库、修改其他产品或发布应用。

## 任务与已有裁决

你是LyricTile的实施负责人。产品设计、技术主线和接口边界已经研究完成，你需要把它实现成可独立下载、长期使用的原生macOS软件，并完成真实播放器验收、签名公证、打包和符合资格的正式发布。不要再返回一份开发计划，不要要求用户做普通测试员，不要把能由你完成的源码、工程、测试、截图、文档工作交还用户。

LyricTile是HOLDSNOW的桌面歌词与音乐控制板，未来由Nearpane直接承载；它不播放音频、不做推荐/社区/歌单管理。首发目标macOS27、Apple Silicon，主验收机为用户M5。必须实施Apple Music、Spotify、QQ音乐、网易云音乐四条适配，按实测能力准确公布正式支持范围。

最终视觉只有 **雾白词页**。独立面板宽`clamp(176,224,4*round(visibleFrame.width/32))` pt，高272pt，圆角22pt，桌面边距16pt、列间距10pt。常态以歌词为主体；鼠标进入只显内部封面/曲名/播控/真实进度/返回播放器，外框与当前歌词不动。采用原生标准雾面阅读层与有限原生玻璃控制层。禁止擅自改成大封面播放器、卡拉OK描边字、灵动岛、频谱或多种主题体系。

## 0. 先接收交接包，控制上下文

先读：

1. `README_START_HERE.md`
2. `docs/LyricTile-Decision.md`
3. `docs/DESIGN_SPEC.md`，并实际打开`design/LyricTile-Design.html`或高保真PDF看稿
4. `contracts/README-LyricDomain.md`、`LyricDomainContracts.swift`、`design-tokens.json`、`player-capabilities.schema.json`
5. `docs/MACOS27_ACCEPTANCE.md`与`docs/TILEKIT_PROTOCOL.md`

按正在实现的模块再读`research/media/MEDIA_AUDIT.md`、`research/lyrics/LYRICS_AUDIT.md`或`research/ecosystem/ECOSYSTEM-AUDIT.md`。不要一次塞进所有第三方仓库、全文日志、原图base64或120条验收轨迹。先固定当前HEAD，后续只读相关文件与diff。每完成一个阶段，将commit、决定、证据、失败原因和下一动作写入`docs/IMPLEMENTATION_STATE.md`；上下文不够时从该文件恢复，不重做已完成工作。

允许你并行分工：媒体适配、歌词/parser/matching、原生UI、共享组件/发行验证。不同任务只改自己模块；合并前统一类型与签名。保留至少一段上下文用于真正集成、验证和交付，不能用研究耗尽整轮。

确认是否已有用户的LyricTile仓库和本地工作目录；有则沿用并保护现有修改，没有则建立隔离工程目录和私有LyricTile仓库准备实施，遵循本会话已有权限。不要覆盖其他项目工作树，不对Nearpane的Stage Manager后端作改动。研究源版本以`contracts/source-lock.json`为起点，若上游已经更新，检查差异再决定是否升级，不盲目追main。

## 1. 建立可编译原生骨架与真实媒体纵切片

建最小SwiftPM/原生App工程，目标分为LyricCore、LyricPlayback、LyricServices、LyricUI、LyricTileApp；TileKit用独立小包/targets。先typecheck提供的Swift6契约，它只是接口蓝图，尚未在研究Linux环境编译：

```sh
swiftc -swift-version 6 -strict-concurrency=complete -typecheck contracts/LyricDomainContracts.swift
```

必要时修正语言/并发细节，保持其语义；不能把不能编译的契约直接当成已验证SDK。LyricCore只依赖Foundation，不引用NSWindow、HTTP或具体播放器。UI只接受渲染状态和动作协议，不能直接发AppleEvents。

先做开发者可读的真实媒体探针并落盘：四播放器实际bundleID/version/build、进程启动身份、currentTrack、duration/position单位、playerState、artwork、支持命令。记录macOS实际build、SIP、Xcode/SDK、硬件与代码签名上下文。读取本机sdef和实际值，不信旧桥接头的duration注释。

Apple Music、Spotify：以实例/PID定向ScriptingBridge或明确AppleEvents为主，系统播放通知触发刷新，低频实际位置读取作校准。不要调用原生macOS未提供的MusicKit SystemMusicPlayer，不把hasLyrics当全文接口。避免探测时启动未运行播放器。TCC的拒绝/超时独立处理，系统许可只在首次实际连接时触发。

QQ音乐、网易云：固定BSD-3-Clause `ungive/mediaremote-adapter`，自行构建、捆绑framework/脚本、记录hash。主线不套完整media-control CLI；CLI可辅助调试。使用`stream/get --micros`，stream尽量`--no-artwork`，图像另按需获取。正确处理full snapshot、diff与null删除；重启等新完整快照。helper stdout/stderr并发消费，设置大小、超时、重启退避，退出无残留。

**这阶段必须见到真实播放器数据。** 单元测试fake、adapter test发布的假NowPlaying、静态样例都不得充当真实接入。视觉样句只能存在于明确标注的Preview/Test target，不进入Release runtime的默认状态。

## 2. 实现来源仲裁、时钟与命令结果

播放器模型分清：实例session、recording identity、track generation、anchor sequence、runtime capabilities、source clock quality。属性晚到不一定是切歌；seek不应重新找词。歌词和封面异步结果提交前必须核对generation。

时钟以真实锚点+单调时间投影，不逐帧累加dt。`--micros`仅保留数据精度，不能宣称上游微秒准确。暂停冻结，唤醒/切歌/seek重锚，稳态stream无事件不应误判为断线；通过低频真实health读取确认。对确实不供进度的播放器显示“不提供进度”，对临时失败显示“重新连接”。失去可信时钟不从0开始计时，也不无限继续扫字。

多播放器：四个目标App组成候选，浏览器视频不自动变成歌词源。明确用户固定源优先；自动模式只根据可信播放事件和当前音乐会话切换，不因短缺字段反复跳。固定查看QQ/网易不等于具有后台定向控制能力。

所有控制入口统一实现：

1. 保存操作意图、预期目标和generation；核对发布资格与当前能力。
2. AppleEvents发给所选实例；MediaRemote全局动作发前再次确认系统当前源正是面板源。
3. 不支持/身份不一致/能力unknown时不发全局动作，保留返回播放器。不能使用`--force`强行绕过能力。
4. 发后读取真实播放器状态核验。helper exit0、系统PID回调、UI图标变化都不算执行成功。
5. seek在拖动时显示独立预览，读回确认后定位实际歌词；失败回到真实位置。adapter seek单位是微秒，media-control单位是秒，用类型化时间避免换错。
6. 不确定执行结果的next/previous不自动重发；禁止为“修漂移”调用play。QQ暂停seek若会自动开播，必须实测处理策略；未证明策略前禁用暂停中seek。

禁止临时修改全局NowPlaying override来冒充定向控制。上游已撤回该路线。不要把读取`get --bundle-id`和定向发送混为一谈。若需要AX菜单作为QQ/网易失焦控制备选，单独实现并按需请求权限，未经验证不启用；首版默认通路无需AX。

## 3. 完成歌词服务、匹配、格式与缓存

请求顺序：用户绑定文件→确认缓存→启用来源的精确平台ID→LRCLIB get→一次受限search→用户选择。整体最多两个独立源并发，每源串行；切歌取消旧任务。用户在QQ播放不要求一定从QQ私有接口取词。

实际对接LRCLIB当前docs.txt：有效User-Agent；可选公开Lrclib-App-Id，secret key不能放客户端；遵守Retry-After和限流；没有歌词/网络错误/限流/解析失败分开。读取当前`hasWordSync/lyricsfile`，严格版本，失败退syncedLyrics，再退plainLyrics。不要沿用“无rate limit”“只有逐行”旧结论。

歌曲匹配先拒版本冲突：艺人、核心标题、专辑、时长、live/remix/伴奏/重录/变速标签；ID和ISRC也不是无条件覆盖所有冲突。metadata回退时≤2秒时长差优先自动接受；2–5需额外一致证据；>5不自动接受。可按实测校准阈值并记录，不把评分叫作正确率。不要复用LyricsKit旧durationQuality公式。

LRC/LRCX核心可隔离fork LyricsKit并履行MPL对应源文件义务；不带其旧网络provider/评分器。TTML用Swift XMLParser按指定profile实现，优先移植MIT ttml-processor-rs语义并保留版权；不直接拷AGPL JS、不用find字符串拆XML。真实cue/token start/end、显示hold边界、多语言/和声lane、UTF16/grapheme映射分别保存。

首轮做完LRC、多标签LRC、Enhanced LRC、TTML Apple/AMLL profile与纯文本；然后补已解密QRC/YRC、Lyricsfile严格reader。没有词尾时间可以保留“未知”，不能均分行长创造词时码。TTML禁DTD/外部实体/网络；YAML拒重复键/custom tag/不受控alias；按交接限额保护文件导入。未知时制不转0。

Cache保存provider/recording/document hash/parser version/来源权利状态，封面也按同一身份归属。404负缓存与临时错误分开；磁盘目标总≤200MiB，用户绑定文件不被LRU删除。匹配正确优先于逐字、翻译和封面丰富度。

## 4. 精确实现原生视觉与交互

先按高保真稿实现一个能真实工作的原生窗口，随后覆盖所有状态。禁止把HTML原型放进WKWebView当成最终产品；不要把设计样句留在正常runtime里作为失败回退。

- 窗口使用非激活NSPanel；浮动层级合理，不用Riftlet捕获专用高层。透明外部区域不能拦截整屏鼠标。hover不抢焦点；用户编辑/菜单/读屏进入才按需建立key。
- 歌词CoreText排版缓存，活动词mask更新；不能每帧重排整个SwiftUI树。中文/英文/日文/韩文/RTL、组合字符、emoji、连字、三行长句按真实glyph runs处理。
- 状态包括播放、暂停、真实间奏、行尾未知等下一句、纯音乐、搜索中、未找到、纯文本、临时时钟断连、源不提供进度、未播放、播放器退出、授权拒绝。具体文案按DESIGN_SPEC，不将这些折叠成同一个spinner。
- 常态当前词句为主。hover140ms后显封面/曲名菜单/前后曲/暂停/真实进度/返回；同272pt外框内变化。离开280ms后淡出，drag/menu/focus中保持。
- 纯文本不自动切句；行时码+健康clock才逐行；词时码+健康且通过精度资格的clock才逐字。能力按每一首歌动态判定。
- 正常曲名菜单能选版本、调时间、导入、看来源。校准以提前/延后文字显示，正advance=提前，lookup=media+sourceAdvance+userAdvance；偏移绑定录音+文档hash。
- 进度只有seek确实支持时可拖；缺能力只读；状态临时不明时禁用，不造时长或进度。
- 浅深、Reduce Transparency、Reduce Motion、Increase Contrast和VoiceOver都必须实际检查；正文最终对比≥4.5。不为了取壁纸申请屏幕录制。
- 一页欢迎+按需Automation说明；主按钮“开始使用”；极简设置无帐号和快捷键学习要求。产品页面不写技术栈/验收门槛/调试说明。

图标按SVG几何与材质概念用Icon Composer/Xcode完成Light/Dark/tinted资源，检查24/32/64尺寸。不要直接把生成PNG毛边带进发行图标。应用英文LyricTile；母品牌HOLDSNOW；不擅自更名。

## 5. 轻TileKit及Nearpane集成准备

按TILEKIT_PROTOCOL实现三个小模块，不开发daemon、云同步、插件平台或通用窗口管理系统。共享小JSON+固定inode flock+原子rename；通知只作提示。hover、切歌、暂停不修改外部占位。

不要假设原子generation等于同时移动：明确重排采用先撤冲突旧窗再呈现新窗；失联TTL不释放仍可见占位。多屏按UUID保存，拔插/缩放/睡眠后重建逻辑坐标；不硬编码主屏或4K像素。正常不可见状态保留位置偏好，不频繁让整列上蹿。

独立LyricTile不等待另三款软件迁移。完成公共包和最小接入说明；在适当分支为Saytile/Riftlet添加占位适配，不改ASR与截图核心。只有兼容版本组合实际通过后才宣传“自动排列”。旧版保留用户拖动避让，不能靠AX搬动旧软件伪装协议已完成。

提供NearpaneLyricsModule最小集成验证：在Host内直接使用LyricCore/Playback/Services/UI，服从Host宽度/主题；没有独立NSPanel嵌入技巧。用生命周期服务锁协调唯一会话owner，接管先停止旧命令/撤旧UI、放锁、新owner读真实快照再显示。不能同时显示两块词页或派发两次控制。

## 6. 真实验收与优化

严格执行MACOS27_ACCEPTANCE，120条真实会话为全项目总量，四平台各30；其中至少30条版本混淆/对照，覆盖中英日韩、缺词、纯音乐、长句、多个播放器、浏览器抢媒体、暂停seek、冷启动、唤醒、断网、断屏。自己的合法测试音轨可以校准时钟，但合成helper数据不算真实播放器支持。

所有结论必须有系统build、播放器版本、commit、最终包hash、source trace与实际结果。时钟精度要说明独立参考与误差；参考不足写unknown，不填0。仅未达逐字资格、但时钟仍健康、具有真实行时码且P95≤750ms时退逐行；参考不足、stale、无进度或未达逐行资格时转静态歌词与对应状态，不删日志“通过”。

CPU主App+所有helper合计，单核100%定义，10min窗口：静止<0.3%、逐行<1%、逐字<3%目标；总RSS median<120MiB、采样peak<180MiB目标。做一次8h持续运行含暂停和唤醒。优化针对实际热点，不靠暂停音乐、减样本、少计helper或关核心功能隐藏超标。

自动测试聚焦真实风险：generation晚到、命令路由、diff/null、单位、parser边界、真实/显示时间分离、bidi/换行遮罩、两阶段布局、owner交接。不要堆只验证实现镜像的测试数量。达到相关证据后停止无关扩测，把时间用于集成和发行。

可观测误控、错版本/旧词污染、虚假进度、破坏系统媒体全局状态属于受影响通路的发布阻断。QQ/网易单项失焦seek失败不等于整个播放器必须放弃；准确声明通过的逐行/当前源控制子集，其他入口按能力处理。

## 7. 许可、签名、公证、更新与发布

准备THIRD_PARTY_NOTICES和固定source lock；MPL文件及修改提供对应源链接；BSD/MIT保留版权许可。不得直接复制或翻译GPL Lyrimuse/AGPL AMLL进与现有Nearpane不兼容的组合。若决定采用整体GPL/AGPL路线，需要新的明确产品许可决策，不能自行假设改语言就免责。

为每个网络歌词provider填独立发布资格：代码、API准入、内容权利、地域、缓存、归属。LRCLIB注册信息和授权文档可准备并核对，开放API不能当整库词曲商业授权。API实现、界面和本地导入继续完成；某源权利不足只影响该源的默认启用/发行声明，可在同协议接入有许可的来源。不要把只能本地导入的包宣称为已经完成自动找词任务。对外授权询问先形成具体可发送草稿，不未经授权代发、付费或接受合同。

选官网分发，Developer ID+Hardened Runtime，签所有嵌套代码，公证并staple，验证Gatekeeper和新安装TCC。不要要求关闭SIP、安装Homebrew、修改系统Perl或添加Apple私有entitlement。macOS公证不同于Mac App Store审核；不因私有接口一句话断言无法公证，也不因此承诺Mac App Store可上架。

采用成熟Sparkle更新机制或生态已验证的正式更新模式，固定依赖与feed签名；版本号1.0.0，build单调递增。最终公开包必须是验收过的包。生成DMG、SHA256、签名/公证证据、能力表、简洁版本说明与下载页。正式支持只列通过组合，不写“所有歌曲/所有播放器版本/完美同步”。

当执行会话已明确授权正式发布，完成这些条件后直接发布；没有相应外部发布权限时，先完成可审阅的候选、下载文件和发布草稿，再就唯一必要动作说明阻塞。不能在尚未把普通工程做完时提前把“请批准发布”当作停工点。

## 8. 最终交付格式

交付真实结果，不只报“测试通过”：

- 产品版本/build/commit、DMG下载、SHA256、签名公证结果、实际下载安装路径。
- 四平台逐能力表：metadata、position精度、歌词层级、封面、play/pause、前后曲、seek、返回、权限恢复；列系统/播放器版本和限制。
- 高保真稿与实际macOS界面对照，常态/hover/暂停/缺词/多语言/深色/同列真实截图。
- 120条样本总览、观察到的误控/错版本数、性能实数、8h稳定性结果，区分PASS/FAIL/NOT_RUN。
- TileKit独立运行、兼容版本排列和Nearpane直接嵌入分别是否完成，不用一个“集成完成”概括。
- 仅剩的真实外部阻塞及其最小处理方式；不给用户大串测试任务。

若实机证据推翻研究前提，写短ADR：哪条假设被什么证据推翻、替代方案、对设计/功能的实际影响，再继续实施。不要重复没有新信息的试验，不把普通编码困难上升成整条路线无限研究。
