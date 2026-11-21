# 系统调度交接 · Nearpane 5.22（90）

完整替代系统调度仍未通过。正式候选的普通桌面选窗、跨 Space、系统调度中心、台前调度与原生 Split View 各自保留独立结论。[正式验收合同](../../../native-spaces/ACCEPTANCE.md)

| 验收对象 | 已取得的证据 |
| --- | --- |
| 第 18 轮延迟漂移 | 系统事件串起外部 Apple Event 激活 Codex、Dock 为窗口 42445 切到 Space 6。触发 Apple Event 的上游仍为 UNKNOWN。观察到前台变化后曾有 0.80 秒以上仍处于目标 Space。观察器跨动作独立记录的内容另存。[系统事件](../5.22-p0/post-reassessment/run18-system.json) · [观察器](../5.22-p0/post-reassessment/observer-isolated.json) |
| 本轮首次 P0 安装尝试 | BLOCKED。正式路径上的隔离诊断 Host 读到 26A428 禁止切换、迁窗。当前桌面 6 与既有租约 5095 不符，布置和产品输入都是 0 次，原焦点、普通桌面、台前调度和日常安装均恢复。未进入正式往返、10 次或 50 次。[数字收据](p0-origin-admission.json) |
| 台前调度开启时的实机交接 | PASS。正式安装的签名 Host 在两次读回中均停止窗口调度、快捷键注册和缩略图捕获。独立进程实际注册并立即释放 Nearpane 自定义组合键 ⌃⌥⌘↑，两次系统调用均成功，全程没有发送按键。已读取签名 Dock 的普通列表。此项覆盖系统台前调度开启时的交还。[Host、系统和独立 Carbon 收据](installed-stage-and-admission.json) |
| 安装测试造成的前台变化 | 早期受保护交换只传入 Launch Services 的 `-g`。实际 Host 的打开事件为 `unmarked`，退出后原窗口焦点 UNKNOWN。此后已有新硬件输入，未执行旧意图。给新旧 Host 均传入已有的 `--background` 后，普通候选交换前后，原桌面 4 和原 AX 窗口连续两次读回相符。[首次拒绝](p0-visit-before-background-fix.json) · [后续只读检查](../5.22-p0/post-reassessment/p0-visit-closed-focus.json) · [修复后的恢复](installed-stage-and-admission.json) |
| 签名与新机器首次启动 | 私有 ZIP 中 13 个代码对象、18 个架构切片通过签名校验，GitHub 下载哈希一致。实体 macOS 27 与云端 macOS 26 均缺少公证票据。隔离解包的 b55ed96 原件双向签名与代码回退通过。[分发收据](../5.22-p6/integrated-35eecd2/draft-asset.json) · [实体](../5.22-p6/integrated-35eecd2/system-policy.json) · [云端](../5.22-p6/integrated-35eecd2/hosted-macos-26.json) · [旧包回退](../5.22-p6/integrated-35eecd2/archived-rollback.json) |
| 苹果速度对照 | NOT_RUN。上次签名候选 `f7997a7` 的 10 次普通桌面选窗有原始按下、目标首帧和真实编辑器读回。以按下为起点，首帧 P95 为 207.96–234.81 ms。缺少同条件 Apple 样本。[逐项资格和原始样本](../5.22-90-sidebar-pair/apple-native-focus-reference/qualification.json) |

当前正式源码 `35eecd2` 的菜单在用户主动打开后才列出本屏真实空间，资格未通过的构建可浏览目录。常驻窗口区继续按当前 Space 和显示器过滤，在空桌面留白。系统接管时撤销待处理的窗口意图，并释放 Nearpane 注册的快捷键。以前已经投给系统的动作和未经实际硬件输入验证的系统入口须各自核验。
