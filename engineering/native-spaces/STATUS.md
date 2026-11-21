# 当前安装与专项状态

## 2026-11-21 · 系统调度交接

5.22（90）签名候选 `35eecd2` 已在 macOS 27.0（26A428）验证台前调度开启时的快捷键交还。两次正式 Host 读回为零注册、零预览流，独立进程能实际取得并释放自定义组合键。修复安装脚本抢占前台后，原桌面和原窗口两次读回一致。本屏空间目录已接入正式菜单，当前构建保持只读。真实切换、迁窗、原生全屏 Split View、多屏与苹果同条件速度仍未通过。PR #15 保持 Draft。[实机逐项结果](../verification/native-spaces/5.22-dispatch-replacement/RESULTS.md) · [同包分发门槛](../verification/native-spaces/5.22-p6/integrated-35eecd2/hosted-macos-26.json) · [发布验收合同](ACCEPTANCE.md)

## 2026-11-21 · 同屏拖放与切窗

**当前签名候选 `f7997a7`，5.22（90）。** 在 macOS 27 正式安装路径，同一普通桌面里，两扇窗口向左或向右拖放分屏、拖回自身和不同应用间右拖均通过。最终槽位各为 615 × 923 点，两个系统来源连续两次读回一致。普通启动下十次鼠标选窗均命中目标编辑器，也均取得目标首帧。相较旧版 `d81c458`，松开至焦点的中位区间由 320–335 ms 降至 105–124 ms，至真实首帧由 358–378 ms 降至 139–159 ms。放手后首次确认双窗布局仍需 1.64–1.86 秒。日常安装 `d2d0bb6`、配置及原有台前调度状态已经恢复，`b55ed96` 回退存档原样保留。台前调度开启时由系统管理窗口。macOS 27 跨 Space 动作继续关闭，全屏 Split View、多屏、系统同条件性能及公证仍待通过。PR #15 保持 Draft。[正式验收、截图与视频](../verification/native-spaces/5.22-90-sidebar-pair/RESULTS.md) · [跨应用读回](../verification/native-spaces/5.22-90-sidebar-pair/final-cross/result.json) · [签名候选](../verification/native-spaces/5.22-p6/integrated-f7997a7/draft-asset.json)

该候选通过 628 项 Swift 测试、317 项 Python 验收测试及托管 macOS 26 原生 CI。云端重新下载的 ZIP 与实机候选哈希一致，13 个代码对象、18 个切片签名通过。两台系统均确认缺少公证票据。[本轮机器摘要](../verification/native-spaces/5.22-90-sidebar-pair/final-acceptance.json) · [云端同包验签与 Gatekeeper 结果](../verification/native-spaces/5.22-p6/integrated-f7997a7/hosted-macos-26.json)

### 早期迭代

签名候选 `d277a1c` 已在同一普通桌面完成双向卡片拖放及跨应用分屏。两款不同签名应用各开一扇窗口，一次右拖就将 A、B 分别放到右、左两个 615 × 923 点的槽位。在同一台 macOS 27 上各点十次，旧签名包 `d81c458` 从松开鼠标到实际屏幕呈现的区间中位数为 358–378 ms，`d277a1c` 为 300–320 ms，两批均为 10/10 次准确键盘输入。单屏普通桌面验收使用关闭台前调度的隔离时段，日常应用、用户配置与台前调度已恢复。后续实验 `d1e0361` 的第一次选窗和反向分屏失败，故保留 `d277a1c` 作为已验证候选。[候选比较与全部失败项](../verification/native-spaces/5.22-90-sidebar-pair/RESULTS.md) · [实机分屏短片](../verification/native-spaces/5.22-90-sidebar-pair/final-pair/right-drag-fixture-windows.mp4) · [跨应用原件](../verification/native-spaces/5.22-90-sidebar-pair/separate-applications/result.json)

签名候选 `203e34e` 在正式安装路径使用独立资料。对两扇已登记文档窗，自投保持原位，拖至另一卡右半及左半均通过，两次系统 AX 与 WindowServer 读回一致。桌面工作区为 1230 × 923 点，两个槽位分别为 615 × 923 点。右拖录像保留两窗从重叠到分屏的实际合成器画面，共 46 帧。正式鼠标交替选窗 10/10 次键盘输入落在目标编辑器。首次显示时延的读屏器在启流前因全屏库存检查拒绝了 10 次，此批的画面时延为 UNKNOWN。日常 App 与配置均已还原。[拖放收据与录像](../verification/native-spaces/5.22-90-sidebar-pair/binding-drag) · [鼠标与输入收据](../verification/native-spaces/5.22-90-sidebar-pair/binding-focus) · [内部签名候选](../verification/native-spaces/5.22-p6/integrated-203e34e/draft-asset.json)

## 2026-11-21 · 5.22（90）正式安装复核

PR #15 从原生 PR #14 的 `629524b` 继续，采用研究分支 `3151827` 三份决策及原生分支 `c1604f3` 的复核。可运行内部候选 `d81c458` 完成双窗正式验收，日常安装 `d2d0bb6` 及日常资料已原位恢复。`b55ed96` 原回退档通过 SHA-256 与双向签名核验。PR 保持 Draft。[候选与还原](../verification/native-spaces/5.22-p6/integrated-d81c458/protected-installation.json) · [回退](../verification/native-spaces/5.22-p6/integrated-d81c458/b55ed96-rollback.json)

| 阶段 | 实测与未通过项 |
|---|---|
| P0 | 第 18 轮的系统事件确认，外部 Apple Event 激活 Codex，随后 Dock 为该应用的窗口 42445 切到桌面 6。脚本上游未知。跨动作观察器两轮分别获得 171、136 个有效被动样本。专用签名 Host 以 nonce 从实际动作助手取回 `canSwitch=false, canMove=false`。借用已登记的相邻 5095/5094 时，第一次清点合格，约 418 ms 后第二次清点无法核对一个普通窗口条目。端点和条目身份保留 UNKNOWN，受控窗口 53833 在前后两次独立读回均归属 5095。布置快捷键和产品切换均为零。原桌面、焦点、Stage 和日常应用均恢复，两张既有测试桌面仍在。正式往返、10、50 均未执行。[隔离实机事件](../verification/native-spaces/5.22-p0/post-reassessment/isolated-97109f4/booked-adjacent.json) · [拒绝现场](../verification/native-spaces/5.22-p0/post-reassessment/isolated-97109f4/rejected-census.json) · [原始事件链](../verification/native-spaces/5.22-p0/post-reassessment/run18-system.json) · [被动观察](../verification/native-spaces/5.22-p0/post-reassessment/observer-isolated.json) |
| P1 | 已验证 Objective-C selector/IMP、真实方法签名、对象生命周期、窗口代际与迁移读回判据。实际投递迁窗 0 次。[非派发收据](../verification/native-spaces/5.22-p1-bridge/bridge-abi.json) |
| P2 | **最新正式安装候选 10/10**。此前候选 `0242247` 独立一轮也是 10/10。两轮均在同一注册签名应用的两扇窗口间交替。每次由生产侧栏发起，外部 AX、实际窗口号、AppKit 键窗和编辑器匹配，12 对按键只改动目标文件。第三按被拒的旧轮次保留。[十次动作和单窗实拍](../verification/native-spaces/5.22-90-active-display-previews/same-space-focus/registered-document-runs/09) · [此前失败](../verification/native-spaces/5.22-90-active-display-previews/same-space-focus/registered-document-runs/05-07.md) |
| P3 | 正式 Host 对已运行 Chrome 的非提示资格查询为 `notRequested`，没有已授权的隔离登录资料。真实草稿上传阻塞；读取标签、上传与发送均为零。[授权收据](../verification/native-spaces/5.22-p3/installed-946afb9/qualification.json) |
| P4 | 已证实真实 Services 回调与签名 Host 的入队和接收。系统在回调前 4.499 ms 为 Host 申请前台，来源窗口焦点保持失败。5 个独立像素样本核实了实际显示的系统语言包下载提示，本机英中翻译模型缺失。预置词条在两个独立签名 Host 的磁盘与设置页读回通过。三句中文各有干净与噪声样本，6/6 原始首尾音频完整。真实识别最终稿 0，60 次物理麦克风启动未测。[Services 系统时序及选区实拍](../verification/native-spaces/5.22-p4/installed-d81c458/README.md) · [词本](../verification/native-spaces/5.22-p4/installed-9ba33eb/seeded-wordbook.json) · [语音](../verification/native-spaces/5.22-p4/local-corpus/summary.json) |
| P5 | 37 项布局和生命周期用例、6 项性能数据核算用例通过。有一次实际全屏进出和隐藏一分钟后恢复。修复了旧预演的到期任务清除新预演的竞态，两项调度用例各复测 20 次。真实多屏、双窗 Split View、睡眠恢复及对标系统的完整性能仍待验。[P5 收据](../verification/native-spaces/5.22-p5/offline-qualification.json) · [竞态复现和修复](../verification/native-spaces/5.22-p5/lifecycle-scheduling.json) |
| P6 | 13 个代码对象、18 个架构切片分发签名通过。已为 Host 签入 Apple Events 和麦克风资源授权。在升级验证中，实际 Host 的辅助功能、录屏、事件投递三项均获准。GitHub Draft 候选下载哈希通过。实体 macOS 27 与托管 macOS 26 均因缺少公证票据拒绝放行，干净设备首启和 Sparkle 在线升级未验。[权限实测](../verification/native-spaces/5.22-p6/integrated-d81c458/host-permissions.json) · [候选](../verification/native-spaces/5.22-p6/integrated-d81c458/draft-asset.json) · [系统策略](../verification/native-spaces/5.22-p6/integrated-d81c458/system-policy.json) · [云端 macOS 26](../verification/native-spaces/5.22-p6/integrated-d81c458/hosted-macos-26.json) |

完整源码离线回归通过 592 项 Swift 测试及加载历史原件后的 269 项 Python 验收测试。分发签名和公证准备另有 9、10 项通过。[分阶段机器结果](../verification/native-spaces/5.22-p6/integrated-d81c458/acceptance.json)

## 既往安装记录

**此前 5.22（90）签名安装候选 `d2d0bb6`，PR #15 保持 Draft。** 两扇真实测试窗在四批正式 Host 实测中完成 48/48 次画面更新。5,708 帧合格侧栏采样都显示了对应色标。首次确认的呈现差为 P50 32.50 ms、P95 48.94 ms、最大 61.20 ms。30 帧完整双卡录像已逐像素验证。从同一侧栏帧读取五个独立应用的五张卡，六个状态下 30/30 项对应正确。三次 AppKit 所有者查询中断均在原有流上通过独立复核。当前安装版隐藏一分钟，7 次读回均为零条活动流，自动恢复后两张卡均继续交付画面。三项已有授权保留，系统仅登记正式安装。单屏桌面归属与台前调度交接已有实证，物理三指动画、双屏、双窗 Split View 和原生同条件延迟仍待验。P0 当前系统适配资格关闭，P1 迁窗 0 次，同应用受控编辑器两轮输入各 1/2，B 最后一批未读到可归属的 AppKit 按键。TextEdit 确认输入 0 个，公证待办。此前两张临时桌面尚未回收。[真实录像、机器收据和签名候选](../verification/native-spaces/5.22-90-active-display-previews/RESULTS.md)

**前一签名安装候选 5.22（90）`32b9f92`，PR #15 为 Draft。** 正式安装版三轮双文档画面更新共确认 36/36，各轮 P95 分别为 46.48、44.10、212.35 ms。第三轮有约 150 ms 的灰色画面，逐帧连续性仍未通过。未取得同条件的 Apple 基准。已有三项系统授权在更新后仍有效，原位安装与 ZIP 的 248 项逐一一致。已验证一次受控窗口真实全屏并正常返回。双窗 Split View、触控板动画与双物理显示器仍待实机证据。原桌面回收状态单列在本轮记录。[机器数据、原图和回退](../verification/native-spaces/5.22-90-active-display-previews/RESULTS.md)

**上一轮 5.22（90）签名安装候选 `f50d6ac`，PR #15 仍为 Draft。** 开启台前调度时，正式 Host 只显示 240 × 150 pt 的工具面板，窗口卡、活动流与新增帧均为 0。关闭后，在一块显示器上的两个受控普通桌面验证了有窗 A → 空 B → 原 A，卡片分别为 2 → 0 → 2。两张实际缩略图分别显示红、蓝测试文档。隐藏一分钟采集停止，恢复后读回两条流。三项权限在原安装路径上继承。与 Apple 原生缩略图同条件的延迟对照、调度中心动画期间的逐帧测量、两块物理显示器均待验。[本轮实拍、逐项结果和回退](../verification/native-spaces/5.22-90-active-display-previews/RESULTS.md)


**此前的 P0 回退候选，2026-11-20，5.22（90）。** 已用签名候选 `b55ed96` 原位换装。在 macOS 27.0（26A428）上，正式 Host 读回辅助功能、录屏与事件投递权限均为允许，跨桌面切换和迁窗能力均关闭，系统只登记一份 Nearpane。上一候选 `96a3e3d` 正式侧栏相邻往返 2/2 通过，一轮 10/10 的落点得到确认。新取证的单次切换 194 个显示呈现持续可见，但按压后约 2.38 秒前台离开目标进程，下一次按压前又发现活动桌面变化。原因未知，因此停止重复测试并撤销该构建的适配资格。两张临时桌面和窗口均已回收，日常配置恢复。该实验的原焦点未确认恢复。当前候选通过 539 项 Swift 测试，仍未公证。[实机证据、签名候选与回退](../verification/native-spaces/5.22-p0/RESULTS.md)

同一签名回退候选的双文档测试取得过 1 个正式侧栏 AXPress 回执，实际输入标记 0 个。修正验收器的 Apple 签名切片选择后，最后一次在会话条件变化时停止，期间探测到物理点击，保留了新焦点。所有临时桌面均已回收，日常配置读回一致。窗口区完整 0→2→0 与一分钟隐藏后自动恢复的实机证据来自此前 `96a3e3d`；当前包的独立空态截图因有其他窗口或输入中断而未通过。[输入与收尾](../verification/native-spaces/5.22-p0/quarantined-build-candidate/final-input-admission/admission-readback.json) · [已确认的窗口区实拍](../verification/native-spaces/5.22-p0/12-physical-probe/roster-serialized/results.json)

**此前的窗口区修复候选 5.22（90），源码 `365fdc4`，2026-11-20。** 工具下方只列已确认的应用窗口和显式组合。正式 Host 的同一窗口区实际经历 0→2→0 张卡，系统始终有 4 个 Space。空态前后实拍相同，桌面编号、全屏占位、空说明均为 0。完整空间、选窗和迁移专项仍未通过，PR #15 保持 Draft。[实机截图、逐点读回与签名候选](../verification/native-spaces/5.22-90-window-roster/RESULTS.md)

**此前的 5.22（90）合同复测，原生源码 `0777130`，2026-11-20。** 正式 Host 原位换装后继续持有辅助功能、屏幕录制和事件投递授权，系统选词服务仅由 `/Applications/Nearpane.app` 提供。三桌面合同为 0/50，另有 9 次正式行选择均未确认到达。双窗输入两次中一次符合预期；正式 Host 报告不可迁移。侧栏进入受控原生全屏、两句语音最终稿及隐藏后自动显示已实测。PR #15 保持 Draft。[完整验收、失败样本与候选](../verification/native-spaces/5.22-90-installed-contract/RESULTS.md)

**此前的权限迁移候选 5.22（91），2026-11-20。** 从 GitHub 下载后原位升级，系统只登记一份 Nearpane。Host 和七个权限助手与 90 双向验签通过。两条仅匹配旧构建的系统授权已清理，正式 Host 的辅助功能、录屏和事件投递仍未放行。侧栏 4 个 Space 与系统匹配，精确键盘聚焦、真实切换及迁移待验。[91 升级、权限与实机截图](../verification/native-spaces/5.22-91-permissions/RESULTS.md)

**历史安装版 5.22（90），2026-11-20，专项部分通过。** 正式侧栏与系统的 4 个 Space 及当前高亮一致。日常安装身份的辅助功能、事件投递、录屏均未获准，精确键盘聚焦、真实切换及迁窗仍待验。浅、深色下四处前景笔画已在同壁纸的两档玻璃设置间保持稳定。各项正式与隔离证据分别列出。[90 实机记录](../verification/native-spaces/5.22-90-r4/RESULTS.md) · [89 的首次校准、签名与失败项](../verification/native-spaces/5.22-89-r4/RESULTS.md)

**历史安装版 5.21（86），2026-11-19，专项 PARTIAL。** 在可取图的隔离视图中，有连续身份见证的一次台前调度往返保留了已标记的历史画面，返回后取得新内容。最终读取器另一次复测中，原身份短暂消失，卡片退为轮廓。正式安装版两项旧签名授权仍被系统拒绝；验收时系统观察器确认 6 扇普通窗口，正式侧栏 0 张，精确选窗 0 次。[86 实机与失败收据](../verification/native-spaces/5.21-86-window-recovery/RESULTS.md)

**历史安装版 5.21（85）** 的独立观察器确认本屏有 4 扇普通窗口，正式侧栏显示 0 张卡。系统明确拒绝将两项旧签名授权用于安装包。[85 结果与实拍](../verification/native-spaces/5.21-85-current-windows/RESULTS.md)

**历史安装版 5.21（82），2026-11-18。** 正式侧栏测得同屏 10 张卡片，纵向无重叠、无滚动。这项测量只验证排版。后续独立比对发现该版会显示已撤下的窗口。源码 `0558a2652b2d121cd99e57122f2988be9265212a`。[82 实机验收](../verification/native-spaces/5.21-82-window-access/RESULTS.md) · [80 历史结果与回退](../verification/native-spaces/5.21-80-current-screen/RESULTS.md)

在 build 86 的阶段范围内，桌面行导航和跨桌面拖放曾从正式侧栏撤出。已有独立窗口管理设置和历史工作包分别保留；打开逐窗列表不会发起布局事务。

## Build 78 及以前的历史验收

2026-11-18，专项 **PARTIAL**。当时的安装为 Nearpane 5.21（78），源码 `30831cf1e7faf1f22fdce32d3542e027fa918ffb`。78 已采用稳定开发者签名，并从实际运行的 Host 重新采样权限。以下 WP 表格沿用 77 的空间验收记录。其环境为 macOS 27.0（26A428），Apple Silicon，一块 1470 × 956 pt 显示器，独立 Spaces 关闭，台前调度开启，普通桌面 3 个，实际全屏 Space 1 个。[78 权限与安装收据](../verification/native-spaces/5.21-78-permissions/RESULTS.md) · [实现 PR #14](https://github.com/haohongfei2001-png/nearpane/pull/14) · [验收合同](ACCEPTANCE.md) · [原安装版基线](../verification/native-spaces/baseline-5.20-73/RESULTS.md)

| 工作包 | 实现及用户路径 | 安装版验证 |
| --- | --- | --- |
| WP1 空间切换 | 正式侧栏按显示器及真实 Space 身份导航。独立签封的动作进程核对权限、原始拓扑及每步意图，完成需窗口系统稳定回读。 | 普通桌面上四行逐项匹配，高亮一致。Host 报告可切换为 false，实际切换 0 次。 |
| WP2 空间地图与选窗 | 同一库存驱动空间地图和工具区下方的逐窗卡片。点击具体窗口时核对进程代际、原 AX 窗口、空间以及仍然有效的用户意图。选窗与取图分别判定权限。 | 一窗和同应用双窗各点击一次，均未取得精确键盘焦点，未输入标记。单窗夹具也产生了第二个离屏 CG 表面。 |
| WP3 迁窗及布局 | 拖放确认要求重查原 AX 窗口、同进程兄弟集合与 membership。迁移确认与目标分屏分开处理，未知回执暂停已管理窗口的写入。保留已授权的平铺、最小尺寸和双窗历史。创建能力缺失时保留分割或尺寸拒绝。 | 安装版可迁移为 false，跨 Space 迁窗 0 次。普通产品自动建删桌面尚未接通。完整占用证明缺失时保留来源桌面。 |
| WP4 系统组合与体验 | 后台采集有上限，允许保留已验证身份的历史图。独立的正常动效与减少动态效果路径，过期意图可中止。 | 一分钟隐藏采样零新增捕获，限于产品无录屏权限的状态。未取得可评价的切换录像、延时与稳态内存数据，缺第二块物理显示器。 |
| WP5 交付 | 统一安装位置、正常 Launch Services 启动，源码版本、Host/helper 身份和回退档均有收据。 | 构建、验签、解包回读通过。核心安装验收仍有未通过项；PR 保持草稿。 |

## 5.21（77）现场结论与本轮接续

当时正式安装进程的辅助功能、屏幕录制均未授权。负责取证的独立进程有自己的权限。只对本次创建的测试窗口投递正式侧栏点击，未将现有三个桌面认作专用 A/B/C。两次选窗后均验证了原桌面、前台、焦点及测试窗口清理。[最终安装版取证](../verification/native-spaces/5.21-77-final/RESULTS.md) · [完整矩阵、安装包与回退](../verification/native-spaces/5.21-77-delivery/RESULTS.md)

此前记录中的系统授权现已在正式 Host 读回为允许。复测从正式侧栏发起。先运行 `scripts/acceptance/native-spaces/run.sh preflight build/verification/ns12-next-preflight`（使用新的输出目录）核对实际 Host 的能力，再建立并清理可确认归属的临时桌面并执行受控输入。单屏场景可独立继续。M01 另需第二块物理显示器及对应的登录会话设置。[验收入口](../../scripts/acceptance/native-spaces/README.md)

5.20 的同一桌面跨应用双窗平分与恢复保留其原验证范围，最大几何误差为 0 pt。该结果没有纳入 5.21 跨桌面成功计数。[5.20 实机记录](../verification/P5.20-DESKTOP-OVERVIEW-AND-AUTO-TILING.md)
