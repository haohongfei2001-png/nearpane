# 副屏普通桌面 A 的实机见证与 B 的创建门槛 · 2026-11-13

**结果：A 已见证；B 未创建；普通 A→B→A 为 0/3；跨空间移窗为 0。** 用户本次准许在 15 分钟内临时借焦点、创建并清理副屏测试桌面。03:55 第二个自建窗口的焦点检查失败，随即停止交互，提前归还电脑。没有打开调度中心、按方向键、点击添加或删除控件、切换任何一个普通桌面。此前[真实全屏及浮层开合](NATIVE-FULLSCREEN-OVERLAY-RESULT.md)的结论不变。

| 设备检查（北京时间） | 原始证据与结论 |
|---|---|
| 03:44，进入实验前 | macOS 27.0 (26A428)，两次新的冻结 Reader 观测：主屏普通记录 1130、1309（当前 1309），旋转 90° 的 800 × 1280 副屏仅 4297。两个显示器有各自的 Spaces。主屏记录不能当 B。[首次](../../build/verification/native-secondary-preparation/20261113-034442/0-scope-snapshot-1.json) · [第二次](../../build/verification/native-secondary-preparation/20261113-034442/1-scope-snapshot-1.json) |
| 03:47–03:48，进入条件 | 原 AX 焦点在主屏，有可验证的限时归还对象。系统 Dock 当时没有暴露调度中心 AX 组；没有在后台按坐标猜测“添加”按钮。[焦点](../../build/verification/native-secondary-preparation/20261113-034442/current-focus-gate.json) · [系统控件](../../build/verification/native-secondary-preparation/20261113-034442/dock-controls.json) |
| 03:51，自建副屏窗口 | 单扇窗口 188575 在副屏的全局 frame 是 (-681, 1034, 240, 160) pt。自建进程代际、AX、CG、owner frame 一致；revision 2、3 均给出唯一 membership 4297，窗口始终未成为 key/main。测试关闭它后同一原 AX 焦点仍在，WindowServer 确认该窗消失。该入口不允许 AX 平铺或其他写控制器命令。[首份读回](../../build/verification/native-secondary-preparation/passive/device-cl6jpn9s/native-gate-2.json) · [第二份](../../build/verification/native-secondary-preparation/passive/device-cl6jpn9s/native-gate-3.json) · [关闭与焦点](../../build/verification/native-secondary-preparation/passive/device-cl6jpn9s/events.jsonl) |
| 03:53，删除安全性调查 | 354 个系统窗口对象中，318 个未被公开 CG 标记为桌面元素；其中 258 个在此次双采样中没有可证明的 membership。数字不等于 258 扇用户窗口，也不能作为未来 B 有窗或没有窗的证据。现有按窗口查询不能独立批准删除。[仅计数调查](../../build/verification/native-secondary-preparation/20261113-034442/baseline-occupancy.json) |
| 03:54–03:55，尝试从自建前台窗进入系统概览 | 初次在创建可见窗口前拒绝；改为先初始化 AppKit 后，第二次在副屏真实创建窗口，确认其 AX/CG 和来源，再检查原焦点。此时无法确认仍是同一 AX 窗口，未到显式 activate、移动指针或打开调度中心。程序关闭自建窗并确认无残留、指针和两屏 scope 不变；该次原窗口的焦点归还检查为 **false**。不能凭这条日志断言具体是谁改变了焦点。[首次拒绝](../../build/verification/native-secondary-preparation/20261113-034442/overview-rehearsal.jsonl) · [停止与清理](../../build/verification/native-secondary-preparation/20261113-034442/overview-rehearsal-appkit.jsonl) |
| 停止交互后，独立只读检查 | 前台再次是第一项被动窗口试验所记录的应用进程，其 AX 焦点可读；两屏的显示器几何、普通桌面顺序和 current 与 03:44 基线相同。第二次试验没有在进程退出前落盘原窗口号，无法事后证明是同一窗口。没有尝试激活个人窗口来修正结果。[前台进程读回](../../build/verification/native-secondary-preparation/20261113-034442/after-passive-return-probe.json) · [两屏读回](../../build/verification/native-secondary-preparation/20261113-034442/after-scope-snapshot-1.json) |

## 保留的工程成果

- [副屏来源验证](../../scripts/acceptance/verify-window-management.py)复用已签封的夹具与外部控制器；`--suite passive-source` 只允许建/关自身一扇窗及读回，已在本机通过。
- [Dock 控件读取](../../scripts/acceptance/observe-secondary-space-controls.swift)只沿系统 Dock 的调度中心 → 指定显示器 → 空间栏分支查找，不查询私人窗口标题、正文或像素。Apple 确认从第二个显示器进入调度中心时，显示的是该显示器的窗口与空间；这不证明本次打开过副屏概览。[Apple 指南](https://support.apple.com/en-sg/guide/mac-help/mh35798/27/mac/27)；AX 标记参照 [Hammerspoon 的实现](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/spaces.lua)，现场仍须逐项核验。
- [限时概览试验](../../scripts/acceptance/secondary-overview/main.swift)在这次拒绝后补存原进程代际和窗口号；现在即使未显式激活，若夹具自己成为前台，清理也会收起自身并有界等候系统归还。该改动已编译，**未重新做可见试验**。[仅构建入口](../../scripts/acceptance/secondary-overview/build.sh)不会启动任何应用。实际运行旧试验包的 SHA 与最终源码分开记录。
- [新增/撤销的拓扑比对](../../scripts/acceptance/verify-secondary-provision.py)要求操作前后各有两次读回，副屏只增加一个邻接的普通记录，主屏完全不变；只能证明拓扑差异，不能单凭此证明是谁创建的、该空间为空或允许删除。[占用探针](../../scripts/acceptance/secondary-occupancy.m)对不完整的基线和归属返回拒绝。
- [校准控制器](../../scripts/acceptance/calibrate-secondary-route.swift)供未来已有 A、B 和可靠返回路径时使用。绑定冻结见证、本次许可、当前自建窗口和副屏，输入意图先落盘，输入后必须有独立目标读回及原见证的确认。**本次未发送校准键，也没有取得 Native 操作能力。**

[8 项校准读回测试](../../build/verification/native-secondary-preparation/20261113-034442/calibration-tests.log)、5 项拓扑比对、13 项既有许可检查点测试通过；两次真实来源读回另做了离线回放，5 种篡改条件全部被拒绝。[回归结果](../../build/verification/native-secondary-preparation/20261113-034442/offline-tests.json) · [现场包、已有 Alpha 和原始收据指纹](../../build/verification/native-secondary-preparation/20261113-034442/fingerprints.json)。[事后编译及签名核验的试验工具清单](../../build/verification/native-secondary-preparation/20261113-034442/final-tools.sha256)。本轮仅变更实验工具和收据，未重跑 P5.7 产品回归、未改正式 Host、未生成替代 Alpha。已安装 P5.7 Host SHA-256 仍为 `7f07b68da4bcf720545ee2ea63e4bccc722d0bf7249c93a1286fb4945a20a833`。

下一次进入条件是：保留原焦点对象的外部观察者能证明从副屏夹具借用并被动归还同一窗口，且能可靠撤销仅本次创建的空白 B；若 B 已经存在，则无须创建或删除。满足这两项之后，才有依据进行六个正式切换动作，继而判断是否可开放空间行。当前不开放行点击、跨空间拖窗或 Virtual 停放。
