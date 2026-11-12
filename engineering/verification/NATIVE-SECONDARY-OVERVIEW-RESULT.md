# 副屏调度中心与原桌面归还 · 2026-11-13

**副屏全屏工具已通过。普通桌面 A/B 切换仍未获准接入产品。** 本次在 macOS 27.0（26A428）上实际借用了副屏测试窗的焦点，尝试通过系统调度中心创建 B。最后一次尝试中，主屏原窗口的独立几何核对失配，控制器在添加按钮之前停止。创建、删除、普通桌面切换、跨空间移窗和向个人窗口写入均为零。副屏只有普通桌面 4297，主屏当前 1309。

## 现场时间线

以下为北京时间。每次临时窗均由新进程创建，绑定其 AX 标识、CG 窗口号、副屏 UUID、真实 frame 及唯一 membership。原焦点观察器不激活应用。两屏的 Reader 初始样本、系统操作、退出、错误和哈希均保存在 Git 忽略目录。[原始文件索引与 SHA-256](../../build/verification/secondary-route-followup/20261113-040753/live-receipts.json)

| 时间 | 实际动作与判定 |
|---|---|
| 04:17–04:19 | 第一次在测试窗隐藏再显示后比较了旧 AX 对象，第二次未能通过指针、活动屏与焦点的组合检查。这两次都停在系统概览之前。退出后外部观察器两次确认原焦点。第二次指针归还没有取得肯定收据。 |
| 04:24 | 窗口 188797 为副屏 key 窗，AX/CG 及 Space 4297 一致。指针连续两次位于该窗中心，Quartz 坐标 (-400,640)。窗口所属屏为 3、AppKit 发布的 main screen 却仍为 2。执行 Apple 调度中心程序后未辨认到唯一副屏添加控件。外部确认原 AX 窗口和原几何；后续只读观察未见概览。 |
| 04:27 | 窗口 188893 已登记。检测到借用之前指针位置改变，夹具退出，未定位指针或请求调度中心。原窗口再次通过退出后的焦点双采样。 |
| 04:28 | 物理输入静置后，窗口 188917 取得副屏焦点，预演被动归还成功，再次取得焦点并确认指针落在副屏。通过 Launch Services 打开系统调度中心后，受保护的主屏原窗口几何未能继续匹配。随即停止，未签发创建意图，未按添加按钮。该试次的记录不能区分瞬时不可读取和不同的 CG 呈现矩形，也不能确定概览具体在哪些屏幕呈现。 |
| 04:29:57–58 | 两次独立只读采样都确认原进程同一启动代际、实际前台 PID 与原窗口号 184630 匹配；五扇临时窗均已消失。两屏 ordinary 列表及 current 与初始一致，Dock 不再暴露概览组。末次试验退出当下未证实同一 AX 对象立即取得焦点，稍后两次确认的是同一进程代际和窗口号。指针未位于试验前记录位置，未强制挪动。 |

[04:24 系统尝试](../../build/verification/secondary-route-followup/d8709c2f-e379-43a3-81f8-941f68b011c9/create.jsonl) · [04:28 系统尝试及退出](../../build/verification/secondary-route-followup/966d2e5a-c4e4-459d-bc20-d86c38980615/create.jsonl) · [末次独立双采样](../../build/verification/secondary-route-followup/966d2e5a-c4e4-459d-bc20-d86c38980615/postflight.jsonl)

## 已落实的验收工具

- 由独立进程跨越测试窗生命周期保留原始 AX 对象并验证进程代际、窗口号、AX/CG frame 和焦点。测试窗重新显示后重新取得其 AX 对象，以窗口号、本次标识和归属验证连续性。[原焦点](../../scripts/acceptance/secondary-overview/FocusAnchor.swift) · [独立观察器](../../scripts/acceptance/secondary-overview/FocusReturn.swift)
- 副屏指针定位使用显示器局部坐标，读取真实落点。实际焦点归属使用测试窗的 key 状态和独立系统身份。试验结束后进一步收紧了物理鼠标输入及时间检查，并拆分保护窗口读回诊断；该最终构建仅做离线验证。[副屏夹具](../../scripts/acceptance/secondary-overview/main.swift) · [往返见证的指针归还](../../scripts/acceptance/secondary-overview/route-pointer.swift)
- 控件、占用与清理分别验证。创建需识别副屏系统控件；仅当原始意图、唯一新增 B、当前所属显示器、Dock 代际及其占用证据均匹配时，才能考虑撤销。未确认的系统输入不会触发重复按键。上一轮指针或焦点归还未被证明时，监督器拒绝再次打开概览做清理。本次未实际触发创建与撤销。[系统控件](../../scripts/acceptance/observe-secondary-space-controls.swift) · [只读归属](../../scripts/acceptance/secondary-occupancy.m) · [监督器](../../scripts/acceptance/secondary-overview/run-route.py)

## 验证与产品状态

离线通过 13 项许可检查点、5 项拓扑比对、8 项路线校准、8 项占用、6 项焦点所有权、9 项创建与持久收据，以及 12 项清理与拒绝分支。测试均未触发真实空间切换。最终实验包使用严格编译和临时签名。末次实机使用的概览执行文件 SHA-256 为 `4fe21bbde8d996955f97aa1897197a7daaf6c85dcf675ac6ba58a08ca5348c45`，其后仅编译的最终版为 `c2d16ea4f0b9dfca4ef7c73c37bdd63eb46cd020378d907e74bbc8d5adaac7f6`。[离线检查](../../build/verification/secondary-route-followup/offline-regression/checks.json) · [控件收据](../../build/verification/native-secondary-provision-controller/controls-tests.log) · [清理分支](../../build/verification/secondary-route-followup/offline-regression/replay-cleanup.log)

既有副屏真实全屏、主动打开和收起语音工具、退出全屏、正常面板及焦点恢复均保留其原结论。三轮普通桌面往返完成 **0/3**，跨空间移窗 **0 次**，产品空间行点击与缩略图跨空间拖放继续关闭。当前能缩小问题范围的现场条件是副屏本身已有可见证的相邻普通 B，在进入全局概览之前即可建立两端与回程。若原窗口呈现或目标归属失去证明，应继续停在系统输入前。[已通过的全屏结果](NATIVE-FULLSCREEN-OVERLAY-RESULT.md)

本次变更限于设备验收工具、测试和收据。已安装 P5.7 Alpha 严格签名检查通过，Host 可执行文件 SHA-256 为 `7f07b68da4bcf720545ee2ea63e4bccc722d0bf7249c93a1286fb4945a20a833`。产品源码、依赖锁和安装包没有变更，本次未重跑完整产品 Debug/Release 或生成替代 Alpha。
