# Nearpane — 整体产品架构与第一方集成方案

**状态：设计基线 / 非运行时实现**  
**版本：0.1 · 2026-11-08**  
**依赖：PRODUCT_DEFINITION.md、NEARPANE-VISUAL-AUTHORITY.md、MACOS-SPACES-FEASIBILITY.md**

## 1. 架构目标

Nearpane 不是 Saytile 与 Riftlet 的代码合并包，也不是把几个应用窗口塞进一个容器。它是一个新的 macOS 常驻桌面交互层：以真实桌面状态为基础，提供统一的边缘表面、模块编排、生命周期管理和跨模块交互。

架构必须同时满足：

- **统一外壳，保留能力自治**：Nearpane 管理桌面表面和模块编排；Saytile、Riftlet 保留其核心领域逻辑。
- **真实系统状态优先**：Spaces、显示器和窗口几何由 Desktop Orchestration 层观察，不由 UI 模拟。
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
│   │   ├── Spaces Adapter
│   │   ├── Window Observation
│   │   └── Switch / Activate Capability
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
- 状态：未启用/待命/正在识别/暂停/错误；
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
- Spaces Adapter：按技术裁决报告提供能力等级和证据来源。
- Window Observation：窗口几何、所属应用、层级、可见状态及 membership 置信度。
- Snapshot Reconciliation：将异步系统观察归并为一致快照，检测过期、过渡态和矛盾。
- User-triggered Actions：切换 Space、激活窗口；每个动作必须有明确目标和能力可用性，不能猜测。

所有窗口 frame 使用统一显示器坐标变换映射到缩略预览。窗口内容捕获是独立可选能力，不是窗口几何映射的必要条件。

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
| NP-ADR-008 | 可选模块扩展不能挤压或改变冻结的核心视觉比例 | ACCEPTED |
| NP-ADR-009 | 私有 Spaces API 隔离、版本化、可关闭且不可作为唯一依赖 | ACCEPTED |

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
