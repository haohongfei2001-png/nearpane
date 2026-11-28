# StageGroup 窗口引擎实施与晋级顺序

产品使用单一工作组入口。组目录和原生 Space 归属分开记录。Rust 的复用范围见[复用裁决](NEARPANE-STAGE-MANAGER-REUSE-DECISION.md)，生产写入边界见[可见性架构](NEARPANE-WINDOW-VISIBILITY-FINAL-ARCHITECTURE.md)。2026-11-25 起按 A、B、C 顺序实施和取证，取消历史上的双后端共同晋级要求。系统开关关闭记录为 A 的当次环境条件，覆盖该开关的证据与 A 能否完整支撑 R4 分别记录。[旧计划和验收历史](https://github.com/haohongfei2001-png/nearpane/blob/7d099c7/engineering/research/NEARPANE-STAGE-MANAGER-CODEX-INTEGRATION-PLAN.md)

| 阶段 | 修改范围与晋级条件 |
|---|---|
| A · 先验原生调度 | 已启用 Apple 台前调度的普通桌面上，正式 R4 读取本屏真实集合，点击后核对目标组与焦点；验证加入/移出、布局、原生边缘呼出及同屏是否出现两套交互。使用受控窗口分别执行黄色按钮、⌘M、批量最小化与还原；查验 Dock、输入接收、旁窗、应用隐藏及退出。AX 通知只触发新的系统集合读回。 |
| B · 隐藏私有 Space | 只有 A 的实测明确缺少产品所需能力时，验证 B 的已签名 Host、自有私有 Space 和普通窗口往返。核对原始身份与焦点、双向归属、鼠标键盘、旁窗、恢复责任和临时资源销毁；在操作中及完成后比较用户可见桌面的数量、次序和当前桌面。在目标 build 全部通过后方可用于产品。 |
| C · Corner | 仅在 A 和 B 均有明确不满足项时继续。从同屏普通桌面登记两款签名应用的目标及旁窗，先验证 Host 中断后的持久恢复责任。再执行一次真实退场、画面与按下/拖动/抬起、键盘、焦点及原始几何恢复。 |
| 整组 | 所用路线在指定构建取得独立实证后，正式侧栏在隔离资料运行一次 A→B→C→A。包括跨应用组合、同应用分别归组、组内精确键盘收件、旁窗不变、布局恢复、组合预览和用户中断。提交活动组须等待整组独立读回。 |
| 稳定性与生命周期 | 同一候选依序完成 10 次、50 次，另验退出、崩溃、睡眠、拔插、权限撤回与系统接管。任一安全项 FAIL 或 UNKNOWN 停止扩大试验，原所有者负责恢复可确认窗口。 |
| 性能及生产 | 在同机同负载比较 Apple Stage Manager，记录首帧、可输入、完整恢复、P50/P95/P99、掉帧、CPU、内存、WindowServer 和错误数。静态库、CI 或单窗试验只能证明相应阶段。公开分发另需验签、公证和干净安装。 |

## 模块和回滚

正式侧栏使用 StageGroupStore、StageGroupCoordinator、WindowIdentity 与原 AX/CG 见证。Apple 路线的临时系统镜像不落入第二套组目录。生产 Provider 资格由签名 Host 读取绑定环境的独立证据，Swift 编排单一事务，C ABI 同样拒绝无权写入。Corner Guardian 在首个写入前保留原 AX 对象并确认写前租约，独立验证 Host 已退出和后像相符才可恢复。无法验证时保留待恢复状态。

保护独立的同屏选窗、布局、组合预览及 R4 工具集成。退出窗口调度只归还 Nearpane 能确认的窗口。部署回滚须先核实已无租约、原配置指纹和标准安装签名；日常用户没有后端选择菜单。[唯一实施状态](../native-spaces/STATUS.md) · [逐项验收合同](../native-spaces/ACCEPTANCE.md) · [性能标准](NEARPANE-STAGEGROUP-PERFORMANCE-STANDARD.md)
