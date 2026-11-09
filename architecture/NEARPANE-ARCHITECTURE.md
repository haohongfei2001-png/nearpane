# Nearpane — 整体产品架构与第一方集成方案

**状态：设计基线 / 非运行时实现**  
**版本：0.2 · 2026-11-09（双空间模式补充，不重新设计整体架构）**  
**依赖：PRODUCT_DEFINITION.md、NEARPANE-VISUAL-AUTHORITY.md、MACOS-SPACES-FEASIBILITY.md、ADR-010-DUAL-WORKSPACE-MODES.md**

## 1. 架构目标

Nearpane 不是 Saytile 与 Riftlet 的代码合并包，也不是把几个应用窗口塞进一个容器。它是一个新的 macOS 常驻桌面交互层：以真实桌面状态为基础，提供统一的边缘表面、模块编排、生命周期管理和跨模块交互。

架构必须同时满足：

- **统一外壳，保留能力自治**：Nearpane 管理桌面表面和模块编排；Saytile、Riftlet 保留其核心领域逻辑。
- **真实窗口与模式语义优先**：Native 观察系统 Spaces；Virtual 由 Nearpane 管理逻辑 Workspace。两种模式共用经验证的 WorkRect / ManagedWindowTiler，用**实际执行后的受管理窗口 frame**驱动预览，而不是 UI 假设。
- **第一方模块深度集成**：语音流与截图队列成为 Nearpane 原生组成部分，而非两个被嵌入的完整独立应用窗口。
- **模块可组合**：可选模块通过明确契约接入，不让每个新模块侵入主应用核心。
- **失败隔离**：Spaces、语音、截图或任意可选模块失败时，不得拖垮其他模块或整个桌面表面。
- **渐进交付**：先稳定统一外壳和第一方模块，再开放内置可选模块，最后评估外部扩展生态。

## 2. 系统分层

```
Nearpane App
├── Desktop Surface & Presentation
│   ├── Edge Surface / Window Lifecycle
│   ├── Layout Composer / Density & Overflow
│   ├── MultiDisplayPresentationCoordinator
│   ├── Interaction Router
│   └── Accessibility & Motion
│
├── Product Orchestration
│   ├── Module Registry & Lifecycle
│   ├── Module Placement / Pinning
│   ├── Permission & Data Boundaries
│   ├── Cross-module Action Broker
│   └── State Snapshot / Event Routing
│
├── Core Capability Domains
│   ├── Desktop Orchestration
│   │   ├── Display Topology
│   │   ├── Workspace Mode Coordinator
│   │   ├── NativeSpacesProvider / VirtualWorkspacesProvider
│   │   ├── Display & Window Identity / Geometry
│   │   ├── DesktopWorkArea / ReservedRegion
│   │   ├── ManagedWindowTiler & App Layout Profiles
│   │   ├── FullscreenTransitionCoordinator / Mini Floating Tools
│   │   ├── CrossDisplayTargetContext & Focus Restoration
│   │   ├── Snapshot Reconciliation
│   │   └── Mode-scoped Space Switch Capability
│   ├── Saytile Domain Adapter
│   │   ├── Capture & ASR pipeline (owned by Saytile)
│   │   ├── Single Transcript State
│   │   └── Copy / Ready / Listening / Paused
│   └── Riftlet Domain Adapter
│       ├── Screenshot Capture & Queue (owned by Riftlet)
│       ├── Thumbnail / Selection
│       ├── Attachment Target & Transfer
│       └── Recovery / No-auto-send guarantee
│
├── Built-in Optional Modules
│   ├── AI Assistant
│   ├── Notes
│   ├── Tasks
│   ├── Calendar
│   ├── Clock
│   └── Weather
│
└── Platform Services
    ├── macOS APIs / Permissions
    ├── Persistence & Secure Storage
    ├── Notifications / Background Refresh
    └── Diagnostics / Telemetry (privacy-minimal)
```

## 3. 关键边界：外壳拥有编排，模块拥有领域

| 责任 | Nearpane Host | 模块 / Domain |
|---|---|---|
| 主表面位置、宽度、材质、显示器归属 | 唯一所有者 | 不得独立创建竞争性常驻主面板 |
| 模块启停、固定、排序、折叠、布局槽位 | 唯一所有者 | 提供能力声明和偏好 |
| 模块内部业务状态 | 不复制、不重写 | 唯一所有者 |
| 麦克风、截图、日历等权限 | 统一授权入口与状态呈现 | 声明权限需求并执行领域操作 |
| 数据存储 | 提供隔离容器/密钥能力 | 负责自身数据模型和生命周期 |
| 跨模块动作 | 校验授权、路由动作 | 暴露显式动作，不直接读取其他模块私有状态 |
| 失败与恢复 | 隔离、状态呈现、重启策略 | 提供可恢复错误与幂等操作 |

Nearpane Host 不应维护第二份语音转写引擎、第二份截图队列或第二套上传状态机。它只维护足够驱动统一界面的领域状态投影，并由对应模块提供权威状态。

## 4. Saytile 集成策略

### 4.1 目标

Saytile 作为第一方 Voice Input Module 深度融入 Nearpane 主表面。用户感知的是一个连续、持续可见的文字流，而不是启动了另一个独立应用窗口。

### 4.2 保留的领域所有权

- 音频采集、音频生命周期、语言选择、ASR provider、GPT-6 修订、单一 transcript engine 由 Saytile 所有。
- 录音状态语义、候选版本保护、错误恢复、用户文本保护、隐私和 API 凭据由 Saytile 所有。
- Nearpane 不直接调用 ASR API，不持有供应商密钥，不复制音频缓存。
- Nearpane 仅订阅只读的 transcript snapshot / incremental update / capability state，并通过明确命令发出 start、pause/resume、copy 等用户动作。

### 4.3 界面契约

Nearpane Voice Surface 只需要：
- 当前唯一正式文字流（增量更新可合并，不展示多候选版本）；
- 主状态仅有三种：暂停、待命、正在识别。初始未启用时表现为暂停状态；错误与权限问题作为独立诊断提示，不增加第四种主状态；
- 单一状态按钮与复制动作；
- 麦克风授权及连接状态的必要反馈。

语音结束后进入待命，不把“说完一句话”解释为暂停。识别动态表现继承 Saytile 已确认的小竖条声波状态，不另造波形语言。

### 4.4 集成路径

优先将 Saytile 的核心能力抽离为可被 Nearpane Host 消费的模块化 domain package / framework 契约；短期若暂时不能安全抽离，则通过版本化进程间接口或内部模块边界接入。不得以把 Saytile 完整 App 窗口嵌入侧栏作为最终架构。

数据传输只包含 UI 必需的 transcript 增量和状态。录音 PCM、模型请求、密钥、完整诊断数据不经 Nearpane Host 中转，除非未来存在明确且经批准的技术理由。

## 5. Riftlet 集成策略

### 5.1 目标

Riftlet 成为 Nearpane 的 First-party Screenshot Module。用户从桌面捕获截图后，在侧栏缩略图托盘中管理和选择，再按既有流程附加到正确的目标草稿。

### 5.2 保留的领域所有权

- 系统截图捕获、截图目录授权、截图文件生命周期、队列、微图生成、附件传输、目标草稿识别、失败恢复由 Riftlet 所有。
- Nearpane 不创建第二个截图目录，不复制一套截图队列，不绕过 Riftlet 的授权和恢复逻辑。
- 附加成功只代表截图进入目标草稿；绝不自动发送。
- 清空待附加队列不能删除已附加文件或历史截图，遵守 Riftlet 正式契约。

### 5.3 界面契约

Nearpane Screenshot Surface 消费：
- 最近截图的稳定标识、缩略图、捕获时间和队列位置；
- 选择、附加、上传/处理、失败、重试等必要状态；
- 当前目标草稿的可确认身份；
- 队列容量和溢出状态。

侧栏呈现必须继承 Riftlet 已确认的托盘外观与交互规则。Nearpane 不自行重新解释点击附加、队列清空、失败重生或目标草稿变化。

### 5.4 集成路径

优先把截图队列和附件生命周期提炼为 Riftlet domain service，由 Nearpane 提供 UI adapter。若当前实现与主应用强耦合，则先建立窄的、版本化的本地 IPC / XPC 契约；不要直接复制内部实现，也不要把 UI 共享误认为领域逻辑共享。

截图文件引用应使用受控 file URL / bookmark 或等价授权句柄；不把图像二进制经过 Host 无意义地重复拷贝。Host 只持有展示与操作所需的最小元数据。

## 6. 桌面编排域

Desktop Orchestration 是 Nearpane 自身的核心领域，不属于 Saytile 或 Riftlet。

子域：
- Display Topology：显示器身份、排列、尺寸、方向、可用区域、镜像状态。
- NativeSpacesProvider：按 Spaces 技术裁决报告观察原生 Space，隔离私有接口并公开能力等级。
- VirtualWorkspacesProvider：管理逻辑 Workspace、窗口分配、目标可见布局、调度动作和崩溃恢复日志。
- Window Observation：窗口几何、所属应用、层级、可见状态及 membership 置信度。
- Snapshot Reconciliation：将异步系统观察归并为一致快照，检测过期、过渡态和矛盾。
- WorkspaceModeCoordinator：确保 Native/Virtual 互斥、preflight、事务式模式转换和失败回滚；原生 Space ID 不得与虚拟 Workspace ID 混用。
- Space Actions：预览**整行**作为一个 Space/Workspace 切换目标；不在缩略窗形状上设置独立激活动作。桌面真实窗口焦点通过系统行为/跨屏目标协调处理。
- DesktopWorkArea 与 ManagedWindowTiler：**所有非原生全屏状态**都维持按用户设置持续保留的 WorkRect（主屏出厂约 7/8），**不因 Nearpane 主界面/模块显示或隐藏**让普通主窗重新扩张收缩；只有真实窗口集合、用户布局/持久预留宽度及显示器几何变更触发重排。权限不足明确标记 unmanaged。
- FullscreenTransitionCoordinator：记录原 Space/Window/Display，区分真正原生全屏、默认退出恢复原空间与经验证后可用的独立 Space 选项；原生全屏隐藏空间面板。
- FloatingToolSurface：用户点击小状态条才打开精简工具，支持移动与审慎的 AX/鼠标热点避让，不重新复制 Saytile/Riftlet 领域服务。
- CrossDisplayTargetContext：维护发起/目标窗口、Space、显示器、快照 revision 与焦点恢复前提，避免跨屏截图附加/文字取用写到错误窗口。

受管理普通窗口的 frame 由 WorkRect 内真实执行的平铺产生，经过重新观察后才允许绘制“成功平铺”的缩略预览；不受管理系统窗单独表示能力缺口。Virtual 非活动窗口临时停放到屏幕外时，预览使用经确认的目标可见 frame。窗口内容捕获是独立可选能力，不是窗口几何映射的必要条件。

### 6.1 双模式 Workspace 契约（ADR-010）

对 Host 提供统一但带身份区分的 Workspace Snapshot：

- mode：native / virtual；两者属于不同身份命名空间，不能用数字顺序或原生 Space ID 互相映射。
- workspaceId：只在对应模式内有意义；Native 的 Space ID 属运行时短期标识；Virtual ID 由 Nearpane 管理持久化。
- displayIdentity：显示器身份、坐标系、镜像/旋转等实际硬件状态。
- windowReferences：可校验的进程/窗口身份及当前或目标可见几何，注明数据来源、时间、置信度和“已停放/不可控制/未知”。
- capabilityReport：按模式、OS build、权限、显示器和动作逐项声明能力，不可用则 fail closed。
- snapshotRevision / timestamp：支持旧快照拒绝、系统过渡状态和事件重取。

观察接口和写操作接口必须分离。Native 私有 SPI 与 Virtual 窗口操作不共用一个未经校验的“万能切换”实现；两者可以共享坐标变换、真实窗口身份验证、事件协议和 UI。

Virtual 所有写操作须先记录足以恢复的原状态、作用目标和执行进度，采用事务式完成/回滚；正常退出、强退、登录重启、显示器拔插和权限撤销时仍需提供恢复路径。若无法确定窗口目标或保证安全恢复，不得接管。发现另一个窗口管理器同时控制窗口时不得争夺窗口操作。

Saytile、Riftlet 与用户模块只依赖 Host 和明确的跨模块契约，不直接依赖 Native 或 Virtual；工作区模式转换不得中止录音、丢弃截图或自动发送。

### 6.2 多屏呈现与工作区引擎分离（ADR-011）

- **MultiDisplayPresentationCoordinator** 依显示器管理一个主驻留屏和各副屏的空间调度形态：副屏**默认 Docked**（持续预留独立 WorkRect，UI 隐藏仍不可被应用侵占），可选 **Floating**（无论显示与否都不预留，允许浮窗覆盖下方应用）。`panelVisiblePolicy` 与 `spacePanelPlacement` 必须为分开的状态维度；切换形态由用户设置显式触发单屏 WorkRect 调整。WorkspaceModeCoordinator 仍只负责 Native/Virtual 全局低频模式选择。
- **WorkspaceModeCoordinator** 仍然全局选择 Native 或 Virtual，属于**低频设置**，首次使用默认 Native 且无强制模式选择向导。各屏 Surface 从同一 Workspace Snapshot 和 Window Identity/Geometry 服务订阅数据，按已验证的 display association 过滤；副屏不私自枚举或执行另一套窗口调度。
- 唯一主表面承载 Saytile/Riftlet 及用户模块；副屏只具有空间调度界面，使用独立 AppKit presentation window，而非第二个 Host/ASR/截图队列。
- 主屏全模块默认约 1/8 宽、3/8 工具与 5/8 空间区；**只有不存在多空间/多普通窗口调度需求时**，空间区可不展示，界面可缩短，但持久 WorkRect 不变；副屏尺寸独立。
- 副屏默认按需出现，可选多目标自动、固定。不得抢当前 App 焦点；自动策略依经确认的可切换目标和稳定快照，避免重叠窗口/系统临时窗口误触发。
- 主屏断连仅迁移展示角色，保持领域服务不变；副屏断连保留偏好，旋转/镜像后重新计算几何和 Space/Workspace 归属；未验证时安全降级。
- 后台窗口预览资源应统一限流，副屏隐藏时不执行无必要的高频捕获，不降低 Riftlet 用户主动截图可用性。

本节为设计契约；不在此分支创建新运行时、schema 或修改现有 P2 代码。

### 6.3 精细 Layout Metrics（ADR-011）

- 统一 Layout Composer 管理分层的可编辑尺寸 token：每屏 panel 宽高、边缘偏移；Saytile、Riftlet、Spaces 和可选模块各自的高度与内部区尺寸；文字字号与行距、按钮/图标、缩略图、Space 行高、间距/内边距、圆角及其他可视度量。**禁止仅暴露总体缩放和少量粗档位来替代完整尺寸调整。**
- 初次使用加载视觉权威给定的默认 preset（主屏宽度约 1/8、分区约 3/8+5/8，以及各领域的确认尺寸）；用户在设置中精确输入、细步进微调并形成 override，不改变 preset 本身。支持预览、应用/取消、逐项/模块/显示器恢复默认。
- 每个尺寸 override 独立存储并以稳定显示器标识归属；修改一个值不得覆写其他自定义值。表示单位使用 macOS 逻辑 point 与明确的可选百分比，适配显示器缩放、旋转和可用区域；本轮不实施持久化 schema。
- 布局冲突要以滚动、分页、裁剪策略与明确反馈处理，不能无提示更改其他用户尺寸；界面尺寸受可用安全区域和基础可操作性的合理约束。
- **呈现设置与桌面占用必须分离**：修改显示器 Docked/Floating 形态或驻留保留宽度才改变 WorkRect 并可触发本屏窗口重排；仅调整缩略图/文字/按钮大小和 UI 显隐都不能修改普通应用 frame。所有切换保留用户自定义窗口布局和真实比例，禁用时安全恢复。

### 6.4 预留区域与自动平铺契约（ADR-012）

- **DesktopWorkArea**：依据该屏 `visibleFrame`、用户独立持久配置的 `spacePanelPlacement` 和 `reservedRegion` 计算 WorkRect。主/副屏 Docked 时即使 UI 完全隐藏也持续预留，副屏 Floating 时无论浮窗显示与否都不扣除区域。只有**用户显式调整占用形态/宽度**、真实成员/显示器变化或进入/退出真正原生全屏才按需重新计算，UI 隐藏不能产生窗口 frame 写操作。
- **ManagedWindowTiler / OverflowRouter**：按 `displayIdentity + modeScopedWorkspaceId` 以及 W1…Wn 的加入顺序管理普通主窗；**前 8 窗默认模板不变**（1 填满，2 各半，3 旧 W1/W2 右半区上下、新 W3 左半区，4 四分，5 旧 W1/W2 各 1/8、新 W5 占 1/4）。**8 是默认跨空间分流阈值，非硬上限**。设置支持 `overflowPolicy=createWorkspaceAboveThreshold`（默认，超额优先创建新合法 Workspace，若系统不支持则继续分割）和 `overflowPolicy=continuousSplit`（无限分割，不主动新建）；分割能力须遵守窗口实际最小尺寸/权限，16 也是示例而非限制。第三方 App 自行产生新窗采用同一策略，无法处理时保留可访问窗口并明确标记 overflow/unmanaged。
- **观察与写分离**：获取权限、确认目标身份/能力、记录可恢复原 frame、执行窗口 resize/move、重读观察并确认成功；未执行或失败的请求必须返回 degraded/unmanaged，不得用理想布局画成已生效。
- **FullscreenTransitionCoordinator**：系统原生全屏不使用 WorkRect 保留区，默认不显示完整侧栏和 Spaces。退出时尝试回到记录的源 Space/Workspace，并恢复普通平铺；“独立空间保留”是用户可选且需各模式、各系统 build 验证的 capability，不得直接宣称 Native 可以新建原生 Space。
- **Mini Status Strip / FloatingToolSurface**：仅用户可配置、可主动点击后展现的轻量工具。浮层能拖动、记忆 per-display 位置、尽可能避让下方可确认按钮区域；不可在全屏自动浮出完整工具或抢焦点。隐藏 UI、录音暂停和停止采集分属不同状态。
- **CrossDisplayTargetContext**：每次截图附加、文字复制/输入建立源/目标 app-window-display-space 与版本化绑定；对用户在操作期间的焦点变更作出尊重，确认后才恢复前台/提交附件，不自动发送。
- **冲突所有权**：Native/Virtual 模式、外部窗口管理工具和 macOS 系统平铺可能相互写 window frame；同一时刻仅由单一被授权编排者提交动作，冲突时停用写而非循环争抢。
- **单产品**：Nearpane 面向用户是一款完整产品，不分别出售必须购买的 Saytile、Riftlet 和 Spaces 入口；领域来源可以维持各自工程和数据契约。

此 ADR 在 P1/产品验收通过前不授权对真实用户工作窗口自动试验。

### 6.5 缩略窗口拖放、空间容量与 Presentational State（ADR-013）

- **WorkspaceWindowDropController**：空间行 click=切换整个 Space/Workspace；具体窗口缩略图 drag/drop=请求迁移成员；目标身份、source membership、OS capabilities、当前 `overflowPolicy`、版本与可恢复日志均须检查。UI hover 不执行窗口写操作。拖入已满默认阈值的空间不直接拒绝，而按模式尝试新建或在本空间继续分割，失败时安全保留来源窗口。
- **IncrementalTilingLayout**：提供基于 W1—W8 的稳定渐进分区、用户拖动真实窗口换槽位/调分割线的操作与当前空间/应用 profile 持久化。两窗口已自定义时加入 W3，仍先使用 W1/W2 右侧上下、W3 左半区的三窗默认布局；随后允许用户继续调整。
- **PresentationStateReducer**：输入实际 Space/Workspace 数量、受管理普通窗数量以及 Saytile/Riftlet 的展示需求，输出完整/仅语音/仅截图/仅空间/全部隐藏状态。若当前存在多个有效空间或多普通窗口，空间调度区不自动藏起；单空间单窗则可仅显示使用中的工具模块。**此状态机不得修改 WorkRect 或应用 window frame**。
- **Fullscreen FloatingToolPlacement**：位置稳定优先，上次用户拖放位置为主锚点，只在可确认按钮/系统安全区实际被遮挡时做最小必要移动；无确认依据时用户自行调整，禁止持续追随鼠标。
- **系统能力边界**：原生跨 Space 移窗和 Virtual 的窗口接管分别验收。无法保证目标 Space 的真实移动/最小尺寸/八窗容量时拒绝 drop 而不隐式新建 Space 或隐藏旧窗。

### 6.6 持久化布局历史与应用退出恢复（最新产品决定）

- 当前每个 Workspace 的 `layoutHistory` 按**真实参与窗口身份/集合、display、mode**保存用户曾明确调整的比例与槽位。新增第三个窗口仍执行标准三窗模板；三窗减至原来的两窗时，优先恢复与剩余窗口准确匹配的双窗历史，若没有历史，则采用默认 50:50；不允许用另一个同名/同 App 窗口的记录冒充。
- Nearpane 正常 **Quit** 时停止接受新的窗口编排事件，利用启用管理前记录的真实 App Window、display、Space 和 frame 日志执行尽可能可确认的安全恢复；释放 Docked 保留、恢复原生 macOS 窗口布局。**Hide/收起 UI 不释放也不恢复**。用户在接管后已经关闭/重新创建的窗口必须重新校验身份；部分失败明确报告，不执行猜测式操作。
- Native 超额新建原生 Space/跨 Space 移动**只在通过相应 build 的实际能力、安全回滚与授权后执行**；不能可靠新建则采用可行的连续分割回退，且不得通过私有接口试错或改 Mission Control。Virtual 由唯一调度引擎创建受控逻辑 Workspace。

## 7. 模块系统：Host 与 Module Contract

Nearpane 首版采用 **Built-in Module Registry + Declarative Module Manifest**，不直接开放任意第三方代码插件。

每个模块描述：
- module ID、版本、名称、图标资源；
- 类型（first-party / built-in / external-link）；
- 提供的 surfaces（compact / expanded / popover）；
- 生命周期能力（resident / on-demand / background refresh）；
- 权限声明；
- 数据类别和存储范围；
- 支持的动作与事件；
- 最低宿主版本、依赖和故障隔离策略。

模块不得自行创建主表面、修改全局布局、读取其他模块私有数据或绕过权限 broker。

## 8. 跨模块协作

通过 Cross-module Action Broker 传递显式、可审计的用户意图，例如：
- 从 Saytile 复制当前 transcript；
- 用户选择一段文本后发送给 AI Assistant；
- 用户明确选择截图并请求 AI 分析；
- 从 AI 生成任务草稿，用户确认后写入 Tasks。

不允许：
- 默认把麦克风内容持续发送给 AI Assistant；
- 默认把所有截图上传到云端；
- AI 自动发送消息、提交表单或附加截图；
- 一个模块未经授权读取另一个模块全部数据；
- 以“方便”为由将所有模块数据复制到统一数据库。

跨模块动作至少包含 source module、target module、action ID、用户触发上下文、数据引用/范围、权限判定和结果状态。

## 9. 状态与事件原则

- UI 使用模块发布的状态快照与事件增量；事件丢失后必须可重新获取完整快照。
- 所有异步事件携带 module ID、module instance ID、monotonic revision / sequence 和 timestamp。
- 过期事件不得覆盖新状态。
- 模块崩溃后 Host 仍可展示其他模块；恢复模块时重新同步快照。
- 权限撤销是运行时状态变化，不是启动时一次性判断。
- Host 不能把某个模块“无响应”解释为“无数据”。

## 10. 安全与隐私

权限按能力最小化并分离：
- Saytile：麦克风、必要的网络访问/用户配置的服务凭据。
- Riftlet：屏幕录制（若实际捕获方式需要）、截图目录访问、辅助功能/目标应用交互（按实际能力）。
- Calendar：日历访问或用户明确连接的日历服务。
- Weather：位置权限可选；默认允许手动城市。
- AI Assistant：仅对话所需数据；任何跨模块上下文必须由用户明确选择。

模块清单和权限请求分离。安装/启用模块不自动授予所有权限。密钥进入 Keychain 或等价安全存储，不进入模块 manifest、日志或普通偏好文件。

## 11. 架构决策记录

| ID | 决策 | 状态 |
|---|---|---|
| NP-ADR-001 | Nearpane 是统一桌面交互层，不是三个 App 的窗口拼装 | ACCEPTED |
| NP-ADR-002 | Host 管理外壳和编排，模块拥有领域逻辑 | ACCEPTED |
| NP-ADR-003 | Saytile 保留唯一 transcript pipeline 与音频生命周期 | ACCEPTED |
| NP-ADR-004 | Riftlet 保留截图队列、附件与恢复生命周期 | ACCEPTED |
| NP-ADR-005 | Desktop Orchestration 使用 Spaces Adapter 与 capability report | ACCEPTED |
| NP-ADR-006 | 首版使用内置模块注册表，不开放任意代码插件 | ACCEPTED |
| NP-ADR-007 | 跨模块数据只通过显式用户动作与 Action Broker | ACCEPTED |
| NP-ADR-008 | 默认尺寸不随模块变化自动压缩；用户可在设置中精细覆盖所有尺寸 preset | ACCEPTED（按 ADR-011 解释） |
| NP-ADR-009 | 私有 Spaces API 隔离、版本化、可关闭且不可作为唯一依赖 | ACCEPTED（Native） |
| NP-ADR-010 | 用户可选 Native Spaces / Nearpane Virtual Workspaces；同一时刻单一调度所有者，独立验证与恢复 | ACCEPTED（产品目标；技术未完成） |
| NP-ADR-011 | 唯一主驻留屏、各副屏 Space-only 面板、独立尺寸与出现策略 | ACCEPTED（产品目标；技术未完成） |
| NP-ADR-012 | 预留 WorkRect、普通窗口平铺、整行切换、全屏浮层、整体产品；窗口成员与 UI 显隐规则由 ADR-013 补充覆盖 | ACCEPTED（产品目标） |
| NP-ADR-013 | 最新容量与空间占用：8 是默认新建阈值、无限分割可选；副屏 Docked 默认保留/Floating 不保留；窗口移除恢复历史，Quit 安全恢复 | ACCEPTED（产品目标，技术须验证） |

## 12. 不在本轮实施的内容

本文件只定义产品和技术架构，不授权：
- 生产运行时代码整合；
- 数据库 schema / migration；
- 截图采集或目录授权改造；
- Thought Library runtime；
- Settings runtime；
- 合并 Saytile / Riftlet 实现分支；
- 改动三个仓库的正式 main。

**架构结论：Nearpane Host 是桌面交互与模块编排的统一所有者；Saytile、Riftlet 和可选模块是领域能力提供者。统一的是体验、布局、生命周期入口与显式协作契约，不是把所有领域逻辑和数据混成一套。**
