# 正式安装候选 5.21（76）

验收主体为 Launch Services 正常启动的 `/Applications/Nearpane.app`。源码 `7f95f05e17f0715d1f6ac3a3505a486d5e32a083`，Host SHA-256 `ac403f4c620b5308791fe8fedf24278ca12263bf320d4dd4f1212016309700b7`。系统为 macOS 27.0 (26A428)，arm64，单个物理显示器。原始操作均由安装版的正式侧栏入口接收。

| 体验 | 真实结果 |
| --- | --- |
| 显示当前空间 | 独立 WindowServer 两次读回与侧栏四行身份一致（三个普通桌面、一个原生全屏）。当前行高亮与系统 current=6 一致。 |
| 空间切换与拖窗 | 运行中的 Host 报告辅助功能和屏幕录制均未授权。其签封后端已就绪，canSwitch=false、canMove=false。未在用户桌面发出空间动作。 |
| 精确点选输入 | 两次普通正式点击测试。单个合成文档和同应用双文档均被生产路径拒绝。两个动作都记录了 `selection refused: owner has no unique ordinary surface`。目标进程均未成为前台，AX focused window 均未到达目标，发送标记 0 次。 |
| 只读诊断 | 另起一份同型一窗夹具。AppKit 窗口号与唯一 AXStandardWindow 同为 25496。独立 CG 在同 PID 读到它和一个离屏 layer-0 表面 25497。前者 320×193 pt、可见、属于桌面 6；后者 500×500 pt、不可见、membership 返回空数组，AX 无对应。该证据仅说明按所有 layer-0 计数会拒绝这类单窗，未识别第二个表面的系统用途。 |
| 隐藏和恢复 | 正式菜单隐藏后第 2–62 秒的 7 次取样没有新增像素请求；无活动流、无处理中捕获，完毕恢复显示。Host 无录屏授权。 |
| 清理 | 所有本轮可控窗口均随其各自进程正常退出，独立 CG 查无遗留目标。原 foreground PID、AX focused window 与 Space 全部恢复。 |

[安装身份、权限与系统库存](single-window/manifest.json) · [单窗实际动作](single-window/actions.jsonl) · [双窗实际动作](controlled-window/actions.jsonl) · [受控进程的窗口表面诊断](../5.21-76-ordinary-window-inventory/actions.jsonl) · [隐藏开销](hidden-budget/actions.jsonl) · [正式侧栏当前行实拍](title-image/current-row-title.png)

S01 仅验证了现有桌面的行身份和高亮。受控三桌面、空桌面、50 次真实切换、跨空间输入、真实迁移、动效时序和多屏仍缺合格样本。W01 的受控输入子项实际失败；真实通用文档、Chromium 和 Electron 兼容性均未获证实。I01、N01 及整个专项保持 PARTIAL。
