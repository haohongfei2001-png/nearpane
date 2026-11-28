# Nearpane 5.21（77）安装版实机验收

**专项判定 PARTIAL。** 运行主体为 `/Applications/Nearpane.app`，源码 `9239327abd17fac9a95cbcc833e6fc85aeac0cb4`，Host SHA-256 `ab1516441f142ad0fdf2c0ce994e681dfc4472d8b36e39d8b62e3bc6801cca19`。运行中的 CDHash `1b51fe43c6b75eda89b70d248089ceeaa54afe8d` 与磁盘签名匹配。

第一次预检发现安装成功但没有运行中的 Host，当轮未创建窗口或发起输入。随后通过 Launch Services 后台正常启动，独立绑定到唯一进程 PID 25310，原前台及 AX 焦点均保留。以下结果来自该次正常安装会话。 [无进程的首次预检](preflight/manifest.json) · [正常运行后的独立预检](installed-session/preflight/manifest.json)

| 项目 | 结果 |
| --- | --- |
| 当前桌面与侧栏 | 唯一显示器 1470 × 956 pt，当前是普通桌面 6。三条普通桌面及一条真实全屏记录与侧栏四行逐一吻合，当前行高亮与系统一致。未进入或退出私人全屏。 |
| 正式窗口选择及输入 | 单窗和双窗各有一次正式目标控件 AXPress。两次均未取得目标 key/main 和独立 AX 焦点，未发送标记。单窗生产日志明确拒绝源为不满足唯一普通窗口；双窗当次未取得相应分支日志。 |
| 系统授权与空间动作 | 安装 Host 自报辅助功能、屏幕录制均未授权，正式后端报告 ready=true、canSwitch=false、canMove=false。未替用观察器授权。受控桌面创建凭据缺失，S02/R01 已准备 0、已发送 0，未迁移或操作个人窗口。 |
| 标题像素证据 | 独立观察器在采集前将源限制在正式侧栏窗口的 60 × 17 pt 标题区，生成 120 × 34 像素真实截图。此图仅证明当前行显示。 |
| 隐藏与清理 | 正式菜单隐藏后第 2–62 秒 7 次采样均为零活动流、零新增捕获请求，最终恢复原显示。两次测试进程均正常退出，目标窗口号均查无残留；原前台、原 AX 焦点及 Space 均恢复。隐藏结果仅适用于本次无屏幕录制授权的状态。 |

[单窗实际动作](installed-session/single-window/actions.jsonl) · [双窗实际动作](installed-session/controlled-window/actions.jsonl) · [空间动作准入](installed-session/scope-preflight/results.json) · [隐藏计数与恢复](installed-session/hidden-budget/actions.jsonl) · [正式行预裁实拍](installed-session/title-image/current-row-title.png)

受控三桌面、空桌面、50 次选择、真实选窗输入、跨空间迁移、原生动画和物理双屏仍缺合格的最终安装版样本。已实现的防重放、身份复核及恢复测试属于自动化证据，不能替代这些现场结果。
