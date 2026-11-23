# StageGroup 窗口引擎实施与晋级顺序

产品使用单一工作组入口。组目录和原生 Space 归属分开记录。Rust 的复用范围见[复用裁决](NEARPANE-STAGE-MANAGER-REUSE-DECISION.md)，生产写入边界见[可见性架构](NEARPANE-WINDOW-VISIBILITY-FINAL-ARCHITECTURE.md)。本计划取代此前将两个后端共同晋级的 Gate 2。Spaces 迁移实验及 Mission Control 展示均退出同桌面单窗前置条件。[旧计划和验收历史](https://github.com/haohongfei2001-png/nearpane/blob/7d099c7/engineering/research/NEARPANE-STAGE-MANAGER-CODEX-INTEGRATION-PLAN.md)

| 阶段 | 修改范围与晋级条件 |
|---|---|
| 架构与权限 | 在产品选择、Swift 传输及 Rust 生产 ABI 拒绝改变原生桌面归属的写入。旧日志可解析；未交还的恢复责任继续阻止更换所有者。 |
| 同桌面单窗 | 从同一物理显示器的普通桌面开始。正式 Host 与独立观察器进行两次同焦点、同归属和 HID 检查。两款签名应用提供至少三扇窗，先登记全部，建立可在 Host 中断后继续履行的恢复责任，再对一个目标执行一次隐藏和恢复。 |
| 整组 | 单窗安全合同在指定构建取得独立实证后，正式侧栏在隔离资料运行一次 A→B→C→A。包括跨应用组合、同应用分别归组、组内精确键盘收件、旁窗不变、布局恢复、组合预览和用户中断。提交活动组须等待整组独立读回。 |
| 稳定性与生命周期 | 同一候选依序完成 10 次、50 次，另验退出、崩溃、睡眠、拔插、权限撤回与系统接管。任一安全项 FAIL 或 UNKNOWN 停止扩大试验，原所有者负责恢复可确认窗口。 |
| 性能及生产 | 在同机同负载比较 Apple Stage Manager，记录首帧、可输入、完整恢复、P50/P95/P99、掉帧、CPU、内存、WindowServer 和错误数。静态库、CI 或单窗试验只能证明相应阶段。公开分发另需验签、公证和干净安装。 |

## 模块和回滚

正式侧栏使用 StageGroupStore、StageGroupCoordinator、WindowIdentity 与原 AX/CG 见证。生产 Provider 资格由签名 Host 读取绑定环境的独立证据，Swift 编排单一事务，C ABI 同样拒绝无权写入。Corner Guardian 在首个写入前保留原 AX 对象并确认写前租约，独立验证 Host 已退出和后像相符才可恢复。无法验证时保留待恢复状态。

保护独立的同屏选窗、布局、组合预览及 R4 工具集成。退出窗口调度只归还 Nearpane 能确认的窗口。部署回滚须先核实已无租约、原配置指纹和标准安装签名；日常用户没有后端选择菜单。[唯一实施状态](../native-spaces/STATUS.md) · [逐项验收合同](../native-spaces/ACCEPTANCE.md) · [性能标准](NEARPANE-STAGEGROUP-PERFORMANCE-STANDARD.md)
