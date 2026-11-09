# Nearpane — 工程实施路线与交付门槛

**状态：实施规划 · 非执行授权 · 0.2 · 2026-11-09（双模式增量）**

## 1. 交付策略

采用阶段式工程路线。每一阶段必须有独立范围、验收收据、可回退边界和用户可理解的状态。不得把设计完成等同于实现完成，也不得在 Spaces 技术能力未证实前将其作为完整交付承诺。

## 2. 阶段总览

| 阶段 | 目标 | 主要交付 | 进入下一阶段的门槛 |
|---|---|---|---|
| P0 产品/设计冻结 | 形成一致的产品、架构、交互与视觉契约 | 本仓库设计文档、原型、资产索引 | 决策无冲突；文档校验通过 |
| P1-Native 平台能力 Spike | 延续既有 macOS Spaces 只读基线、切换/激活验证 | Native Adapter 试验、OS build 收据 | 经验证的原生映射/动作与降级 |
| P1-Virtual（新增） | 验证逻辑 Workspace 调度、窗口停放/恢复和故障边界 | 隔离式 Virtual Spike、恢复收据、冲突/异常矩阵 | 安全启停、强退可恢复、无用户窗口丢失 |
| P2 Nearpane Host Foundation | 建立模式无关主表面、布局、事件路由、模块注册表与双模式 mock | 独立 Host 工程、统一 Workspace 契约 | 主表面稳定；两模式模拟态隔离且不调用生产写操作 |
| P3 First-party Integration | 集成 Saytile 与 Riftlet domain adapters | transcript surface、screenshot surface、权限与状态桥 | 不复制领域逻辑；既有产品契约通过 |
| P4 Desktop Orchestration | 分别实现经验证的 Native Spaces 与 Virtual Workspaces | 各模式独立验收、统一 UI、模式切换与恢复 | 两模式分别通过准入；未通过模式不得开放 |
| P5 Built-in Modules | 加入 AI、Notes、Tasks、Calendar、Clock、Weather | 内置模块和设置入口 | 权限隔离、状态、刷新和数据生命周期通过 |
| P6 Hardening & Distribution | 性能、隐私、稳定性、分发和迁移 | Release Candidate、诊断、签名/公证方案 | 长时间运行和升级/卸载验证通过 |

## 3. P0 — 产品与设计冻结

交付：
- PRODUCT_DEFINITION.md；
- NEARPANE-VISUAL-AUTHORITY.md；
- MACOS-SPACES-FEASIBILITY.md；
- NEARPANE-ARCHITECTURE.md；
- USER-MODULE-SYSTEM.md；
- INTERACTION-SPEC.md；
- 本路线图；
- 静态/交互原型、设计资源与 SHA-256 manifest。

验收：
- 产品定义、视觉权威、架构、交互之间无相互矛盾；
- 设计材料清楚标记合成数据，不冒充真实系统状态；
- 44 项历史原型检查只作为历史记录；若原型内容发生变化，只对变化影响的测试项做增量复核；
- 设计交付的文件、哈希、版本、提交 SHA 和远程分支可核验。

## 4. P1 — macOS 平台能力 Spike

仅验证必要能力，不提前搭建完整产品：
- Display topology 与坐标系；
- Window metadata、窗口 frame、层级、可见状态；
- Space inventory、display scope、window membership；
- Space 切换与窗口激活；
- Accessibility / Screen Recording 权限边界；
- macOS 版本、镜像、全屏、Stage Manager、显示器插拔等状态。

要求：
- 公开 API 路径与私有 API 路径分开报告；
- 私有 API 动态加载、版本白名单、能力探测、故障回退；
- 不请求无关权限，不采集窗口像素作为默认步骤；
- 原始证据和 SHA-256 随每次测试归档；
- 若 Space mapping 不可靠，先发布受限模式，不阻断 Saytile / Riftlet 和其他模块。

### P1 执行状态 — 2026-11-09

**当前状态：IN PROGRESS。** 已完成单台 Mac / 单个 macOS build 的只读基线探测，详见 `docs/engineering/P1-READONLY-BASELINE-20261109.md`。

已验证的范围仅包括公开显示器拓扑、显示器 UUID 对应、该构建上的 SkyLight 只读 Space inventory、当前可见窗口 membership 和坐标系差异。

尚未验证 Space 切换、窗口激活、separate-Spaces 开启配置、显示器插拔、镜像、Stage Manager、全屏过渡及跨版本兼容性。**P1-Native 退出门槛尚未满足。** 既有 P1 独立技术审查已允许使用 mock/fixture 的受限 P2 Host Foundation 与 P1 并行；这不授权真实 Spaces 控制。

### P1-Virtual（新增独立验证流，不重跑 P1-Native）

- 基于窗口真实身份和当前几何构造逻辑 Workspace 归属，不读取虚拟成员作为系统 Space。
- 验证窗口离屏停放/恢复或经比较确定的其他安全机制；屏外位置不得被当作可视布局。
- 使用无损测试窗口覆盖双显示器、旋转屏、非活动窗口、最小化/全屏、关闭与新建窗口、睡眠、重启、权限撤销与窗口管理器冲突。
- 必须证明因 crash/kill/强退造成的中间状态可恢复，且不挤占其他工具的窗口调度权。
- 在被授权并通过恢复证明前不得对用户真实工作窗口尝试虚拟模式切换。
- 独立保存脚本、原始与脱敏收据、SHA-256，结果不得与 Native PASS 混淆。

## 5. P2 — Host Foundation

实现边界：
- 用户指定一块显示器拥有的唯一全功能主表面（Saytile/Riftlet 仅一份）；
- 每块副显示器独立的 Space-only 呈现窗口（P2 仅 Mock/Fixture）；
- MultiDisplayPresentationCoordinator 与 WorkspaceModeCoordinator 分离：前者管理 per-display 布局/出现，后者管理全局 Native/Virtual 引擎；
- Surface layout composer；
- Module Registry / lifecycle；
- Interaction Router；
- Permission Broker；
- Event / snapshot bus；
- WorkspaceModeCoordinator 的接口及 Native / Virtual / Mock provider 契约；
- Native / Virtual 各自独立的模拟工作区身份、窗口状态、错误/恢复 fixtures；
- 单屏/双屏/三屏、90° 旋转、镜像、主屏拔插、屏幕重连，以及 separateSpaces=false 的空间归属未知 fixtures；
- 副屏按需（默认）/多目标自动/固定显示策略及不抢焦点的测试样例；
- 故障隔离与诊断。

首个可运行里程碑只要求：
- 主表面尺寸、边缘位置、无标题结构稳定；
- 主屏 Spaces 区可关闭且关闭后高度可收缩；每个副屏面板宽高、位置、Space 行密度独立配置；
- 合成模块样例可启停、展开和收起；
- 模块异常不影响 Host；
- 配置持久化与恢复正确。

不要在此阶段引入截图采集、语音识别、Spaces 私有 API 或虚拟窗口移动的生产实现。P2 先用 mock/fixture 验证两个模式共用一套 UI，不得提前调用真实用户窗口写操作。

## 6. P3 — Saytile / Riftlet 集成

### Saytile
- 明确模块接口与版本；
- transcript snapshot + incremental events；
- Ready / Listening / Paused / Error 状态映射；
- Start / pause / copy 命令；
- 音频和模型链留在 Saytile domain；
- 验证长时间识别、修订、文本保护、权限撤销、断连恢复。

### Riftlet
- screenshot queue snapshot + events；
- thumbnail reference 与受控文件访问；
- select / attach / retry / clear 等明确命令；
- 目标草稿身份和附件结果；
- 截图目录、上传、恢复留在 Riftlet domain；
- 验证队列持久性、目标变化、失败恢复和 no-auto-send。

两者不以复制源码或共享数据库实现集成。优先通过可测试的 domain package / framework 契约，必要时使用窄 IPC/XPC。

## 7. P4 — Desktop Orchestration

**双模式实现与验收必须独立：** Native 复用 P1-Native 通过的真实系统观察/操作；Virtual 复用 P1-Virtual 通过的窗口调度/回滚方案。UI、几何投影、操作路由共享，但原生 Space ID 与虚拟 Workspace ID 不可转换。只有两者各自通过时才向用户开放对应模式；用户在设置中切换，切换前校验和记录窗口恢复能力。

- 先实现只读观察和统一快照；
- 其次实现 Space 行和真实窗口几何映射；
- 最后实现用户触发的 Space 切换和窗口激活；
- 每个动作都要求目标身份、能力状态和快照新鲜度；
- 私有适配器无法确认目标时禁用对应动作；
- 不把窗口像素捕获作为 Space 识别的前置依赖。

关键门槛：在单屏、双屏独立 Spaces 开/关、镜像、全屏、Stage Manager、显示器插拔等场景中，Space 和窗口目标不能错配。副屏只能显示该屏可确认的 Native/Virtual 空间与窗口；不可将 3+1 scope 当成四个独立 Spaces。

## 8. P5 — Built-in Modules

建议交付顺序：
1. Notes / Clock：低权限、低依赖，验证模块契约；
2. Tasks：验证状态变化、提醒和可撤销动作；
3. Calendar：先只读，再按需写入；账户连接独立；
4. Weather：手动城市优先，位置授权可选；
5. AI Assistant：上下文默认空白，显式选择数据，所有外部动作可确认。

AI Assistant 不应成为 Nearpane 的默认主界面，也不能自动订阅麦克风或截图。

## 9. P6 — 产品化与分发

- 长时间驻留的 CPU、内存、能耗和唤醒频率；
- 副屏按需与多目标自动出现的触发/去抖、焦点不抢占、系统快捷键/热角冲突、独立配置恢复与全屏兼容；
- 多屏窗口预览限流，隐藏副屏不得持续高帧率捕获，Riftlet 主动截图不得明显受阻；
- 多显示器布局和睡眠/唤醒；
- 权限撤销、文件访问失效、账户离线；
- 崩溃隔离、日志脱敏、诊断导出；
- 安装、升级、迁移、卸载与残留数据说明；
- Developer ID 签名、公证、自动更新；
- Mac App Store 可行性与私有 API 风险独立评估。

不以“应用可以启动”作为发布验收。必须覆盖真实用户日常工作流。

## 10. 全局工程规则

- Nearpane 的所有实现工作先进入独立设计/实现分支，不直接写入正式 main。
- Saytile 和 Riftlet 的正式 main 保持不变；通过版本化契约或明确批准的只读依赖接入。
- 不直接共享两个产品的数据库。
- 所有跨模块调用显式、最小权限、可追踪。
- 系统私有 API 必须有公开 API fallback 和能力状态。
- 每阶段独立提交、CI、真实设备收据和回滚点；Native/Virtual 两套验收分别出具结果，不互相代替。
- 不允许把历史 44 项设计检查直接写成当前版本通过；保留历史记录，增量验证改动。
- 任何未经真实验证的能力标记 DESIGNED / NOT VALIDATED。

## 11. 发布门槛

V1 可以分层发布：
- **Core Surface**：主表面、Saytile、Riftlet 和安全的基础桌面观察。
- **Native Spaces Preview**：只有在具体 macOS 构建和设备矩阵达到门槛后启用完整预览。
- **Nearpane Virtual Workspaces**：产品正式目标，完成虚拟调度与强退恢复验证后可单独开放；不得用虚拟模式伪装成原生 Spaces。
- **Optional Modules**：按模块逐个发布，不要求所有模块同步成熟。
- **Advanced Orchestration**：更深层的 Spaces 控制或第三方扩展独立评估，不作为基础产品运行的前提。

**最终路线：先做一个稳定、模式无关的 Nearpane Host；Native Spaces 和 Nearpane Virtual Workspaces 作为两条独立验证与实施路线逐步交付。双模式是已确认的最终产品目标，但任何未验证功能都不得提前宣布可用。**
