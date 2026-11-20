# 5.22（90）正式 Host 验收

研究基线为 `3151827`，PR #15 起点为 `6f85f73`，其历史包含 PR #14 的 `629524b`。本页记录 macOS 27.0（26A428）、单块物理显示器上的安装和操作，其他环境的结果另列。[源码路径与技术裁决](../../../research/IMPLEMENTATION-PATH-MAP.md)

## 窗口调度区

已安装的 `f9e981c` 在两个独立回合均通过空、打开两扇文档、关窗测试。三个状态分别为 0、2、0 张窗口卡，独立空间行、占位文字和重复控件均为 0。双窗截图第二张卡有紫色窗口预览，第一张为轮廓，两张预览像素均就绪尚未通过。[空态实拍](window-roster/empty-before-sidebar.png) · [两扇文档](window-roster/two-documents-sidebar.png) · [关闭后](window-roster/empty-after-sidebar.png) · [窗口与侧栏逐项读回](window-roster/results.json)

实机录屏只采集身份已核对的正式侧栏与系统壁纸。12 帧通过前后窗口、几何及配置核验，按实际时戳编码为 14.84 秒 H.264，单视频轨、无音轨。第一次因并发采集超时，只录到打开文档。该尝试和未采集区间随收据保留。此片记录窗口打开及关闭，跨 Space 动画单独验收。[实机录屏](window-roster/installed-sidebar.mp4) · [帧、间隔和哈希](window-roster/recording.json) · [首次不完整录制](window-roster/first-recording-incomplete.json)

## 相邻普通桌面

正式入口为悬浮侧栏中具体窗口的 AX 按钮。验收先绑定安装路径、签名、进程出生时间和隔离数据目录。独立进程只建场、清理并读取 WindowServer 的实际 Space。计入产品切换需要同一意图 ID、源/目标 ID 和 UUID、真实三阶段投递、Host 终态与独立持续到达证据。

| 安装版运行 | 结果与系统读回 |
| --- | --- |
| [第一次普通桌面建场](01-ordinary-setup/results.json) | 前台变化，停止。临时普通桌面已回收。 |
| [既有全屏](02-user-fullscreen/results.json) | 原前台是既有全屏，未向它投递输入。 |
| [自有全屏](03-owned-fullscreen-setup/results.json) | 系统未同时证实两扇窗口归属，收尾原始焦点为 UNKNOWN。 |
| [连续建立普通桌面](04-overview-dismissal/results.json) | 第一次添加后未确认 Mission Control 已退出，第二次添加未投递。随后按创建收据回收，原有三个空间和当时前台均已独立核对。[回收收据](04-overview-dismissal/lease-cleanup.json) |
| [核对原生桌面按钮](05-tile-identity/results.json) | 连续添加和回收两个桌面成功；系统按钮的 AX 归属与旧检测假设不符。 |
| [两扇真实普通窗口](06-background-AX/results.json) | 系统原生控件选中两个临时桌面，各窗口在所属桌面均有精确标准 AX 身份。切走后，第一扇窗口仍有双向唯一 Space 归属，但系统 AXWindows 清单将其省略。此轮两租约均已释放，正式侧栏投递为 0。[两窗口读回](06-background-AX/fixture-second-document.json) · [系统收尾](06-background-AX/lease-cleanup.json) |
| [清点空桌面期间有新用户输入](07-new-input/results.json) | 取消建场，退出两个自有应用。随后按 ID/UUID 独立回收两租约，保留新选中的全屏空间；精确焦点恢复为 UNKNOWN。[回收收据](07-new-input/lease-cleanup.json) |
| [独立空间清单复读](08-native-list/results.json) | 稳定空清点通过，识别到 WindowManager 的真实 AX 按钮，第二次读取清单时不能确认系统显示组，选择未投递。两租约已回收。[系统按钮分项读回](08-native-list/setup-press-4995.json) |
| [安装版保留窗口测试](09-installed-background-card/results.json) | `da46651` 的两扇受控窗口均已在各自的普通桌面显示，正式侧栏分别连续两次给出可按的正确当前卡。独立读回确认独占归属和原窗口身份。首次 B→A 在 5 秒内仅出现一张当前卡，后台目标卡为 0，正式按压和 helper 投递均为 0。原桌面顺序已恢复、无遗留临时桌面，瞬时前台及焦点恢复为 UNKNOWN。[正式按钮读回](09-installed-background-card/roundTrip-01/card-before.json) · [安装身份](09-installed-background-card/installed.json) |
| [正式 Host 逐层读回](10-retained-AX-error/diagnosis.json) | `1ddec43` 在有界的专用测试目录写入了两扇夹具的诊断。A 在前台已绑定原 AX 对象；切到 B 后 Reader 仍交付 A 和独占归属，签名动作助手首次读取后台应用窗口列表返回 `AXError.illegalArgument (-25201)`，后续丢失原对象。正式按压为 0。两租约均已回收，日常前台原为已被替换的 Nearpane 进程，原窗口引用恢复为 UNKNOWN。[Host 原始事件](10-retained-AX-error/host-window-audit/installed.jsonl) · [日常配置和焦点](10-retained-AX-error/profile-session.json) |
| [首次正式相邻往返](11-adjacent-round-trip/results.json) | `96a3e3d` 保留了后台原窗口。正式侧栏 B→A、A→B 均有一次真实三阶段投递及独立稳定落点。随后 10/10 交替落点也已确认，每次继续观察 2 秒。10 次的物理防黑屏前置校准拒绝当前系统壁纸目录，只有夹具视频，视觉结果为 UNKNOWN，50 次未运行。两个临时桌面均已回收，原顺序和日常配置已恢复。日常 Nearpane 前台原 PID 已退出，精确焦点恢复为 UNKNOWN。[12 条逐动作收据](11-adjacent-round-trip/per-action.jsonl) · [重新核算的时延和 579 条独立采样](11-adjacent-round-trip/readback.json) · [全部原始读回](11-adjacent-round-trip/original-receipts.tar.gz) · [观察范围与影片哈希](11-adjacent-round-trip/ten-01-visual.json) |
| [物理显示器校准](12-physical-probe/results.json) | 同一签名候选的两端桌面、系统壁纸、窗口受控区域和两种颜色均独立校准。往返再次 2/2，10 次阶段第 1 次落点确认后，黑屏检查无法解释辅助截图的时间区间，自动停止。原收据为 UNKNOWN。167 个原生呈现样本的独立重放确认最长间隔 33.334 毫秒、未观测到空白呈现，目标色仍未证实。[保留原结论的重放](12-physical-probe/visual-replay.json)。50 次未运行。本次两个租约、原桌面和日常精确焦点均已恢复。[实际采样和时间](12-physical-probe/ten-01-visual.json) · [日常前台恢复](12-physical-probe/profile-session.json) |
| [显示呈现时序与目标颜色](13-presentation-timing/results.json) | 同一候选再次往返 2/2，第 1 次交替落点确认后自动停止。显示流中 6 个完整目标帧有 5 个匹配独立校准色。原生呈现间隔一处实测 50.000042 毫秒，跨越 50 毫秒上限；部分早到回调缺少同时序的后续表面见证，独立末端校验也未就绪。视觉 UNKNOWN，50 次未运行。[时间及最终颜色证据](13-presentation-timing/physical-readback.json) · [完整原件](13-presentation-timing/original-receipts.tar.gz) |
| [真实窗口动态色标](14-moving-documents/results.json) | 正式侧栏往返 2/2，再发第 1 次交替并独立确认落点。两扇受控文档在自己的窗口内改变颜色。真实显示流的 196 个呈现均有窗口与时序证明，最长间隔 16.667 毫秒，持续可见、零原生空白、目标色均已确认。终点最后一次独立清点发现额外的层 0 窗口，身份未证实，取证在另一份截图前停止。整轮视觉继续为 UNKNOWN，两个临时桌面、日常焦点和配置均已恢复。[分项结果](14-moving-documents/target-check.json) · [每次真实按压](14-moving-documents/per-action.jsonl) |
| [额外窗口身份查明](15-fixture-auxiliary/owned-auxiliary-diagnosis.json) | 同一安装版再次往返 2/2，第 1 次交替实际到达。显示时序、持续亮度及目标色均通过。20 次独立清点证实额外窗号 50369 属于受控 Field Notes 的同一签名进程，其 AX 子角色为非标准、非主窗，位于取样区外。目标文档窗号为 50319。此轮按旧规则停在末端交叉截图之前，整体仍为 UNKNOWN。[全部原始收据](15-fixture-auxiliary/original-receipts.tar.gz) |
| [切换过程中的一次系统通知](16-handoff-frame/handoff-readback.json) | 正式侧栏往返 2/2，第 1 次交替落点已确认。辅助窗资格、两次终点清点、真实显示流目标色和独立终点截图全部通过。193 个呈现中有一帧的两次元数据都确认了同一受控目标表面，但活动 Space 在两读之间由源变为目标。当时的观察器没有读取此帧像素，持续亮度保留 UNKNOWN，后续选择已停止。[原始收据](16-handoff-frame/original-receipts.tar.gz) |
| [系统 Dock 身份读取中断](17-system-dock-identity/results.json) | 建场进程从内核和 Apple 签名确认了原 Dock，但读取概览控件时又通过 Launch Services 查找 Dock，第二次查找未得到唯一结果。系统“添加桌面”按钮与正式侧栏均未按下。此轮新建桌面 0 个、真实切换 0 次。原有两个桌面的身份及顺序、原始焦点和日常配置均已核实恢复。[原始事件](17-system-dock-identity/actions.jsonl) · [独立复算](17-system-dock-identity/readback.json) |

以上建场成功次数和历史版本的尝试均不计入本候选的往返、10 次或 50 次门槛。

## 构建与兼容性

- 本机使用仓库标准测试入口，524 项 Swift 测试、78 个测试套件通过。macOS 26.7.2 的 GitHub runner 编译了生产 helper，运行真实生产协议与 Host journal 的 13 项 Swift 测试，并完成 41 + 13 项 Python 测试。此前有四次失败和一次工作流返回成功却没有执行 Swift 测试，均保留在基线收据中。工作流现要求四个套件和非零测试的结束记录。[机器收据](baseline.json) · [CI 运行日志](https://github.com/haohongfei2001-png/nearpane/actions/runs/44720154517)
- P1 仅读取系统 ABI。当前系统的 `initWithWindows:spaceID:` 和无冒号 `performWithWMBridgeDelegate` 均存在，后者返回 void；操作对象创建为 0，迁窗请求为 0。[ABI 收据](move-abi.json)
- 同一 macOS 26.7.2 runner 随后也完成了生产 NearpaneUI 在 foundation-only 配置下的编译。保留原主题设置行为，避免了旧 Swift 编译器的 IR 生成错误。[编译及协议收据](https://github.com/haohongfei2001-png/nearpane/actions/runs/44721534963)
- P4 本地翻译/单词本与 Saytile 独立分支保留持久化和最终稿测试；P5 独立分支保留预热 5×20 的统计与真实进程用量采样。正式安装版的原位翻译、完整首句矩阵、多屏、Split View、睡眠恢复和性能门槛仍待实测。[P4 源码与收据](https://github.com/haohongfei2001-png/nearpane/tree/baa28fe4b40205e1014b4f702ba1bdd80c6fce46/engineering/verification/native-spaces/5.22-p4) · [P5 数据和门槛](https://github.com/haohongfei2001-png/nearpane/blob/30595b287e66c7fb79ab0bb5999509745f0eaaaa/engineering/verification/native-spaces/5.22-p5/harness.json)

- P4 另在标准 macOS 26.7.2 arm64 runner 合成了三句干净语音及各自 10 dB 加噪文件。Apple 解析到中文，但系统报告设备转录器不可用、资产 unsupported。6 条均为 NOT_RUN，未取得本轮识别率，正式安装版新增冷启动为 0/60。[原始模型收据与复算](https://github.com/haohongfei2001-png/nearpane/tree/d6df4bf1e55949ca97b8a2a712a8020a25130366/engineering/verification/native-spaces/5.22-p4/hosted-speech)
- P3 的 Riftlet 专用分支在 Chrome、Edge 和四个域的 96 个隔离场景中验证了附件与零发送，16 个可见附件、8 个取消、72 个投递前拒绝。正式 Host、已登录服务的上传完成及 Safari 标签身份尚未通过。[源码、逐案证据及回退](https://github.com/haohongfei2001-png/nearpane/blob/35940ff2917aa51ec6ad2bf19050230af7c5611a/engineering/verification/native-spaces/5.22-p3/QUALIFICATION.md)

同一候选的窗口区再次取证：增强的观察器在空态、两窗分别连续两次核对了 Host 与夹具代际、当前桌面和窗口集合。关窗后正式侧栏读回超时，此次为 BLOCKED，11 帧录屏只覆盖 0→2。此前另一次实拍有 14 帧。[双读回与超时](12-physical-probe/roster-two-censuses/results.json) · [实际录制区间](12-physical-probe/roster-two-censuses/recording.json)

使用同一安装包按顺序读侧栏和截图后，三状态完整通过。空态、两扇文档、关闭后分别由两个独立进程确认 0、2、0 张卡，三次均无空间行、占位文字或重复卡。夹具退出，系统窗口编号已消失，日常配置已恢复。此轮关窗后保留了窗口区域截图。[空态侧栏](12-physical-probe/roster-serialized/empty-before-sidebar.png) · [两扇窗口](12-physical-probe/roster-serialized/two-documents-sidebar.png) · [关闭后](12-physical-probe/roster-serialized/empty-after.png) · [六次独立系统读回](12-physical-probe/roster-serialized/results.json)

## 签名候选与回退

当前候选 `96a3e3d` 的 SHA-256 为 `5c019c20effbc81e4e7733b5b21ac6d0d1af9160305f628e0c0095680853871e`。本机全量 538 项 Swift 测试、82 套件通过。托管 macOS 26.7.2 编译生产 UI、执行 18 项协议测试，另在完整 UI 测试可执行文件中实跑 7 项窗口引用和空 AX 数组测试。本机安装保留三项授权。草稿 ZIP 的 141 个文件、11 个符号链接和 96 个目录逐项与安装包相符。[GitHub 下载回读](11-adjacent-round-trip/candidate/github-binary-readback.json) · [包与实际安装逐项比对](11-adjacent-round-trip/candidate/zip-installed-tree.json) · [签名及实际权限](11-adjacent-round-trip/candidate/live.json) · [内部下载与校验值](11-adjacent-round-trip/candidate/candidate.json) · [CI 日志](https://github.com/haohongfei2001-png/nearpane/actions/runs/44728228718)

此候选的侧栏实拍 0→2→0，无占位标签和空间行，14 帧、15.69 秒。双窗时候选显示了两张身份正确的卡，独立观察器本次报告了 0 扇可证明可见窗口，故此轮窗口完整性为 BLOCKED。夹具退出后两个号码均已消失。[截图](11-adjacent-round-trip/window-roster/two-documents-sidebar.png) · [侧栏录屏](11-adjacent-round-trip/window-roster/installed-sidebar.mp4) · [完整性分项](11-adjacent-round-trip/window-roster/results.json)

签名候选 `da46651` 包含前台精确 AX 引用、后台进程与独占归属复核、单次导航及落地焦点约束。本机全量 531 项 Swift 测试通过，原位安装保留三项权限。窗口卡再次经实机验证为 0→2→0，本轮录屏 13 帧、15.22 秒、无音轨。ZIP 的 SHA-256 为 `9d5e04786cd9ebc17f8d31d11a3bd38a113b46d82c7b179dc30ab2e6df50f72a`。[安装及签名](retained-window-candidate/installation.json) · [实时权限](retained-window-candidate/live.json) · [窗口实拍](retained-window-candidate/window-roster/two-documents-sidebar.png) · [真实窗口区录屏](retained-window-candidate/window-roster/installed-sidebar.mp4) · [下载记录](retained-window-candidate/candidate.json)

`Nearpane-5.22-90-f9e981c-macOS-arm64.zip` 已原位安装。正式 Host 与七个权限助手的指定要求逐项双向相容，辅助功能、事件投递和录屏均由安装版进程实时读回。授权延续依赖这组签名身份和系统授权状态。分发检查仍缺 Hardened Runtime、可信时间戳、公证、staple 和干净 macOS 26/27 首装。旧 `365fdc4` ZIP 作为回退保留在同一内部草稿。[候选与回退 ZIP](https://github.com/haohongfei2001-png/nearpane/releases/tag/untagged-0d613209d89c24e3816f) · [包哈希](candidate.json) · [签名连续性](installation.json) · [正式权限](live.json) · [包内逐件检查](package-gate.json)
