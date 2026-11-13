# 当前显示器 Native Spaces 实机结果

2026-11-13，北京时间。普通桌面往返 **0/3**，跨空间移窗 **0 次**。空间行点击和窗口缩略图跨空间拖放继续关闭。副屏自建窗口全屏、语音工具浮层开合和退出此前已有实机结果。[全屏收据](NATIVE-FULLSCREEN-OVERLAY-RESULT.md)

## 实际执行与恢复

| 检查 | 现场结果 |
| --- | --- |
| 显示器与桌面 | 两次独立读取均为一块 1470×956 的显示器，旋转 0°，普通桌面从左至右为 1130、1309。1309 是当前桌面。 |
| 既有候选 1130 | 两次按窗口号读取，31 个对象未能排除，21 个位于零层，其中 18 个至少为 80×60 点。另有 8 个共享对象及 4 个桌面元素。窗口类型及具体内容未知。没有对 1130 发送切换输入。 |
| 系统动作 | 09:00:34 自建窗口 190838 出现，核对其归属和按窗口号登记的原焦点，预演被动归还后再次取得焦点。09:00:35 打开系统调度中心，随后在 Apple 的桌面栏中执行一次悬停。 |
| 临时桌面 | 系统桌面栏为 (0,0,1470,72)。WindowManager 向 AX 发布了启用的添加按钮及 AXPress，直接和分项框均约为 (1539.19,−0.5,138.39,90)。栏内命中检查没有定位到这个按钮。添加意图 0、添加执行 0、删除 0。 |
| 桌面与指针 | 控制器于 09:00:47 读回调度中心已关闭，指针回到登记点 1 pt 内。09:04:55 和 09:04:56 单屏观察器再次确认仍在 1309，完整桌面顺序相同，登记的测试窗口零残留。 |
| 键盘焦点 | 退出后原进程代际、原窗口及几何仍在。外部观察器未能验证原 AX 对象取得焦点。两次最终采样时前台进程与原进程不同，AX 未发布可读的焦点窗口。**焦点归还未通过。** 随后没有继续发系统输入或激活个人应用。 |

来源桌面由真实系统读取，目标的占用只记录脱敏计数。没有采集私人窗口像素或正文。[起始双采样](../../build/verification/secondary-control-identity/B2FB272B-795D-4D70-9D0D-0B00EB99DD02.json) · [目标窗口计数](../../build/verification/current-display-route/candidate-by-id.json) · [调度中心操作记录](../../build/verification/secondary-route-followup/b7f1194e-9f46-431f-bbac-eed3c9d961a1/create.jsonl) · [单屏最终读回](../../build/verification/current-display-route/postflight-current.jsonl)

## 实现与准入

单屏模式显式绑定显示器 UUID、当前普通桌面和完整桌面顺序。现有桌面要求空白见证。新建桌面要求在最右来源后仅追加一项，并由独立 Reader 读回，移除前还须逐窗证明不会搬迁任何未授权窗口。临时窗口、焦点和方向命令均在实验装配内核对。原有双屏模式保留独立准入条件。[监督器](../../scripts/acceptance/secondary-overview/run-route.py) · [占用检查](../../scripts/acceptance/secondary-occupancy.m) · [Reader](../../Sources/NearpaneDesktopReader/EnrolledRoute.swift)

现场还发现第二次悬停的预设 y=74 超出实际 72 pt 高的栏。修复后从系统栏实际边界计算两次悬停点，并核对目标点的归属。清理时若系统概览仍持有前台，工具会再次检查登记的自建窗口、AX/CG 几何和指针活动，然后仅尝试让该自建窗口取回焦点，再沿已预演的路径隐藏。两项修复均已编译，最终焦点读回失败后没有再运行现场动作。尚未证实按钮会随此次悬停显现，或该焦点处理能恢复现场。[概览控制器](../../scripts/acceptance/secondary-overview/main.swift) · [命中与几何](../../scripts/acceptance/observe-secondary-space-controls.swift)

下一次系统输入前，优先取得明确的原焦点返回路径。三轮切换还需要一个已经验证的相邻空白 B，或对本轮新建 B 的可定位系统按钮和移除路径取得证据。现有 1130 继续排除，跨空间移窗仍须独立取得成员关系和兄弟窗口的实机读回。

## 构建和回归

- 完整 Swift 集成回归 **310/310**，WindowLab **21/21**。首次在受限沙盒中运行时，系统粘贴板与测试图片解码未通过；在正常图形会话中使用同一套隔离测试全部通过。直接使用 SwiftPM 默认测试命令还遇到资源签名错误，正式结果取自仓库测试入口。[系统回归](../../build/verification/current-display-route/full-tests-console.log) · [WindowLab](../../build/verification/current-display-route/windowlab-tests.log)
- 监督和清理 26、桌面变更 6、许可检查点 14 项通过。物理命中和悬停 16、控件几何 9、桌面顺序 10、焦点所有权 6、占用 12 项通过。最终 6 个工具指纹及实验 App 签名均通过。[脚本回归](../../build/verification/current-display-route/offline-checks.log) · [占用](../../build/verification/current-display-route/occupancy-tests.log) · [最终工具](../../build/verification/current-display-route/final-helpers-check.log)
- Debug 和 Release 均构建并验证资源。Host SHA-256 分别为 `9d6de0b5fff3313cf8417dbbd0de053aa82d3d33f6d5968354abc55d77788b19` 和 `73781bfaeff19220df7c9ddd1a3672090c918af7d4224d1170553f9653ac218d`。固定 Saytile 93 个和 Riftlet 78 个文件通过离线核验。[Debug](../../build/verification/current-display-route/alpha-debug.log) · [Release](../../build/verification/current-display-route/alpha-release.log) · [固定依赖](../../build/verification/current-display-route/fixed-deps.log)
- 源码提交 `f9cdeb2839d3b600ca83bdaff1e1ad2ea002d4a3`。现场实际概览可执行文件 SHA-256 为 `625f4aa33e89fbf7ab50867e946e34b27acd42a9396ee39b4ab7e1e5d82b4c96`。已安装的 P5.7 Alpha 通过严格签名验证，Host SHA-256 为 `7f07b68da4bcf720545ee2ea63e4bccc722d0bf7249c93a1286fb4945a20a833`。本轮没有发布新 Alpha 或迁移用户资料。

## 09:17 后的只读复核与修复

09:17:51 和 09:17:52 的两次独立读取都找到了原进程代际及原窗口号，原窗口当时已重新取得键盘焦点。09:28 的两次读取仍在 1309，焦点已在其他进程。两次复核均未发出系统输入，概览已关闭，测试窗口零残留。这些较晚的观察无法确定上轮退出后是谁、通过什么动作恢复了焦点。上轮的即时归还结论仍为未通过。[09:28 复核](../../build/verification/current-display-return/independent-focus.jsonl)

已修正一个会影响实际归还的顺序差异。预演和退出现在都先隐藏登记的测试窗口及其应用，保留窗口对象，在原 AX 窗口和几何稳定 150 毫秒后关闭隐藏窗口。监督器新增独立的真实概览预演，须取得外部观察器的退出后焦点确认、指针返回、零窗口残留及零桌面变更。随后创建流程会核对同一原进程代际和窗口号。单屏清理入口只接受本轮新建桌面的收据，可以再次检查未确认动作、原始顺序和当前占用。[归还顺序](../../scripts/acceptance/secondary-overview/main.swift) · [监督与清理](../../scripts/acceptance/secondary-overview/run-route.py)

单显示器实验还可通过受控的辅助功能动作调用系统“添加桌面”按钮。若不能物理定位该按钮，须确认唯一未镜像显示器、已验签的进程代际、唯一且启用的按钮、所属桌面栏的实际屏内命中，以及系统提供的可见性信息。在动作发生前重新验证同一个控件；删除桌面仍须证明对应缩略图的实际位置。两种调用方式均须由系统记录证明新增的是唯一相邻普通桌面。此路径尚无现场创建回执。[实验实现](../../scripts/acceptance/observe-secondary-space-controls.swift) · [Apple AX 动作接口](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction)

本次变更限于验收工具。50 项控件及焦点离线检查、31 项监督回归、6 项桌面变更回归、14 项许可检查点通过；6 个冻结工具指纹和概览签名通过。见证清单 SHA-256 为 `41da648d2a7fc0c0d273a7105c92459d3932a5dd91455f6b4eee46cf369c32bb`，新概览工具清单为 `cfca743ea673efdf79923547af2e759a1dee36f56638efb05f4bca7b72118ee2`。命令行与 Finder 共用一个控制台锁，避免重复启动的验收程序同时派发输入。[本次检查](../../build/verification/current-display-return/checks.log) · [监督器最终回归](../../build/verification/current-display-return/route-tests-final.log)

现场未借用键盘时，准备了供本次开机使用的一次性 [Finder 验收入口](../../build/verification/finder-native-space/01fbc949-77f6-474a-8e84-96dde298dc03/开始原生桌面往返验收.app)。用户在 Finder 中双击后才开始计时，最多十分钟。它从实际双采样识别最右侧普通桌面，每次均核对冻结工具和脚本。结果输出到[同目录文本](../../build/verification/finder-native-space/01fbc949-77f6-474a-8e84-96dde298dc03/验收结果.txt)。入口是指向本机临时签封程序的链接；该临时目录清理或启动会话改变后须重新装配。最终入口可执行文件 SHA-256 为 `25bfc39f491f96773e41880055a7cc56298ea89f10ee7b217e5402d788acb4ab`。早期装配未能解析交付链接；修正后的入口通过严格签名及只读 `--verify-only` 自检。未触发真实双击、未请求新权限，Finder 启动下的实际权限边界及路线仍待验。[装配程序](../../scripts/acceptance/secondary-overview/build-finder-trial.py) · [最终自检](../../build/verification/current-display-return/finder-integrity.log)
