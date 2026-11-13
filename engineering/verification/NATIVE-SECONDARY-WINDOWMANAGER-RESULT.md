# 副屏调度中心的添加按钮与普通桌面验收

## 14:23 从已确认的当前桌面出发

14:20，两次零输入读取均确认副屏只有普通桌面 4568，主屏当前桌面为 1309。独立只读程序确认原焦点窗口 184630 属于主屏 1309。14:23:38 进入本轮授权时段后，再次在准备窗口之前核对了同一进程代际、同一窗口及其当前桌面。[开始前的双采样和焦点](../../build/verification/secondary-route-followup/a91671fb-66a3-4560-b183-0a08484c832c) · [限时验收原始记录](../../build/verification/secondary-route-followup/b1451ff8-7f39-4e28-a285-621a490f2ceb/observe.jsonl)

副屏合成窗口 193611 成功取得焦点，隐藏窗口的预演也成功归还了原焦点。打开调度中心后，系统再次给出可唯一归于副屏桌面栏的添加按钮。系统没有提供足以把某个窗口缩略图唯一关联到测试窗的 AX 证据，程序沿已登记的系统入口关闭概览。随后键盘焦点落到了登记范围外的进程；记录没有识别该进程，也没有对它采取动作。此轮可以排除“初始焦点属于非当前桌面”和“副屏测试窗未能取得焦点”两项原因。[焦点、添加控件及退出事件](../../build/verification/secondary-route-followup/b1451ff8-7f39-4e28-a285-621a490f2ceb/observe.jsonl)

**本轮添加桌面 0 次，普通桌面往返 0/3，跨空间移窗 0 次。** 14:24:25 两次独立读取均确认测试窗口已消失、概览已关闭、指针归位，两屏当前桌面保持为 1309 和 4568。原窗口仍在 1309，未取得键盘焦点。此次授权的桌面输入到此结束。[最终双采样](../../build/verification/secondary-route-followup/b1451ff8-7f39-4e28-a285-621a490f2ceb/postflight.jsonl) · [停止原因](../../build/verification/secondary-route-followup/b1451ff8-7f39-4e28-a285-621a490f2ceb/stopped.json)

本轮现场曾在副屏坐标 (−400, 44) 读到一个属于桌面列表的系统按钮。为避开概览退出后再次选择前台进程的问题，验收工具新增了选择已登记的当前副屏桌面 A 来关闭概览的路径。只在两次命中同一 AX 对象、核实副屏桌面栏、当前桌面和系统进程代际后尝试一次；没有使用该坐标发送点击。自行建 B 后还须证实 A 仍当前、桌面顺序为 [A, 本轮 B] 且 A 按钮仍是同一对象。此路径尚未在真实概览执行，焦点归还继续待验。[代码](../../scripts/acceptance/observe-secondary-space-controls.swift) · [12 项新离线检查及原夹具关联自检](../../build/verification/secondary-route-followup/b1451ff8-7f39-4e28-a285-621a490f2ceb/current-tile-tests.log)

最终签封的工具清单 SHA-256 为 `643944849c7a2c49a796c938cca210bbcac04aa24b54a274d799c9dc9ccf81fc`。Finder 启动器 SHA-256 为 `fe61ffec897d32cbcdbb191123ca43a274c03b16351729b277e65c8ab4c9caf7`，通过严格签名和无界面自检。监督程序 40 项及桌面拓扑 6 项回归均通过。成品仍为 P5.7；本次交付是只操作专用窗口和桌面的本机验收工具。[自动建 B 的本机验收入口](../../build/verification/finder-native-space/2fbd4c6b-de64-4b12-8887-cc4ff8fd4731) · [监督回归](../../build/verification/secondary-route-followup/b1451ff8-7f39-4e28-a285-621a490f2ceb/supervisor-tests.log) · [拓扑回归](../../build/verification/secondary-route-followup/b1451ff8-7f39-4e28-a285-621a490f2ceb/provision-tests.log)

## 13:20 副屏测试与焦点归属

**普通桌面往返 0/3，跨空间移窗 0 次。** 12:56 和本次启动前的 Reader 双采样均显示主屏当前为 1309、副屏仅有普通桌面 4568。13:20 在新授权的无人时段内实际创建了副屏窗口 193049。它通过了本进程 AX、CG、显示器和桌面核对，AppKit 请求后仍未取得前台或 key。程序在打开调度中心之前停止。创建桌面、删除桌面和方向输入均为零。[启动前双采样](../../build/verification/secondary-route-followup/1ef746d0-9d32-404c-aa08-4c1df777ee37/origin-2.json) · [实际窗口及退出过程](../../build/verification/secondary-route-followup/1ef746d0-9d32-404c-aa08-4c1df777ee37/observe.jsonl)

子进程退出时，独立观察器确认原 AX 窗口 185257 的身份、几何和键盘焦点。13:21:49 再次独立采样两次，测试窗口已消失，概览已关闭，两屏 current 未变。两次均读到 185257 归属主屏非当前桌面 1130，前台与指针已改变。此次没有借用指针。现场证据不能确定焦点何时、因何改变，也不能倒推出启动瞬间的窗口归属。至此已归还控制，本次不再派发桌面输入。[最终双采样](../../build/verification/secondary-route-followup/1ef746d0-9d32-404c-aa08-4c1df777ee37/postflight.jsonl)

据此修复了原焦点登记的缺口。控制器现在核对原窗口 AX/CG 所在显示器、该屏当前普通桌面和原窗口唯一 membership，在预演、概览清理及归还时复核。普通往返的监督器在启动见证程序前和签发操作许可前各核对一次，要求两个检查点的进程代际、窗口号、显示器和桌面一致。13:27 新工具实际只读确认当时前台窗口 184630 属于当前桌面 1309。此前 185257/1130 的反例纳入回归。[现场只读核对](../../build/verification/secondary-route-followup/1ef746d0-9d32-404c-aa08-4c1df777ee37/updated-readonly-gate.jsonl) · [焦点归属实现](../../scripts/acceptance/secondary-overview/FocusAnchor.swift) · [监督器](../../scripts/acceptance/secondary-overview/run-route.py)

概览退出另可识别系统按钮直接关联的本轮测试窗。仅在两次读取都唯一关联同一 AX 对象时尝试一次按压；已派发但结果不明时仅观察。没有这项正向关联时，保留原来核对受控概览后再关闭的路径。此次没有进入概览，实际系统是否提供这个关联仍待验。Finder 验收入口支持分别固定已知 A、B，既有桌面验收不会创建或删除桌面。目前交付的入口按副屏只有 4568 装配，使用真实概览预演、临时建 B 和清理路径。[控件关联](../../scripts/acceptance/observe-secondary-space-controls.swift) · [Finder 入口](../../build/verification/finder-native-space/69c5007d-5f33-403d-901c-83656990bbbc)

最终验收工具由本机 Swift 编译，六份工具指纹、实验应用和 Finder 入口签名通过；Finder 入口 SHA-256 为 `c164c082459ec2bc5d289e8ac67cb4d3a457194df94f4cc1905246b2e5660ca3`，工具清单为 `c08192bb2bf362a004cb90cb674e36f0a49e86aca659b7a1cc6d52de2a95405c`。离线通过监督与清理 40 项、桌面拓扑 6 项、授权检查点 14 项、Finder 路线及完成判定 21 项、焦点归属 12 项、原焦点所有权 6 项、控件和桌面顺序 50 项，以及控件关联自检。产品代码及 Alpha 未改动，已安装 P5.7 签名复验通过。[检查收据目录](../../build/verification/secondary-route-followup/d55504e8-31b9-48d8-bd19-24f3468d0f10) · [此前已通过的副屏全屏与工具开合](NATIVE-FULLSCREEN-OVERLAY-RESULT.md)

## 12:18–12:25 重连副屏实测

副屏“添加桌面”控件的归属已在 macOS 27.0 (26A428) 上取得系统证据。**两次退出概览的焦点归还结果分别为成功、失败。两次均在创建之前停止。** 主屏当前桌面为 1309，旋转副屏的唯一普通桌面为 4568。没有生成创建或删除意图，普通桌面往返 0/3，跨空间移窗 0 次。

| 北京时间 | 现场经过与核对 |
|---|---|
| 12:18 | 合成窗口 192680 取得副屏焦点，进入系统调度中心。WindowManager 给主屏和副屏发布了两个不同的 AX 按钮对象，副屏桌面栏在 (−800,0,800,40)，副屏按钮本身的 AX 框落在栏外。两次悬停后，通过系统入口关闭概览。独立观察器在子进程退出后确认原进程代际、窗口 184630 的同一 AX 对象与几何，指针也归位。此轮没取得按钮的物理命中。 [现场记录](../../build/verification/secondary-route-followup/67a57286-bb38-4533-9cf6-d589c7e87b31/observe.jsonl) · [两次事后读回](../../build/verification/secondary-route-followup/67a57286-bb38-4533-9cf6-d589c7e87b31/postflight.jsonl) |
| 12:25 | 使用修正后签封的控制器和新登记的合成窗口 192728。系统签名、主副屏 UUID、不同的显示器容器、不同的桌面栏和不同的添加按钮均得到核对，副屏栏内 (−400,20) 命中同一桌面栏两次，控件提供 AXPress。此处仅完成对象验证，实际派发次数为零。退出调度中心时，原窗口的 AX/CG 身份与几何完整，前台却已在登记范围外的另一进程。控制器关闭了自建窗口，监督器因精确焦点没有归还而停止。 [按钮、焦点与清理记录](../../build/verification/secondary-route-followup/eaa2e96c-e402-4a39-9b7f-fac3a300b6a4/observe.jsonl) |
| 12:25:39 | 独立只读程序连续两次核对两扇登记窗口均已消失，概览已关闭，指针回到起点 1 pt 以内。主屏普通桌面仍为 1130、1309，当前 1309；副屏仍只有 4568。原窗口仍属于 1309，两个采样点的前台进程及精确 AX 焦点都与原窗口不符。 [最终双采样](../../build/verification/secondary-route-followup/eaa2e96c-e402-4a39-9b7f-fac3a300b6a4/final-readback.jsonl) |

两个系统后台进程在这次会话中均未通过 AppKit 发布启动日期。现用内核提供的同一存活 PID 的启动时间验证代际；已在派发任何桌面动作前实际核对 WindowManager 和 Dock。副屏语义动作仅接受经过验证的控件对象，准备和执行前均须复查主屏的另一个对象；窗口清单、焦点、桌面占用及清理约束仍生效。焦点失败现在有独立于控件失败的原因记录。[控件识别](../../scripts/acceptance/observe-secondary-space-controls.swift) · [外部焦点观察](../../scripts/acceptance/secondary-overview/FocusReturn.swift)

验收工具的 113 项相关离线检查通过，6 个工具文件的 SHA-256 与清单一致，实验应用通过严格签名验证。实际用于第二次试验的清单 SHA-256 为 `6d088d4331c4fdfaa1971b62b21d4025398af6f63a3987a520a1844520bf8dd5`。没有改动 Host 或发布新 Alpha。 [校验与回归](../../build/verification/secondary-route-followup/eaa2e96c-e402-4a39-9b7f-fac3a300b6a4/final-helper-checks.log)

下一条有区别的验证路径，是在副屏**已经存在**相邻空白普通桌面 B 时，用现有相邻目标入口直接核对两端与回程，跳过借调度中心创建桌面这一步。当前 4568 尚无相邻普通桌面。真实切换、跨空间移窗继续关闭。

2026-11-13，北京时间。macOS 27.0（26A428），独立 Spaces 已开启。已在授权时段内实际打开调度中心，定位到 Apple WindowManager 提供的副屏桌面栏。**副屏普通桌面往返仍为 BLOCKED，完成 0/3 轮。** 系统报告的添加按钮位置落在副屏以外，五次准备过程均停在创建意图落盘之前。创建、删除、方向切换输入和跨空间移窗均为零。空间行点击和缩略图跨空间拖放继续关闭。[逐次输入与拒绝摘要](../../build/verification/secondary-route-followup/20261113-0442/result.json)

## 实机结果

主屏 current 为 1309。旋转 90° 的 800 × 1280 pt 副屏 current 为 4297，副屏可见的普通桌面记录只有 4297。本次获准临时将焦点借给副屏合成窗口，且允许调度中心暂时呈现主屏缩略图。每次都登记原焦点与测试窗身份，检查主屏桌面、窗口身份及其 AX 逻辑位置。没有向个人窗口发出布局或激活命令。[初始两次读取](../../build/verification/secondary-route-followup/bc118bc2-49f4-46b3-9b7c-e5467ef8b8ec/origin-2.json)

| 北京时间 | 实际操作与观察 |
|---|---|
| 04:44、04:46 | 两扇分别登记的测试窗先后借到副屏焦点。调度中心已打开，Dock 的 `mc` 容器未提供显示器子节点。第二次还在副屏桌面栏悬停。两次均在添加前停止。 |
| 04:50 | 通过运行进程的 Apple 代码签名确认 WindowManager 身份。系统 AX 树给出显示器 3 的 `mc.display → mc.spaces → mc.spaces.add`。悬停后桌面栏高度由 40 增至 170 pt。仍未取得属于副屏的按钮几何。退出时概览仍可见，原焦点也未立即恢复。 |
| 04:52 | 核对仍打开的是同一轮系统概览后，通过系统入口发送一次关闭请求。独立读回确认概览消失、两个 current 恢复、原窗口重新得到焦点。[关闭回执](../../build/verification/secondary-route-followup/ffe01db2-8449-4446-bd73-1b9f70c800fc/dismiss.log) · [归还读回](../../build/verification/secondary-route-followup/20261113-0442/interim.jsonl) |
| 04:53 | 第四扇测试窗未取得可见证的焦点，直接退出。这次未打开概览。 |
| 04:55 | 第五扇测试窗取得焦点。由系统 AX 树确认添加按钮归于副屏桌面栏，已启用并支持 `AXPress`。收起状态下，按钮的 `AXFrame` 和 `AXPosition` 加 `AXSize` 均给出 **(828.125, −32.5, 56.25, 90)**，副屏边界为 **(−800, 0, 800, 1280)**。控制器拒绝按下按钮，并关闭本次概览。独立观察器在子进程退出后确认原 AX 对象与原窗口几何。[末轮原始回执](../../build/verification/secondary-route-followup/bc118bc2-49f4-46b3-9b7c-e5467ef8b8ec/create.jsonl) |

这两种 AX 读法得出了相同数值。矛盾发生在按钮所处的系统层级与它报告的屏幕位置之间。现有证据不能判定系统采用了另一坐标空间、发生了动画变换，还是控件位置报告有误。

04:56:23 与 04:56:24 的独立读取均确认两个 current 为 1309、4297，调度中心已关闭，原前台进程代际和 AX 窗口号 184630 匹配。五扇登记窗全部消失，无法读取的登记窗为零。**鼠标指针没有回到原位置**；归还逻辑未在无法证明仍掌握指针时强制移回。最终核对只读。[最后两次系统快照](../../build/verification/secondary-route-followup/20261113-0442/final.jsonl)

## 已保存的修复与验证

- 控件发现支持已签名的 Apple WindowManager 以及 Dock。准备动作检查当前显示器、父子控件关系、可用动作与有效矩形。缺失、冲突或越出所属控件区域的矩形均拒绝输入。删除本轮新建 B 还须核对原桌面标签、两块桌面的顺序和占用状态。[控件与停手条件](../../scripts/acceptance/observe-secondary-space-controls.swift)
- 主屏临时呈现许可只在本次明确指定的截止时间内生效。窗口的原坐标、焦点和指针分别核对。关闭概览前检查仍是本次保留的系统控件。[现场控制器](../../scripts/acceptance/secondary-overview/main.swift) · [指针归还](../../scripts/acceptance/secondary-overview/route-pointer.swift)
- 修复了冻结见证器写出数字型起始 revision、字符串型终止 revision 时可能误拒有效回执的问题。清理前同时核对两笔外部方向校准，准备 B 时为三轮路线和独立清理预留时间。没有启动路线时，只有创建、焦点、指针和当前拓扑均有独立证明，才可尝试删除本轮 B。[验收监督器](../../scripts/acceptance/secondary-overview/run-route.py) · [回归用例](../../scripts/acceptance/test-secondary-route-cleanup.py)

本地源码提交 `34920bd277d07eda525826711dd10adfd11b4c63`。本次运行 70 项离线检查。监督与清理 21、许可检查点 13、双屏拓扑 5、方向校准回读 8、窗口占用 8、焦点所有权 6、系统控件几何 9，全部通过。[监督器](../../build/verification/secondary-route-followup/20261113-0442/route-tests.log) · [几何](../../build/verification/secondary-route-followup/20261113-0442/geometry-tests.log) · [校准](../../build/verification/secondary-route-followup/20261113-0442/calibration-tests.log)

末次**实际运行**的概览二进制 SHA-256 为 `883fdd4673b7f9945325ad7e0aa8f5efa6dafef5642a9c217972ac6bea6bb474`。收紧几何检查后重编的概览二进制为 `501e11b50a49abf7c3e45cbd0913f39ac15f4abf3ae835ea6a97fd1f4a1f9fd6`，仅执行了无界面检查。六个实验工具通过指纹核验，实验 App 通过严格签名验证。原始五份回执及最终快照的指纹已记录在忽略目录，汇总文件 SHA-256 为 `f649381f8ae0156e7b11d2b3f12ae5e57990ff72c50479789fe49e5c446ef6c4`。[工具指纹](../../build/verification/secondary-route-followup/20261113-0442/final-SHA256SUMS) · [签名核验](../../build/verification/secondary-route-followup/20261113-0442/kit-verify.log)

## 产品能力与接续条件

副屏自建窗口原生全屏、用户打开和收起语音工具、退出回到原桌面与普通面板已有独立现场通过记录。本轮仅修改验收工具和文档。已安装 P5.7 Alpha 通过严格签名核验，Host SHA-256 为 `7f07b68da4bcf720545ee2ea63e4bccc722d0bf7249c93a1286fb4945a20a833`。[全屏浮层现场记录](NATIVE-FULLSCREEN-OVERLAY-RESULT.md) · [当前 Alpha](</Users/hhf/Applications/Nearpane P5.7/Nearpane P5.7 Alpha.app>)

下一次有效的实机条件是副屏自身已有可识别的相邻空白普通 B，或取得能独立证明添加动作确实位于副屏的新证据。已有 B 时可直接从 A/B 身份及回程校准开始。空间行接入仍取决于三轮真实往返，跨空间拖窗另须证明单窗 membership 改变、兄弟窗口原位及可恢复。

## 第二次无人时段

2026-11-13 北京时间 05:20—05:34:45。两次冻结 Reader 读取均确认主屏 current 为 1309，副屏 current 为 4297，副屏只有这一个普通桌面。第一次使用的较早 Reader 缺少普通桌面分类字段，已舍弃其读数并按清单锁定 P5.7 Reader。[有效的两次读取](../../build/verification/secondary-control-identity/1D1B15B6-FC54-4BDA-89CD-4514A667A90F.json)

05:20 自建窗口 189180 获得副屏焦点并打开调度中心。桌面栏右上方的悬停交给已验证的 Apple 系统进程，栏仍高 40 pt。添加按钮的两种矩形读数仍为 (828.125, −32.5, 56.25, 90)，栏内的有界系统命中检查未能两次定位到同一个按钮。没有按下按钮。05:20:40 概览关闭，窗口消失，双屏 current、原焦点及指针均归还。[实机操作与外部读回](../../build/verification/secondary-route-followup/b470f15a-1656-465b-b242-697aaf8c9b25/create.jsonl)

随后改为先从中部展开栏，再在已确认的展开区域悬停右缘。05:23 系统仍报告有输入，未启动窗口。05:24 创建的窗口 189223 在借用指针前发现指针已变化，随即关闭，未打开概览。外部观察器确认子进程退出、原 AX 窗口与几何恢复；指针位置已与登记时不同。05:25—05:27 的只读等待共采样 60 次，最长一次报告空闲 14.9 秒，未达本次为避免干扰而设置的连续 30 秒，后续验收未启动。上述记录只能说明系统输入状态，不能判断是谁在使用电脑。[首次预检](../../build/verification/secondary-route-followup/c0f721e7-dbc8-454a-9baf-9272c320e45d/create.jsonl) · [指针变化前后](../../build/verification/secondary-route-followup/c183401d-6b49-41bb-9b46-e053741a055b/create.jsonl) · [只读等待](../../build/verification/secondary-control-identity/idle-dispatch.txt)

三个准备目录的动作日志均无创建意图，方向见证进程均未启动。**实际建 B 为 0，普通 A→B→A 为 0/3，跨空间移窗为 0。** 最新的“中部展开 → 右缘显现 → 精确按钮命中”路径未取得完整现场结果。若副屏已经有可见证的专用相邻 B，可直接走现有桌面的校准入口。此前的独立全屏和工具浮层结果继续有效。

实验源码提交 `4c8c02329af32eb3fd59168417e9410a30e2e11e`。当矩形不能定位时，新的检查要求副屏条内同一物理点两次命中已登记的同一 Apple 控件，并在输入前重新核对对象。只有语义控件获准才可派发动作。新控件命中 12 项、原几何 9 项、监督与清理 24 项、许可检查点 13 项、拓扑 5 项回归均通过。最终工具的六个二进制通过 SHA-256 清单核验，实验 App 通过严格签名核验。构建与这些离线检查均未给产品添加空间切换权限。[监督器用例结果](../../build/verification/secondary-control-identity/supervisor-regression.log) · [公开命中接口](https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition)
