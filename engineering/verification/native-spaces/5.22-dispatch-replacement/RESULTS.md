# 系统调度交接 · Nearpane 5.22（90）

完整替代系统调度仍未通过。正式候选的普通桌面选窗、跨 Space、系统调度中心、台前调度与原生 Split View 各自保留独立结论。[正式验收合同](../../../native-spaces/ACCEPTANCE.md)

| 验收对象 | 已取得的证据 |
| --- | --- |
| 第 18 轮延迟漂移 | 系统事件串起外部 Apple Event 激活 Codex、Dock 为窗口 42445 切到 Space 6。触发 Apple Event 的上游仍为 UNKNOWN。观察到前台变化后曾有 0.80 秒以上仍处于目标 Space。观察器跨动作独立记录的内容另存。[系统事件](../5.22-p0/post-reassessment/run18-system.json) · [观察器](../5.22-p0/post-reassessment/observer-isolated.json) |
| 本轮首次 P0 安装尝试 | BLOCKED。正式路径上的隔离诊断 Host 读到 26A428 禁止切换、迁窗。当前桌面 6 与既有租约 5095 不符，布置和产品输入都是 0 次，原焦点、普通桌面、台前调度和日常安装均恢复。未进入正式往返、10 次或 50 次。[数字收据](p0-origin-admission.json) |
| 苹果速度对照 | NOT_RUN。上次签名候选 `f7997a7` 的 10 次普通桌面选窗有原始按下、目标首帧和真实编辑器读回。以按下为起点，首帧 P95 为 207.96–234.81 ms。缺少同条件 Apple 样本。[逐项资格和原始样本](../5.22-90-sidebar-pair/apple-native-focus-reference/qualification.json) |

当前正式源码 `35eecd2` 的菜单在用户主动打开后才列出本屏真实空间，资格未通过的构建可浏览目录。常驻窗口区继续按当前 Space 和显示器过滤，在空桌面留白。系统接管时撤销待处理的窗口意图，并释放 Nearpane 注册的快捷键。以前已经投给系统的动作和未经实际硬件输入验证的系统入口须各自核验。
