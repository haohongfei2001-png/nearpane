# 副屏 Native Spaces 续验 · 2026-11-12

起点为 `3d705103dbc0ef76a0d62d70778e586e7c58b318`，现场为 macOS 27.0（26A428）。副屏是旋转 90° 的 800 × 1280 显示器，UUID 为 `C92BDE5E-0D5D-4811-8EF2-04EE7B99A3A9`。本轮没有收到具体的无人使用起止时间。测试程序未签发现场操作许可，未修改个人资料。

## 设备裁决

| 核验对象 | 现场结果 |
|---|---|
| 已安装 P5.7 Reader 和原冻结见证 | 两个新鲜 revision 均读到主屏记录 1130、1309，副屏仅有当前记录 4297。原见证包 SHA-256 与 P5.7 交付收据一致。[双采样与签封预检](../../build/verification/native-continuation/2cf0c48c-ebd7-4da3-b3ad-a65ebfcbde56/live.json) |
| 记录类型、主副角色及顺序 | 21:29 独立读取得到非镜像主副屏和 separateSpaces=true。主屏有两个普通记录，副屏只有一个普通记录。主屏 current 从早先的 1309 变为 1130，期间本试验系统输入为 0。没有把这个变化计作测试动作。[独立读回](../../build/verification/native-continuation/ordinary-records.json) |
| 新冻结见证的 A/B 准入 | 同一副屏完整系统顺序中没有相邻的两个普通记录。建窗前拒绝，测试窗归属尚无现场见证。A→B→A 为 **0/3**，跨 Space 移窗为 **0**，产品空间行点击及拖放保持关闭。[设备收据](../../build/verification/native-continuation/final--check-console.json) |
| 全屏独立准入 | 21:56 最终见证取得 AX 权限、原前台窗口及可用于限时借焦点的对象，原焦点在主屏。副屏来源 4297 是普通记录。该结果允许在明确时段内继续做被动归还校准。实际焦点借用、校准、系统全屏进入/退出、原生浮层开合均为 **0 次**。全程测试窗口 **0 扇**。[焦点及归还对象收据](../../build/verification/native-continuation/final--check-fullscreen-console.json) |

已核对 Apple 提供的普通桌面创建操作需进入调度中心，在空间栏选取添加按钮。本轮范围内尚未证明该操作能仅改变副屏呈现，也没有在用户桌面上试开调度中心。可在单个已确认的副屏测试桌面上单独验全屏。[Apple 多空间指南](https://support.apple.com/zh-sg/guide/mac-help/mh14112/mac)

## 本轮解决的问题

1. 既有见证对主屏原焦点一律拒绝。现在可以在绑定本次会话、端点和时限的许可下登记原前台进程代际、保留 AX 窗口对象及原 frame，在副屏登记唯一自建测试窗。系统操作前先收起测试应用，被动核对原焦点确实回到同一窗口，再重新登记测试窗。试验结束独立核对窗口清理、原焦点和两个显示器的状态。代码只对自建窗请求激活。原窗口缺失、跨屏、变化或无法恢复时拒绝。源码提交 `9941c58`。[借用与归还](../../engineering/window-lab/Sources/NearpaneSpaceWitness/ConsoleFocusLoan.swift)
2. 校准前单靠副屏 scope 数量和记录索引，会把紧邻的全屏记录当成候选 B。冻结 Reader 现在把同一次稳定读取得到的普通记录类型交给见证和授权控制端，按原顺序检查两端均为该副屏的普通桌面。缺类型证据、当前记录非普通、第二个普通记录位于主屏或中间隔有全屏记录时拒绝。正式 Alpha 的普通读取协议未增加动作权限。源码提交 `3ab75a2`。[记录资格](../../engineering/window-lab/Sources/WindowLab/OrdinaryConsoleScope.swift)
3. 此前全屏见证会在系统进入后立即退出，P5.1 产品工具收据另用注入分类，两者无法证明同一次系统转场。组合入口 `--fullscreen-tools-console` 在真实进入后留出有界观察期。隔离 Host 用冻结 Reader 的新鲜样本和当前前台 AX/CG 复核驱动同一个正式浮层 presenter。外部控制器只能命中登记 Host 的指定控件。开启、关闭、文字与托盘状态、正常退出和普通面板恢复分别取证。独立全屏试验仍可直接返回。该路径尚未在真实全屏中执行。源码提交 `971ceaf`、`91d342b`。[系统见证](../../engineering/window-lab/Sources/NearpaneSpaceWitness/FullscreenToolHold.swift) · [Host 接线](../../Sources/NearpaneHost/EnrolledFullscreenFixture.swift) · [联合验收](../../scripts/acceptance/verify-native-fullscreen-overlay.py)

## 定向验证与可恢复的现场准备

| 项目 | 结果 |
|---|---|
| 实验组件 | Reader 4/4、WindowLab 19/19、检查点控制协议 13/13。冻结实验 Reader 和见证 Release 构建通过。[Reader](../../build/verification/native-tools-console/ordinary-reader-tests.log) · [WindowLab](../../build/verification/native-tools-console/ordinary-window-lab.log) · [协议](../../build/verification/native-tools-console/ordinary-python-tests.log) |
| 全屏联验组件 | Swift 定向测试 10/10、外部控制器 6/6。带真实样本入口的隔离 Alpha Release 构建、签名及资源校验通过。额外以只读会话的 UUID 调用控制器，实际在缺少限时许可时退出，Host 事件和 AX 操作意图均为零。[分类与状态机](../../build/verification/native-continuation/overlay/scoped-classifier.log) · [控制器](../../build/verification/native-continuation/overlay-controller/contract.log) · [真实无授权拒绝](../../build/verification/native-continuation/missing-consent.json) |
| 空资料会话 | `7d6e9df4-ce06-4f02-9927-696fbff21a1c` 已与隔离 Host 二进制、原验收脚本、资源和实际副屏 UUID 绑定。截图、录音、附件尝试、START 均为零。[准备收据](../../build/verification/native-continuation/overlay-controller/prepared.json) |
| 冻结与回退 | 独立试验 Host SHA-256 为 `6335bc65ae42e9f1fb7657aecf95ca5ea5cc2b860b0e4247f79e21b32973fd8e`，见证文件清单 SHA-256 为 `e06cfd8acaa5d18a5c7c0906815358bd7264ea402333a35471594a20212a96a7`。已保留可解包复核的见证和试验 Alpha。个人安装 P5.7 Host 仍为 `7f07b68da4bcf720545ee2ea63e4bccc722d0bf7249c93a1286fb4945a20a833`。未安装覆盖包或迁移用户资料。[二进制指纹及隔离路径](../../build/verification/native-continuation/ready/delivery.json) · [见证归档](../../build/verification/native-continuation/ready/SpaceWitness.zip) · [隔离 Alpha 归档](../../build/verification/native-continuation/ready/IsolatedFullscreenAlpha.zip) |

## 接续位置

取得明确的无人使用时段后，重新读取副屏当前 Space 和原焦点。若副屏仍只有已确认的普通测试来源，可先独立执行全屏及真实工具联验。启动冻结见证的组合入口，从其新运行私有目录取得当次 UUID。通过该包的 `space-checkpoint.py` 记录当次时段、来源及 `--fullscreen-only --observe-tools --allow-temporary-focus`，再让 `verify-native-fullscreen-overlay.py observe` 连接前述空资料会话。主屏 current、焦点、原窗几何或两屏拓扑有偏差即停。普通 Alpha 的实际全桌面识别仍需与隔离装配的现场结果分别记账。

两扇端点窗口分别在副屏相邻的两个普通桌面取得唯一 membership 后，按既有校准和三轮回程流程继续。按三轮稳定往返的独立读回裁决空间行点击。跨空间拖放另需窗口归属变化和恢复证据。
