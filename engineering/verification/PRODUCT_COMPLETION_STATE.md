# Nearpane 产品完成状态（持续维护入口）

从本文件和当前分支 HEAD 接手。权威顺序：[产品定义](../../PRODUCT_DEFINITION.md)、[ADR-010](../../decisions/ADR-010-DUAL-WORKSPACE-MODES.md)、[011](../../decisions/ADR-011-MULTI-DISPLAY-PRESENTATION.md)、[012](../../decisions/ADR-012-DESKTOP-WORK-AREA-AND-FULLSCREEN.md)、[013](../../decisions/ADR-013-STABLE-WORKRECT-AND-EIGHT-WINDOW-TILING.md)、[视觉权威](../../design/NEARPANE-VISUAL-AUTHORITY.md)。固定分支 `implementation/host-foundation-20261109`；总任务开始于 `b2af573876aa120a1db003d9b82542daee6409e4`。个人资料、主屏工作窗口不作为验收对象。

**读法：** IMPLEMENTED＝有可运行实现，尚缺相应现场证据；VERIFIED＝仅在写明的环境实际通过；PARTIAL＝同一能力中仍缺部分路径；BLOCKED＝前置未满足；NOT_IMPLEMENTED＝没有产品实现。算法、隔离系统实测、真人环境是三种证据；后两者不互相替代。

**当前可打开的版本**　[Nearpane P5.7 Alpha](</Users/hhf/Applications/Nearpane P5.7/Nearpane P5.7 Alpha.app>)。回退时正常退出当前版本，再打开 [P5.6 Alpha](</Users/hhf/Applications/Nearpane P5.6/Nearpane P5.6 Alpha.app>)。两个版本沿用稳定资料身份，普通用户窗口自动接管默认关闭。

## 副屏实机接续 · 2026-11-13 23:27

两次只读核对确认副屏仍只有普通桌面 4568，原焦点归属主屏 1309。已修复验收器对副屏原窗口误用主屏边界的问题，完成无界面回归和签封。普通桌面往返仍为 0/3，空间行和跨空间移窗保持关闭。[现场记录与单次启动入口](NATIVE-SECONDARY-WINDOWMANAGER-RESULT.md#2322-只读复核及归还窗口的显示器边界)

## 副屏选中当前桌面后的焦点与恢复 · 2026-11-13 15:21

真实按压副屏当前桌面 A 的系统控件后，调度中心关闭，前台转到登记范围外。监督器在创建 B 前停止。稍后的两次只读采样确认原窗口已取回焦点，两屏原桌面均在，测试窗零残留。普通桌面往返 **0/3**，跨空间移窗 **0 次**。验收工具现已增加系统级 AX 焦点核对，并将已见证的越界设为该轮的终止条件。产品仍为 P5.7，空间行切换及跨空间拖放关闭。[现场经过、修复与验证](NATIVE-SECONDARY-WINDOWMANAGER-RESULT.md#1519-实际选中副屏当前桌面-a)

## 已验证原焦点归属后的副屏验收 · 2026-11-13 14:24

已实测从主屏当前桌面 1309 的原窗口出发，在副屏 4568 创建测试窗口、取得键盘焦点并打开调度中心。关闭概览后，独立观察器确认原窗口仍在原桌面但未获焦点。系统输入在创建 B 前停止；桌面往返仍为 0/3，跨空间移窗为 0，零测试窗口残留。P5.7 的空间行切换、跨空间移窗继续关闭。[实机经过与最终双采样](NATIVE-SECONDARY-WINDOWMANAGER-RESULT.md#1423-从已确认的当前桌面出发)

## 副屏普通桌面与原焦点归属 · 2026-11-13 13:27

副屏唯一普通桌面为 4568。13:20 实际创建的专用窗口未取得键盘焦点，已在打开概览之前停止，退出后两次核对零残留。随后发现原焦点窗口属于主屏非当前桌面。验收程序已将原窗口与当前普通桌面的关联纳入动作前检查，修正版已完成一次真实只读验证。本轮创建桌面 0 次，普通桌面往返 0/3，跨空间移窗 0 次。当前 Alpha 仍为 P5.7，两个产品入口继续关闭。[现场收据、修复及本机一次性验收入口](NATIVE-SECONDARY-WINDOWMANAGER-RESULT.md#1320-副屏测试与焦点归属)

## 副屏添加桌面控件的身份已确认 · 2026-11-13 12:25

已在真实调度中心区分主副屏的两个添加按钮，并从副屏桌面栏独立验证所属关系。两次退出时，原 AX 窗口分别成功、未成功取得焦点。末次两次独立采样确认两个测试窗零残留、指针归位、主屏 1309 与副屏 4568 均保持原位。没有创建 B，普通桌面往返为 0/3，跨空间移窗为 0。下一次有现成副屏空白 B 时可直接走相邻目标入口。当前可打开的产品仍为 P5.7。[两次现场记录及回归](NATIVE-SECONDARY-WINDOWMANAGER-RESULT.md#12181225-重连副屏实测)

## 双屏重连后的验收准备 · 2026-11-13 11:30

两次独立读取确认主屏为 1920 × 1080 pt，当前桌面 1309；旋转副屏为 800 × 1280 pt，当前且唯一的普通桌面为 4568。上次登记的原窗口在 11:21 两次读回时均已取得焦点，测试窗口零残留。重新取得焦点的时间及原因未知。此次只读重查没有执行桌面切换。签封的双屏验收工具已绑定副屏 4568，保留主屏 current、来源和归还检查。[双屏准备与实测边界](NATIVE-CURRENT-DISPLAY-RESULT.md#双屏重连)

## 当前屏幕实测 · 2026-11-13 09:47

在单显示器的桌面 1309，从登记的合成窗口实际打开并关闭系统调度中心。预演能归还焦点，真实概览退出后焦点却在另一进程。09:47 的两次独立读回确认原窗口存在、鼠标归位、测试窗口零残留、桌面顺序未变。系统添加控件仍未获充分定位证明。没有创建 B，普通桌面往返 0/3，跨空间移窗 0 次。两个产品操作继续关闭。已编译改为后台打开概览的验收工具，真实归还效果待验。[现场收据和修复](NATIVE-CURRENT-DISPLAY-RESULT.md#0938-单显示器限时实测)

## 焦点归还与一次性验收入口 · 2026-11-13 09:32

已将调度中心退出和预演的窗口隐藏顺序统一，在创建 B 之前要求独立进程证明原焦点、指针和桌面均归还。单显示器准备了经签名验证的 Finder 单次启动入口和按精确 AX 身份派发的“添加桌面”路径。此次续查只有只读设备采样，累计普通桌面往返仍为 0/3、跨空间移窗为 0，两个产品操作仍关闭。[现场读回、回归和启动入口](NATIVE-CURRENT-DISPLAY-RESULT.md#0917-后的只读复核与修复)

## 当前显示器普通桌面验收 · 2026-11-13 09:05

当前只有一块 1470×956 的显示器。相邻的既有桌面 1130 未通过空白检查。已从 1309 的自建窗口打开系统调度中心，添加控件位于桌面栏外，实际建桌面 0 次、普通桌面往返 0/3、跨空间移窗 0 次。最终两次读回均确认当前桌面、原始顺序、指针和测试窗口清理。原前台进程没有恢复，精确键盘焦点未获证实；后续系统输入已停止。产品能力开关和已安装 P5.7 维持原状。[现场证据、修复与回归](NATIVE-CURRENT-DISPLAY-RESULT.md)

## 副屏普通桌面续验 · 2026-11-13 05:27

副屏两次读回均只有普通桌面 4297。05:20 从副屏合成窗口打开了调度中心并悬停桌面栏右缘，栏仍高 40 pt。系统未在栏内正向命中同一个“添加桌面”按钮，控制器退出。两扇实际创建的测试窗口均已关闭，外部观察器确认原窗口取回焦点。普通 A→B→A 完成 0/3，跨空间移窗 0 次，产品开关维持关闭。已提交副屏物理命中及首次切向 B 前的占用检查 `4c8c023`。[实机回执和未验条件](NATIVE-SECONDARY-WINDOWMANAGER-RESULT.md#第二次无人时段)

## 副屏添加桌面的系统控件 · 2026-11-13 04:56

WindowManager 确认了副屏桌面栏及添加按钮，但按钮的两种 AX 几何读法都落在副屏以外，实际添加输入为零。副屏仍只有普通桌面 4297，普通 A→B→A 为 0/3，跨空间移窗为零，两个产品入口仍关闭。04:56 的两次独立读回均确认主屏原桌面 1309 和原窗口焦点、概览已关闭、五扇合成窗口零残留。鼠标指针未回到原位置。下一次实测需要副屏已有可见证的相邻普通 B，或新的副屏添加控件定位证据。副屏原生全屏和语音工具浮层已有现场通过记录。[系统控件、恢复与验收收据](NATIVE-SECONDARY-WINDOWMANAGER-RESULT.md)

## 副屏调度中心与归还 · 2026-11-13 04:29

副屏自建窗取得焦点，指针在其中心完成双采样。04:28 调用系统调度中心后，主屏原窗口的几何核对失配，添加按钮前已停。副屏仍只有 4297，普通 A/B 为 0/3，跨空间移窗为 0。最后两次只读采样确认两屏原桌面、原前台进程代际及窗口号，五扇临时窗零残留。末次退出瞬间的 AX 焦点与原指针位置未获归还证明。空间行和跨空间拖放继续关闭。副屏全屏及工具浮层沿用其真实通过收据。[现场记录及证据](NATIVE-SECONDARY-OVERVIEW-RESULT.md)

## 副屏普通桌面 A · 2026-11-13 03:55

副屏自建窗口 188575 的 AX、CG 和两次 Space membership 均确认它只属于普通桌面 4297，已关闭且无残留。随后另一扇测试窗未能通过借焦点前的同一窗口检查，已在进入调度中心之前停止。B 未创建，普通 A→B→A 为 0/3，空间行和跨空间拖窗仍关闭。两屏 current 与指针保持原状，事后核实原前台进程，但第二扇测试窗的原 AX 焦点归还未获证明。[现场收据及准入条件](NATIVE-SECONDARY-DESKTOP-PROVISION.md)

## 副屏全屏工具浮层 · 2026-11-13 02:35

**VERIFIED（当前系统构建，隔离 Host，自建全屏窗口）**　普通面板在全屏中隐藏，用户动作对应的 AXPress 打开语音工具一次、收起一次，同一浮层的状态条、展开、收起均由外部 AX 读回。退出后普通面板恢复，原主屏窗口取回焦点和原位置；Host 正常排空。Voice 与 Tray 实例及空资料保持一致。本次只见证一个普通副屏桌面，A/B 切换及跨空间拖窗仍关闭。[系统及工具结果](NATIVE-FULLSCREEN-OVERLAY-RESULT.md)

## 副屏原生全屏实测 · 2026-11-13

在当前系统构建上，自建窗口已真实完成原生全屏 4297 → 4446 → 4297，主屏 current 保持 1309，退出后同一主屏原窗口的 AX 焦点及 frame 已核实，两扇测试窗零残留。隔离 Host 未完成工具浮层开合，AX 控件操作 0 次。副屏仍只有一个普通桌面。[现场时间线、失败与清理证据](NATIVE-FULLSCREEN-TIMED-SECONDARY.md)

## 副屏 Native Spaces 续验 · 2026-11-12

11 月 12 日现场的两次 P5.7 读取及最终冻结见证均发现副屏只有普通桌面 4297。A→B→A 完成 0/3，跨空间移动 0 次。最终只读检查已绑定主屏原焦点的可归还对象；在明确的无人时段内可先校准临时借焦点，再独立执行副屏全屏与真实 Host 浮层联验。截至该次预检尚无全屏进入、退出或浮层开合收据。实验工具和空资料 Alpha 已签封，个人 P5.7 安装及产品动作开关保持原状。[本轮现场收据、冻结包及接续入口](NATIVE-SPACES-SECONDARY-CONTINUATION.md)

## P5.7 原生空间和全屏

| 用户操作 | 当前状态 |
|---|---|
| 查看当前 Space | 已安装 Reader 在真机双屏读回成功。来源行要求独立的 active-Space 窗口、同屏唯一 membership 与稳定几何。普通窗口缺可比标题时可使用同号 AX/CG 作证，窗口号冲突会被拒绝。 |
| 点击空间行、跨空间拖窗 | 副屏只有一条可观测记录。三轮 A→B→A 完成 0 轮，移动 0 窗。两个产品入口均关闭。 |
| 全屏后的布局恢复 | 已修复来源过期和错误桌面可以放行布局写入的问题。保留原事务，在 Settings 显示等待原因。冻结见证包确认真实 AX 焦点在受保护主屏，本轮全屏进入/退出 0 次，真实浮层及返回待验。 |
| 安装与回退 | Debug、Release、305 项集成、243 项独立 Host 回归通过。两版已安装 Host 的隔离资料往返通过，源数据、五项媒体及 UNKNOWN 完整。 |

本轮功能、实机预检、设备限制和接续入口见[原生空间交付收据](P5.7-NATIVE-SPACES.md)。P5.6 的真实跨应用平铺仍以原现场收据为准。其余语音、截图附加、全屏工具呈现、发布及普通窗口兼容性范围沿用下表。

## P5.5 之后的实测增量

本轮从本地 `b90c3ca7341bf40c8fcf6356a86c9cebedc112ed` 开始。下表保留各阶段原始证据。

- **首次跨应用混合平铺。** 两款独立 AppKit 应用各有两扇窗口。逐窗选择文档窗和允许加入其他应用台前分组的工具窗，在副屏 640 × 1280 pt 的 WorkRect 中先得到 320 + 320 pt，再得到 384 + 256 pt。7 笔布局、3 笔恢复，18 个 AX 属性写入步骤。Owner、AX、CG 最大误差 0 pt，预演和暂停期间新增写入均为零。排除工具窗后只调整另一应用。四个窗口最终无残留，前台 PID 和 AX 焦点相同。此轮冻结 Host 为 `467f38c7301c9a97d7aba858780c8b90d0be43f4d4c51f4d77a0f36604035ea8`。验收范围代码 `2fbcae4`，设置页以已获准的应用身份标记管理对象 `d2565c3`。[实测与各阶段读回](../../build/verification/p54/ordinary/01af32e7-4d37-4ff0-8ce1-e866cdb6c6eb/mixed.json) · [事务](../../build/verification/p54/ordinary/01af32e7-4d37-4ff0-8ce1-e866cdb6c6eb/manager.json) · [退出](../../build/verification/p54/ordinary/01af32e7-4d37-4ff0-8ce1-e866cdb6c6eb/cleanup.json) · [工具窗口的 AppKit 行为](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications)
- **两个主文档应用的限制。** 第二个应用出现后，第一个应用的 AX 保持 240 × 152 pt，CG 显示 49 × 71 pt。此次预检停在首次写入之前。窗口同号只能证明身份，无法证明它当前以可写的普通几何显示；不切换台前调度分组。[现场负例](../../build/verification/p54/ordinary/897371f9-c70a-49ed-b180-1a67a96cfb00/geometry.json)
- **启动、全屏与输入法。** 从应用启动即登记锁屏和会话通知；资料打开期间的暂停条件在首次桌面读取之前生效。回归覆盖两个条件独立解除。另复现 AX 全屏标志与同号 AX/CG 小矩形同时出现时错误授予单窗全屏资格；现在要求已核对的窗口覆盖可用工作区域。候选文字正处于输入法标记时，尺寸预览刷新和辅助功能赋值均保留当前组合，确认后才提交。代码 `c0ca411`。[启动读数](../../build/verification/product-next/preview-and-startup.log) · [全屏反例原始失败](../../build/verification/product-next/fullscreen-before.log) · [修复后](../../build/verification/product-next/fullscreen-after.log) · [AppKit 输入法合成事件](../../build/verification/product-next/ime.log)

### Native Spaces 的执行检查点

macOS 27.0（26A428）两次独立只读采样均报告 `separateSpaces=true`；1920 × 1080 主屏有 3 条内部记录，800 × 1280、旋转 90° 的副屏只有 1 条。两次 current 稳定。此处的数字是 scope 记录数，用户桌面总数仍未知。对比 P1 当时的 `false`，当前结果也说明启动时必须重新读取设置。未读取任何个人窗口内容。[本次空窗口白名单读回](../../build/verification/native-route/scope-only.json)

已冻结的双窗口见证包在每次拟发键前独立复核两扇登记窗口、两屏 current、相邻方向、当前焦点和有效会话。明确区分专用图形会话与限时授权控制台。实际运行前者在日常登录被拒，后者因副屏缺第二个候选被拒。两条入口均在创建窗口前返回，输入 0，真实 A→B→A **0/3**。空间行切换、跨空间拖窗、创建、删除、Virtual 停放都保持关闭。公开快捷键可表达相邻方向，Apple 的窗口拖拽需要 Mission Control 的真实目标；当前均没有本机三次往返与跨空间 membership 终态。[可行路线、分发和返回条件](../../architecture/MACOS-SPACES-FEASIBILITY.md) · [冻结工具](../../build/verification/native-route/Nearpane-Space-Witness.zip) · [两次拒绝收据与可执行文件指纹](../../build/verification/native-route/final-preflight.json) · [Apple 的多空间操作说明](https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/mac)

若使用当前 Mac，需一个明确的无人使用时段，加上副屏上由所有者指定的一对相邻空白普通测试桌面和可靠回程。另一选择是已有、可控制且完全隔离的图形登录或测试机，并提供两个测试 Space。常用虚拟机应用的标准安装位置和命令入口未发现现成工具；未检查私人虚拟机目录，也没有创建账户、来宾系统或修改系统选项。[环境探查范围](../../build/verification/product-next/vm-availability.json) · [Apple 的 macOS 来宾方案](https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon)

### 语音、截图与草稿权限

设置分别呈现 TCC 与默认音频输入状态，显示期间共享一个 HAL 默认路由监听器，最后一个视图退出后注销。实机注册和注销均返回 0，默认输入可用；设备之间的切换通过合成变更事件验证。Riftlet 的截图目录丢失后保留原授权和队列，让用户重新核对同一个目录。目录名相同但 inode 或创建时间不同会拒绝。Chrome 不在运行、未安装、尚未询问、已拒绝和身份不明确都有对应反馈。迟到的权限回复不能重启用户刚关闭的附加；待重核状态可跨重启保留，P5.5 读取时保持关闭。原授权在隔离导入及回退后都没有继承，源树指纹不变。[实际 HAL 收据](../../build/verification/continuation-domains/hardware/listener/result.txt) · [权限与顺序回归](../../build/verification/continuation-domains/final-auth-and-routes.log) · [资料投影](../../build/verification/continuation-domains/profile-permission-projection.json)

### 安装包上的窗口布局和可及性

P5.6 第一份安装包的 Host 为 `a708574915fb44e5d9627ad56a55387de6b305aebe33d717fda29a640a70ac94`。实际从「设置」逐窗授权两个进程时，AX 的两个静态文字行分别显示 Standard documents、Standard palette，仅显示获准的应用与窗口编号。排除后相应行消失，未授权兄弟窗一直保持原位。验收脚本最初错误假设刷新后仍选中了两窗，实际界面清楚显示仅选一扇。保留该次拒绝与退出收据后，重新逐一选择并核对两扇窗口，完整 10 笔事务通过。[首次中止及现场](../../build/verification/p54/ordinary/074158e8-180b-4690-86aa-043666fb9d2f/) · [10 笔事务](../../build/verification/p54/ordinary/89c99e9f-0fe6-4b40-9a20-d23ee4c1be59/mixed.json) · [真实 Settings 名称](../../build/verification/p54/ordinary/89c99e9f-0fe6-4b40-9a20-d23ee4c1be59/mixed-half-owner-rows.json) · [退出清理](../../build/verification/p54/ordinary/89c99e9f-0fe6-4b40-9a20-d23ee4c1be59/cleanup.json)

副屏普通窗口预览现在为辅助功能提供逐窗、从前到后的相对位置和宽高。对标记的两扇合成窗读取实际 macOS AX 静态文字，在禁用及启用空间观察的两种状态均与独立几何换算一致。截图、语音文字和窗口标题没有进入描述。没有启用系统 VoiceOver 朗读。此次 Host 在副屏持续约 23.54 秒，24 次同一进程内核采样，CPU 0.204 秒、进程能量计数差约 0.254 J、物理内存 35.16–83.39 MiB。测量包含启动与窗口预览，长期驻留另见已有 180 秒内核观测及 P3.7 收据。[实际 AX 及几何](../../build/native-acceptance/237ec2e8-4ae7-4741-9e6a-15caa819e4a7/desktop-result.json) · [单窗实拍](../../build/native-acceptance/237ec2e8-4ae7-4741-9e6a-15caa819e4a7/panel-observed.png) · [资源与焦点](../../build/verification/product-next/installed-native.json)

### 最终成品与回退

- **本地中文管线。** 本轮 P5.6 首次查询时系统报告支持中文、资源尚未就绪。通过已签包的官方准备入口执行一次，后续进程及最终安装包均回读已安装。下载字节数未知。最终包麦克风状态为已授权，旧 Speech 授权状态为未决定。独立且已准备的固定 Saytile 领域程序处理了本轮 29,061 帧合成中文 PCM，本次 Recording 和 Attempt 自己的 terminal 为 completed，final 与预期短句一致，SQLite 完整性检查通过。另一独立程序身份未取得资源，自行停止；没有把它记作成功。未打开物理麦克风。[资源准备](../../build/verification/product-next/installed-voice-prepare.log) · [最终安装包资源读回](../../build/verification/product-next/shipping/installed-voice-status.log) · [此次识别关联收据](../../build/verification/product-next/voice-pcm/correlated-final.json)
- **资料原件与回退。** 最终 P5.6 → 既有 P5.5 → 最终 P5.6 使用同一隔离代际、同一目录 inode，五张媒体的 SHA-256 及顺序、人工修订、时区、旧版保存的显隐偏好和一笔 UNKNOWN 全部保留。外部输入 START、语音派发及窗口动作收据均为零；合成来源前后散列相同。另实测 Apple SQLite 对缺少 WAL/SHM 的主文件返回 CANTOPEN。原版一概提示文件损坏，现在日常启动能区分不可只读打开、忙锁、非数据库、坏页和不兼容 schema，五类均拒绝、原主文件指纹保持一致。修正还覆盖 header 版本正常但表页损坏的情况。未用个人资料。[两版往返](../../build/verification/product-next/version-roundtrip/final-roundtrip.json) · [五种真实错误](../../build/verification/product-next/version-roundtrip/final-read-errors.json) · [SQLite 实际返回码](../../build/verification/product-next/version-roundtrip/sqlite-cold-probe.json)
- **最终冻结。** 产品源码 `af8948a2580a2068a2b41153a0f1717bd8f19d1d`，安装 Host SHA-256 `73f795dd8929de8ee534edcfafb2118cc2b2b45c0a94bd3afc4a02df5abab062`。最终安装和上次混合平铺用包的五个嵌套助手逐字节相同；Host 增量涉及资料读取及显示器恢复。最终包在副屏重新启动并正常退出；原焦点、五图队列保持，输入尝试和 START 均为零。两扇合成窗的 Owner/CG/AX 最大误差 0 pt，空间登记前后均读回两个正确的静态 AX 轮廓，其中有真实 current 见证的一轮仅确认副屏自己的当前行。23.66 秒中采样 24 次，Host CPU 0.266 秒、能量计数差 0.266 J、物理内存 28.86–83.84 MiB。这是启动和可见预览的进程测量。[最终实拍](../../build/native-acceptance/c8d6a18f-65bc-40fc-b3dc-06cdbe58b7f1/panel-observed.png) · [最终现场读回](../../build/native-acceptance/c8d6a18f-65bc-40fc-b3dc-06cdbe58b7f1/desktop-result.json) · [资源与焦点](../../build/verification/product-next/shipping/installed-native.json)
- **回归与构建。** Swift 集成 300/300、独立 Host 238/238、固定网页组合 18/18、目标守卫 17/17、依赖解析 6/6、回执策略 27/27、窗口管理 Python 32/32、资料领域 10/10、迁移事务 14/14。固定上游仍为 93 + 78 = 171 个文件。Debug、Release 各有 16 份相同资源；Alpha 增加四份帮助与管理资源，20 份资源指纹为 `dbcba47b4d3428d465610fe7d696ee6a8560ce0d8f8a94bfbd92710a460ee782`。六个 Mach-O 验签通过，均含 arm64；属于本机开发签名，尚未公证。原始日志保留工程目录临时包的验签失败；最终安装目录的校验独立通过。[回归汇总](../../build/verification/product-next/shipping/regressions.log) · [窗口回归](../../build/verification/product-next/window-management.log) · [领域投影](../../build/verification/product-next/shipping/profile-domains.log) · [迁移回归](../../build/verification/product-next/shipping/profile-transactions.log) · [Debug/Release](../../build/verification/product-next/shipping/packages.log) · [安装资源](../../build/verification/product-next/shipping/installation.log) · [签名清单](../../build/verification/product-next/shipping/distribution.json)
- **本地提交。** 基线 `b90c3ca` 后依次为 `c0ca411` 会话/预览/输入法、`2fbcae4` 混排实测、`d2565c3` 管理对象显示、`fb3cf9b` 空间路由见证、`1b0db47` 领域权限恢复、`18c4d98` 独立打包、`043fd47` 资料错误与屏幕重连、`af8948a` 普通启动坏页核对。最终收据提交可由 `git log -1 --format=%H -- engineering/verification/PRODUCT_COMPLETION_STATE.md` 定位。

### 当前须由外部满足的条件

1. **空间与全屏。** 优先交付一对相邻空白测试 Space 及允许副屏切换和返回的无人时段，或指定可控独立双屏的图形会话。工程端负责身份映射、校准、三轮往返、回程和清理。现在仅有一个副屏候选。跨空间迁窗与 Virtual 各自仍需单独的身份、动作及恢复证据。真实第三方全屏、物理插拔、真人输入法或 VoiceOver 使用体验和真实区域截图磁力效果，沿用受保护环境条件。
2. **真人端到端。** 若希望完成这两项验收，一次交接安静中文短句时段，以及一个合法登录、无私人内容的专用 ChatGPT 草稿。二者可以分别选择。真实设备采集、实际外部文字插入与 ChatGPT 最终服务回执按各自证据待验，UNKNOWN 保持原状。
3. **发布。** 个人 Alpha 可本机使用。向他人正式分发时才需 Developer ID、公证及干净设备验证。当前无公开发布。

## 按能力追溯的历次证据

| 正式能力 | 状态 / 实际边界 | 证据、依赖与下一步 |
|---|---|---|
| 普通窗逐窗选择、预演、授权/撤销、同应用隔离 | VERIFIED · 当前 build 的副屏标准 AppKit 窗口；全局自动接管关闭 | [P5.4 原生](P5.4-REAL-AX-ACCEPTANCE.md)；产物源码 `8613465`。达到真实 AX/CG/焦点条件才能发放许可。无普遍第三方兼容声明。 |
| 成员增减、渐进平铺、用户比例、超八窗分流 | VERIFIED · 副屏无专用协议的标准 AppKit 普通窗逐窗授权后 1–8 窗实测；新兄弟窗不自动纳入。三窗关闭和 60:40 历史恢复已实测 | [本轮九个阶段](../../build/verification/p54/ordinary/a56be84a-0e3d-4625-b094-652a62aa9750/density.json)：17 个布局事务、停止后 8 次原位恢复，Owner/AX/CG 最大误差 0 pt；第九未授权窗零写入、同焦点、零残留。没有将第九窗当成硬上限；9–17 仍为布局模型验证。旧包在第五/六窗的拒绝经 BSD 代际、可执行文件及动态签名共同重验修正。[关闭的时间证据](../../build/verification/p54/ordinary/b073e46d-914a-4234-8daa-072d92957b55/)证明 CG 仍在执行结束动画。限定只读等待后，[真实关闭/重建](../../build/verification/p54/ordinary/70f934e1-fdd4-4ca6-bf17-fba33eae2229/membership.json)通过：通知后约 329 ms 消失，101 ms 后复证；自动恢复双窗 60:40，同名新窗不继承许可，11 笔操作的 6 个检查点均 0 pt。 |
| 工作区预留、排除、暂停、停止与恢复 | VERIFIED · 副屏 Docked/Floating、排除、可证明时恢复；进程重启没有持续见证时保留待处理日志 | [故障回合](P5.4-REAL-AX-ACCEPTANCE.md)、[随包应用](P4.6-NATIVE-ACCEPTANCE.md)。已按所选窗口实际显示器分别预演；跨屏混选只读，旋转/缩放变化使旧授权失效。主屏可独立保存配置，未开放个人窗口写入。 |
| Stage Manager、跨屏和系统调整 | PARTIAL · 正常几何可管，几何不一致拒绝；移动/编辑不能可靠归因时不覆盖 | [P4.8](P4.8-STAGE-MANAGER-COMPATIBILITY.md)。不重做 TextEdit 异常试验；未证明缩略几何的具体成因。 |
| 空间、窗口、显示器只读映射 | VERIFIED · 可见几何轮廓、z-order、按显示器呈现；仅有可见 Space 见证时成行 | [P4.0](P4.0-readonly-desktop-closeout.md)。未将内部记录数当成桌面数；无证据时只显示可见窗口。 |
| Native 行点击切换、保留焦点、返回 | BLOCKED · 无获准且可控的独立 A/B 环境；产品动作关闭 | [P4.3](P4.3-ACTION-ADMISSION.md)。Apple 的[变化通知](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)不提供源/目标身份；[moveToActiveSpace](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/movetoactivespace)是本窗口激活时的行为，不是切换到指定任意桌面的公共命令。只在有两屏初态、A/B 与可靠回程的专用时段执行。 |
| Native 跨 Space 拖窗、新窗新空间、清理空空间 | BLOCKED · 已拆分窗口拖放/整行意图及归属、扩容策略；未实现可准入的系统写适配器 | [动作门槛](P4.3-NATIVE-SPACE-BEHAVIOR.md)。实际移窗/创建/删除各需权限与独立结果见证；无能力时只做可行分割，不虚构新 Space。 |
| Virtual 逻辑归属与真实隔离 | BLOCKED · 已有模式互斥及逻辑模型，未获可靠的第三方单窗口停放/恢复机制 | [P4.2.2 裁决](P4.2.2-VIRTUAL-TECHNICAL-VERDICT.md)。Apple 的 [orderOut](https://developer.apple.com/documentation/appkit/nswindow/orderout%28_%3A%29) 属于目标 NSWindow 实例，且可能改变 key/main，不提供普通外部管理器的逐窗授权；不重复旧停放、Hide 或最小化。 |
| Saytile 实时文字、编辑保护、复制和手动插入 | PARTIAL · 原生文字、手改与复制及本地资料重开已验证。手动插入已接通固定 Saytile 引擎和独立修订回执，真实前台输入框待验 | [P4.5](P4.5-ALPHA-CORE-WORKFLOWS.md)、[版本延续](P5.3-PROFILE-MIGRATION.md)。[专用输入测试](../../Tests/NearpaneVoiceTests/ManualVoiceInsertionTests.swift)使用真实隔离数据库和替身输入框；实际私人的输入框从未用作验收。用户须从复制按钮菜单主动选择。一次手势不并发、不向新目标续写，未知结果不会自动补发；再次主动选择是另一笔人工操作。 |
| 中文采集、声级、待命/说话/暂停与纠错 | PARTIAL · 本地中文合成 PCM 有本次 Attempt 的 completed+final；物理麦克风、真人说完待命未验 | [工作流](P4.5-ALPHA-CORE-WORKFLOWS.md)。不录私人语音、不调用付费服务；本轮已在设置接通显式同意、逐资料凭据、本机/API 切换和撤销；原 Saytile 单专家+融合控制器，五项临时资料/凭据替身测试通过。未用实际服务。 |
| Riftlet 系统截图、托盘、历史队列和共享锁 | VERIFIED · 隔离副屏截图、滚动/展开/收起、重新打开与顺序已证实 | [P4.8 成品](P4.8-ALPHA-DELIVERY.md)、[P5.2 对齐](P5.2-UPSTREAM-INTEGRATION.md)。仅明确授权后监听用户选中的截图目录，不创建第二套队列。 |
| 截图点击附加到草稿、不发送、UNKNOWN | PARTIAL · 普通 Alpha 已接入真实适配器；本地无界面浏览器及真实领域回执守卫通过。真实服务端终态 BLOCKED | [P5.0](P5.0-CHATGPT-ATTACHMENT.md)。只需专用已登录的非私人草稿；不重新代用户上传、不补传 UNKNOWN。 |
| 一套领域实例、唯一主驻留屏、副屏 Space-only | VERIFIED · 角色切换、跨模块状态延续已有副屏/合成拓扑组合实证；物理拔插、两块个人工作屏同时操作未验 | [P5.2](P5.2-MULTIDISPLAY-ACCEPTANCE.md)，`4ac8a84`。镜像/失效身份/旧事件降级。 |
| 原生全屏与 Fill、主动精简工具、位置保存、返回 | PARTIAL · 实现运行链及手动副屏工具、源身份检查；真实第三方系统全屏覆盖和返回未验 | [P5.1](P5.1-FULLSCREEN-RUNTIME.md)。本机缺不扰动主屏的全屏试验；不猜 Space，不暂停领域。 |
| 连续宽高、按屏 pt/%、图标及恢复默认 | VERIFIED · 原生图标/默认/窄高/展开已有实拍；本轮副屏实测“模块”和“本屏全部尺寸”的预览、取消、应用 | [P4.8.1](P4.8.1-RESPONSIVE-ALPHA.md)、[本轮 Settings 实测](../../build/verification/product-closeout/settings/7924e58d-b891-42c7-aa0d-db30a8cc38da/result.json)。只复原模块时独立预留保持 119 pt；确认全屏尺寸重置后才恢复跟随。另一屏配置不变、管理写入零。P5.4 同时操作普通窗口和图标的一次焦点分歧不按通过。 |
| 默认布局、玻璃、文字、截图动效、键盘可及性 | PARTIAL · 有副屏单窗实拍/滚动/焦点；动态玻璃和真实选区磁力仍缺连续可归因证据 | [P3.8](P3.8-native-experience-closeout.md)。禁止采集个人桌面，不用静态替代动态。本轮补齐按模块/当前屏恢复尺寸，应用前提示 Docked 预留变化；显示器拓扑变化原地刷新设置页并作废旧确认。提交 `782e2df`，副屏设置操作见上一行。系统 VoiceOver 导航未经真人验收。 |
| 用户可选模块及隐私 | VERIFIED · 时钟默认不启用，沿用既有 ID、启停、顺序。已在真实副屏侧栏展开和收起，能显示本地时间；可选额外时区 | [真实展开](../../build/verification/product-closeout/settings/7924e58d-b891-42c7-aa0d-db30a8cc38da/clock-expanded.png)、[时区回归](../../build/verification/product-closeout/domains/local-clock.log)。候选隐藏无实际数据源的样例；日历、天气、AI 等在产品定义中是可选扩展方向，没有作为已实现集成。 |
| 可选的日历、天气、AI 或第三方插件 | NOT_IMPLEMENTED · 产品定义列为扩展方向，当前成品未提供对应数据服务 | 时钟已独立落地；其余项目等实际用户任务、数据源及权限决定。[模块范围](../../PRODUCT_DEFINITION.md) |
| 首次使用、权限说明和故障处置 | IMPLEMENTED · 安装包内提供可离线阅读的使用帮助；设置显示授权范围、拒绝原因及待处理恢复 | [随包帮助](../../docs/ALPHA-HELP.md)。当前系统的隔离运行已验证；新设备的 TCC 首次授权和不同辅助技术用户的上手体验未实测。 |
| 升级、资料契约、备份、失败回退 | VERIFIED · P5.2 → P5.3 隔离副本实测，P5.4、P5.5 沿用相同格式和身份；旧操作、TCC 和窗口票据不继承 | [升级回退](P5.3-UPGRADE-ROLLBACK-ACCEPTANCE.md)，`cc36d14`。更早版本按标记和真实 schema 拒绝不兼容；本轮不迁移个人资料。 |
| 驻留、退出屏障、权限及资源 | PARTIAL · 领域进程排空、关闭观察器、睡眠/唤醒和历史一小时驻留有证据；不是普通窗口观察长期电量基准 | [P3.7](P3.7-hardening-closeout.md)、[P5.2](P5.2-MULTIDISPLAY-ACCEPTANCE.md)。新加入的长期观察以限定目标、有限采样和退出清理测量。 |
| Apple Silicon、安装及公开发行 | PARTIAL · 本地开发签名，6 个 Mach-O 均有 arm64，按各自部署下限验签；正式签名、公证、干净设备验收仍 BLOCKED | [打包检查](../../scripts/check-alpha-distribution.py)、[发布门禁](../../build/verification/product/distribution-gate.json)。[Apple 公证要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)：按授权签名并加固、时间戳、公证、干净机安装验证。已在一次性副本按嵌套顺序加固、重新计算 3 项助手指纹、重新封签 6 个 Mach-O；[原包保持一致](../../build/verification/product/signing-rehearsal.json)。未使用发布凭据或上传；窗口/资料助手仅使用已安装的 Apple 签名 Python，缺失时拒绝、不触发安装。 |

## P5.5 交付记录

可运行：[P5.5 Alpha](</Users/hhf/Applications/Nearpane P5.5/Nearpane P5.5 Alpha.app>)；[P5.4 回退包](</Users/hhf/Applications/Nearpane P5.4/Nearpane P5.4 Alpha.app>)。P5.3 起共用稳定资料契约及写锁，须先退出再换版，不拷贝数据库，不自动回放外部操作。本轮只用标记的隔离目录。

- 提交：`daf477b` 建立状态；`782e2df` 恢复尺寸；`182ae05` 领域设置和真实时钟。`d9adbe2` 固定八窗、按屏预演、资料锁及安装验收。对应 P5.5 首份安装 Host SHA-256 `bba64dfbb083f904a9120e9843732e11cdb2d97da9b65c8817d86f056867a104`。安装与回退边界见[使用帮助](../../docs/ALPHA-HELP.md)。
- [集成 271/271](../../build/verification/product/integrated.log)、[独立 Host 221/221](../../build/verification/product/foundation.log)、[Debug/Release](../../build/verification/product/packages.log)、[安装资源](../../build/verification/product/installation.log)、[资料事务 13/13](../../build/verification/product/profile-transactions.log)。171 份固定输入均验证；资料锁持有者退出释放的并发回归已通过；原先失败保留在 integrated-current.log。
- [真实密集窗口几何/采样](../../build/verification/p54/ordinary/a56be84a-0e3d-4625-b094-652a62aa9750/geometry.json)：42.88 秒交互，Host CPU 累计由 0.28 增至 1.35 秒，RSS 峰值 94,288 KiB；窗口助手 CPU 0.04→0.86 秒，RSS 峰值 15,600 KiB。不能外推电池续航。
- 第二轮冻结修复：`5720cf32269e33b9f2067e2945f7dcbae83d005e58e76406b61c65cfbac927b2`（Host）；[278 项集成](../../build/verification/product/final-integrated.log)、[228 项独立 Host](../../build/verification/product/final-foundation.log)、[安装资源](../../build/verification/product/final-installation.log)。关闭/重建已实测；[排除与驻留](../../build/verification/p54/ordinary/ea4e25fe-579a-4070-841e-f29568037dfa/exclusion-result.json)亦已通过。逐窗 Settings 按钮落盘后仅另一窗重排一次，未授权窗零写；App 排除经同一设置 setter 验证（未点击该表单），撤销余窗且不覆盖其位置。[180 秒内核采样](../../build/verification/p54/ordinary/ea4e25fe-579a-4070-841e-f29568037dfa/steady-resources.json)：7 个检查点、事务数始终 3；Host CPU 1.0843 s / 0.72742 J / 35.20–35.64 MiB，助手 0.8228 s / 0.76499 J / 5.91–6.02 MiB，不是整机功耗。普通 Settings 的选择在关窗、最小化、遮挡和锁屏时撤销，不中断已授权的窗口管理；仅就实际执行环境报告。
- 时区回退缺陷：两个旧/新签包对隔离配置保存后会遗失额外时区。[复现](../../build/verification/product/version-roundtrip/probe.json)。`1dba9bf` 将显式时区选择原子保存于当前资料代际，旧版继续管理原有设置。损坏记录保留，重新选择后可恢复；损坏源不会作为成功导入发布。两项 Swift、10 项领域及 14 项迁移事务检查通过。[迁移收据](../../build/verification/product/version-roundtrip/migration.log)。

## P5.5 冻结成品

产品源码 `0d6c9731995f2fcdff4d18ef1342a841e80524cf`。Finder 打开上方 P5.5 Alpha，在菜单栏进入设置；默认不接管普通窗口。此构建在 `839cb18` 的窗口生命周期基础上加入 `1dba9bf` 的时区资料延续、`e947d61` 的手动文字插入、进程内验收外观采样及深色语音图形修复。手动插入从正在使用的输入框开始，在检查其他页面内容之前核对进程、窗口、元素和文档，遇到来源不明或无明确回执就中止。[输入守卫的 21 个场景](../../build/verification/product-closeout/domains/manual-scope-3.log)在真实 SQLite 及替身输入框上运行。

| 最终包检查 | 结果 |
|---|---|
| 工程回归 | [Swift 集成 285/285、独立 Host 230/230、JS 18/18 与 17/17、依赖解析 6/6、回执 27/27](../../build/verification/product/shipping-contrast/regressions.log)；[窗口策略 32/32](../../build/verification/product/delivery-window.log)。套件有交叉，不相加。 |
| 可运行文件和资源 | [Debug/Release 各 16 项资源](../../build/verification/product/shipping-contrast/packages.log)，[安装包 20 项资源](../../build/verification/product/shipping-contrast/installation.log)。P5.5 Host SHA-256 `e6e9ddd1e6e4931d02798a98622f5178313b2ce8d4c3573b402afcd98ae742c2`；P5.4 回退包的 Host 仍为 `80f42f10b307ec7f6b60788a256a4d0c30748e4137f34ad334cedefff901eda5`。[完整指纹](../../build/verification/product/shipping-contrast/installed.sha) |
| 依赖与发布 | 对两个锁定版本逐文件校验 93 + 78 = 171 份输入。P5.2 的完整源码对照和本轮核对仍支持保留锁，独立应用主分支的改动没有引入第二个引擎。[首方比较](P5.2-UPSTREAM-INTEGRATION.md) · [独立复核](../../build/verification/product/independent-delivery-audit.json)。[签名演练](../../build/verification/product/shipping-contrast/signing-rehearsal.json)签封 6 个嵌套 Mach-O，更新了 3 个助手指纹；安装包逐文件保持一致，未使用 Developer ID。 |
| 隔离资料 | [领域 10/10](../../build/verification/product/shipping-contrast/profile-domains.log)、[事务 14/14](../../build/verification/product/shipping-contrast/profile-transactions.log)。空资料夹具与含五张图的夹具原始目录散列分别为 `8691e847…d195`、`0b51c11a…5977`，前后逐一相符。人工编辑、队列顺序和 UNKNOWN 保留；没有授予浏览器输入、系统权限或旧窗口操作许可。 |

在外观修复前的冻结 Host `b93fca41…b64c` 上，[再次逐窗授权 1–8 扇副屏普通窗](../../build/verification/p54/ordinary/1349fee5-2175-46cc-b67c-c12e9fffba12/density.json)。17 笔布局、8 笔原位恢复，所有者读数与 AX/CG 的最大几何误差都是 0 pt。第九扇未获授权的同应用窗口始终保持原位；[退出清理](../../build/verification/p54/ordinary/1349fee5-2175-46cc-b67c-c12e9fffba12/cleanup.json)核对焦点未变、无残留、退出码 0。最终包的普通窗口助手与此轮逐字节相同，源码差异只涉及语音字形；没有重跑窗口写入。

P5.5 → P5.4 → P5.5 的[真实安装包往返收据](../../build/verification/product/version-roundtrip/installed-result.json)来自同一个隔离资料代际；P5.5 Host 为 `b93fca41…b64c`，最终包的资料事务另见上表。旧包重存后主配置已无时区字段，新包重开仍读到 `Asia/Shanghai`，并读回旧包的显示设置变更。显式清除、损坏原件保留、导入暂存区隔离和领域记录数量都通过。

最终成品按同一副屏 240 × 1280 pt 面板分别呈现 Aqua 和 Dark Aqua。实际 AX 界定的收音按钮内，深色实心字形对相邻底色从 1.522∶1 提高到 3.528∶1，浅色保持 3.625∶1。合成文字及四张可见缩略图的位置、大小一致，五张图的队列和原焦点保持。验收采用的非文字控件对比度参考值是 3∶1；此处只报告两个实测外观。[修复前深色实拍](../../build/verification/product-closeout/appearance/4188f15e-3a76-4990-bd78-46d09a7e230a/darkAqua.png) · [修复后深色](../../build/verification/product-closeout/appearance/261b0027-6e5d-430b-8f48-2b49d2715518/darkAqua.png) · [最终浅色](../../build/verification/product-closeout/appearance/261b0027-6e5d-430b-8f48-2b49d2715518/aqua.png) · [原始几何、像素及退出收据](../../build/verification/product-closeout/appearance/261b0027-6e5d-430b-8f48-2b49d2715518/result.json) · [W3C 的对比度说明](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html)

### P5.5 当时的外部条件

- **真人语音、前台文字输入。** 语音只需一次安静且本人同意的短句，核对实际 Host 的麦克风与语音权限、本次 Attempt 的 final 及返回待命。外部文字插入另需一个可暂时取得真实前台焦点的空白测试输入框；使用前台的个人桌面期间保持待验。默认本地模式无需 API 密钥。
- **草稿附件。** 只在已有授权的、已登录且无私人内容的专用草稿上做一次单图输入，再看原 Riftlet 的终态；没有终态继续保留 UNKNOWN。无需再次验证已通过的托盘和网页守卫。
- **桌面编排。** 已管理对象覆盖副屏标准 AppKit 窗口。扩大到某款日常应用，需要该应用的独立空白窗口和相应授权。对 Native 的下一步是专用时段或隔离桌面上的真实 A→B→A、两屏见证及可验证返回。第三方全屏覆盖、物理拔插、真实选区动效和合成材质的最终视觉效果，均须满足不影响个人主屏且能对现场画面取证的条件。
- **Virtual 和公开发行。** Virtual 继续关闭，等有能够独立读回同一窗口、可恢复且保护同 App 兄弟窗口的新系统机制。公开分发需要受权的 Developer ID、公证和干净机安装；本地可直接使用上述 Alpha。

**P5.5 当时按完成条件 B 交接。** 以上授权范围内的工程和设备验收已收口。保留未通过的原始观测和明确的下一项门槛。发布前须取得相应授权；本次只在工程分支本地提交。远端查询时仍为 `cc36d147904fde58373fbb868d270502c69af31e`。[只读远端收据](../../build/verification/product/nearpane-origin-at-delivery.json)。本收据所在本地提交用 `git log -1 --format=%H -- engineering/verification/PRODUCT_COMPLETION_STATE.md` 定位。
