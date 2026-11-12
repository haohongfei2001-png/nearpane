# 副屏调度中心的添加按钮与普通桌面验收

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
