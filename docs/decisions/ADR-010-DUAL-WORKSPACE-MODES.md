# ADR-010 — 原生 Spaces / Nearpane Workspaces 双模式

**状态：ACCEPTED（产品决定）；工程尚未实现或完成验证**  
**日期：2026-11-09**  
**覆盖旧决定：** 原产品定义中“仅原生 Spaces、不创建虚拟桌面”的限制。  
**保留权威：** Saytile / Riftlet 领域语义、侧栏视觉比例、窗口几何真实性、权限与恢复要求。

## 1. 正式决定

Nearpane 最终支持两种由用户选择的空间模式，共用一套主表面、窗口预览、Saytile、Riftlet 与用户模块。

- **Native Spaces**：macOS 拥有 Space 身份、生命周期与原生切换；Nearpane 读取并操作真实 Spaces，不另建一套 Space。
- **Nearpane Workspaces（Virtual）**：Nearpane 拥有逻辑 Workspace 身份、窗口分组与切换调度；通过可恢复的窗口管理在现有 macOS 桌面上呈现不同工作区。虚拟 Workspace 不是原生 Space，也不会成为 Mission Control 的系统桌面。
- 两种模式的**窗口调度权互斥**；系统的 Spaces 功能可以继续存在，不要求关闭 SIP、关闭 Mission Control 或关闭“显示器使用单独的 Spaces”选项。
- 在独立设置里选模式；**默认 Native**，让现有窗口和原生桌面不被首次启动时重组。Virtual 只在用户明确启用、可恢复条件满足后接管。

这是一项长期正式产品承诺，不是“可选研究课题”。两种引擎可以分阶段完成与发布，不要求同日 GA，但不能因先发布 Native 而取消 Virtual 目标。

## 2. 视觉与交互保持不变

- 常驻侧栏约屏宽 1/8，无标题、Logo、Header；Saytile/Riftlet 约占纵向 3/8，空间区约占 5/8。
- **一行对应当前模式下的一个工作空间**：Native = 系统 Space；Virtual = Nearpane Workspace。不能用原生 Space ID 为虚拟工作区建档，也不能将虚拟工作区说成 macOS Space。
- 窗口必须保留真实身份和可靠的几何。Virtual 非活动窗口可能被移动到屏外：预览显示**已确认或保存的目标可见布局**，标明有效性/新鲜度，不把屏外停放点当作正常窗口坐标；如没有有效布局就标记未知，不捏造。
- 点击目标前检查模式、窗口身份、Space/Workspace 关系、快照版本、权限和动作支持情况；失败时 fail closed。
- 在主侧栏不增加创建/删除系统 Spaces 的操作。Virtual Workspace 创建、删除、排序放在独立设置；不强迫用户管理 Space 数量。

## 3. 安全模式切换

两套身份体系没有可靠的一对一关系，不能声称“一键无损转换”。

1. **Preflight**：检查其他窗口管理器竞争、权限、被接管的窗口范围、不可管理窗口、未完成截图/录音操作和恢复日志。
2. **用户确认**：展示真实受影响窗口与可逆性；未授权前不移动或隐藏用户现有窗口。
3. **切入 Virtual**：记录每个被调度窗口的原始显示器、可见位置及必要恢复信息；采用事务式切换与中途回滚，允许窗口管理失败时保留原样。
4. **切回 Native / 退出**：停止调度，依恢复日志恢复 Nearpane 曾移动/隐藏的窗口，验证用户仍能访问，之后才确认模式切换成功。
5. **异常恢复**：强退、系统杀进程、崩溃、重新登录、睡眠唤醒、权限撤销、显示器拔插、窗口进程重启时不得丢失恢复能力；若不能恢复，显式诊断且提供安全处置。
6. 不自动终止 Saytile 的识别、不破坏 Riftlet 截图队列、不自动发送内容、不关闭用户 App。

Virtual 不能假定所有系统/安全/全屏窗口都可移动；遇到系统限制、其他工具抢占或身份不明时应拒绝接管或有明确降级。

## 4. 架构决定

共用 Workspace Presentation & Interaction Contract，底层提供：

- **NativeSpacesProvider**：真实系统 Space、窗口归属与经验证的操作能力。
- **VirtualWorkspacesProvider**：逻辑 Workspace、窗口成员、目标可见布局、操作日志与恢复能力。
- **WorkspaceModeCoordinator**：当前模式、互斥、preflight、切换提交/回滚与恢复。
- **Display/Window Identity & Geometry Service**：模式无关的显示器、窗口身份和坐标变换。
- **CapabilityReport**：按 OS build、模式、权限、显示器与动作分别报告 supported/degraded/unavailable。
- Host 不直接调用私有 SkyLight 写操作或擅自重排窗口；两个 provider 均通过有证据的 Adapter 契约接入。

## 5. 分阶段实施与独立验证

- **P1-Native**：沿用已有 Spaces 只读基线及 P1 审查，不重新做已完成研究；继续验证 3+1 scope、切换、membership、坐标和窗口激活。
- **P1-Virtual**：新增隔离 Spike，针对虚拟窗口分组、非活动窗口停放、恢复、全屏/最小化、多显示器、其他管理器冲突及崩溃进行可重复的无损测试；不得直接在用户真实工作窗口上试错。
- **P2**：Host 与布局共用同一 Workspace Snapshot；Native/Virtual/Mock 三套适配器结构，仍只用 mock 数据推进基础工程。
- **P4**：两种引擎分别取得性能、准确性、故障恢复和权限验收，分别逐步开放；未完成的模式不可在设置中假装可用。
- **发布**：用户必须看得懂两种模式的区别；产品最终目标是两者可选，但不能将未验证能力标为完成。

## 6. 边界

本 ADR 只授权产品规范、架构及实施路线修订。不修改 Nearpane main、Saytile main、Riftlet main，不重写 P1 历史证据、不修改 P2 运行时代码，也不把双模式宣称为已实现。

**决定有效；技术可行性与用户级可靠性必须分别取证。**
