# Nearpane — 工程实施路线与交付门槛

**状态：目标工程路线与准入权威 · 2026-11-09 · ADR-013 已并入；不代表当前代码已实现**

> 当前工程实现状态以 [P4.1 准入报告](verification/P4.1-native-action-gate.md) 等实际收据为准。本文件定义后续实施的行为和通过条件，历史 Mock/P1/P2 的验证不得自动解释为符合 ADR-013。

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
| P4 Desktop Orchestration / Window Tiling | 分别实现经验证的 Native / Virtual + 普通 WorkRect 平铺与全屏恢复 | 两模式独立验收、主窗平铺、整行空间点击、可恢复全屏/浮层 | 按实际设备证明无重叠/不越界，未通过能力不得开放 |
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
- Space 切换的**整行目标**身份与焦点稳定性；
- 真实普通顶层窗口的 AX 身份、移动/调整大小可用性、最小宽高边界与 WorkRect 非重叠布局；
- 真正原生全屏进入/退出、源 Space 身份、全屏 mini tool 的窗口行为与可见性；
- Accessibility / Screen Recording 权限边界；
- macOS 版本、镜像、全屏、Stage Manager、显示器插拔等状态。

要求：
- 公开 API 路径与私有 API 路径分开报告；
- 私有 API 动态加载、版本白名单、能力探测、故障回退；
- 不请求无关权限，不采集窗口像素作为默认步骤；
- 原始证据和 SHA-256 随每次测试归档；
- 若 Space mapping 不可靠，先发布受限模式，不阻断 Saytile / Riftlet 和其他模块。

### P1 执行状态 — 2026-11-09

**P1 历史只读基线（2026-11-09，非当前工程进度）**：已完成单台 Mac / 单个 macOS build 的只读基线探测，详见 `engineering/P1-READONLY-BASELINE-20261109.md`。

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
- DesktopWorkArea / ManagedWindowTiler：验证主、副屏独立 Docked（隐藏仍永久保留）/Floating（显隐均不保留）；保留前 8 窗模板。超额策略为①默认 8 窗后优先合法新建 Space/Workspace、创建不可行时回退连续分割②设置选择无限分割；用合成 9/12/16/17 窗覆盖递归分割和最小尺寸冲突。
- FullscreenTransitionCoordinator：进入全屏隐藏 Spaces/释放 WorkRect、默认回源空间、可选独立空间（未验证标不可用）、小状态条主动展开可移动浮层；
- CrossDisplayTargetContext：来源/目标 display、原前台 app/window、workspace、revision、取消/完成后的焦点条件；
- 单屏/双屏/三屏、90° 旋转、镜像、主屏拔插、屏幕重连，以及 separateSpaces=false 的空间归属未知 fixtures；
- **每块副屏默认 Docked 持续预留独立区域**（即使 On-demand 暂时隐藏），用户可改 Floating 无预留；出现时机 On-demand/Auto/Pinned 是另一个维度。验证每屏独立切换占位形态时的单次窗口重排及显示/隐藏不重排、全屏当前屏例外。
- 故障隔离与诊断。

首个可运行里程碑只要求：
- 主表面尺寸、边缘位置、无标题结构稳定；
- 主屏有多空间/多受管理窗口时 Spaces 区必须可见；仅无调度需求时可省略 Space UI 并收缩界面高度，WorkRect 不变；各副屏面板宽高、位置、Space 行密度独立配置；
- 用 mock 验证全量可视尺寸的出厂 preset 与 Settings override 契约：主/副屏面板、各模块高度、文字、按钮、截图微图、空间行、间距/内边距与圆角等，且不修改生产 Settings runtime；
- 验证精确数值输入/细步进、修改单项不覆盖其他自定义尺寸、预览和分级恢复默认、极端尺寸组合下的滚动/安全区域/等比预览。
- 区分两类尺寸调节：① 完整侧栏边界调整会重新计算 WorkRect 并需要真实窗口编排；② 纯内部预览/控件尺寸改变不得移动系统窗。
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
- 空间预览**整行切换** Native Space 或 Virtual Workspace，不再把缩略图划成逐窗点击目标；
- 经实际授权验证前 1—8 窗渐进分区，并对**超额默认新建/能力不支持转连续分割/主动选择无限分割**分别验收。包含 Native 创建/跨 Space 移动能力门禁、Virtual 创建逻辑 Workspace、同 App 多窗、第三方 App 主动新开窗、极端 16+ 窗但不设硬上限，受限时不丢窗。
- 引入应用级窗口布局 profile（主窗/比例/优先位置），严格落实真实 frame 并在失败时退化标记，不能只画理想示意；
- 验证 fullscreen enter/exit、默认返回来源空间、可选独立 Space capability gate、全屏隐藏空间调度、状态条手动打开工具浮层；
- 支持跨屏发起/目标及焦点稳定恢复，不自动发送 Riftlet 附件；
- 每个动作都要求目标身份、能力状态和快照新鲜度；
- 私有适配器无法确认目标时禁用对应动作；
- 不把窗口像素捕获作为 Space 识别的前置依赖。

关键门槛：在单屏、双屏独立 Spaces 开/关、镜像、全屏、Stage Manager、显示器插拔等场景中，Space 和窗口目标不能错配。**受管理普通主窗不得重叠、出界或侵入完整侧栏预留区，未经系统写权限/真实动作验证不得宣称 PASS。**副屏只能显示该屏可确认的 Native/Virtual 空间与窗口；不可将 3+1 scope 当成四个独立 Spaces。

### P4 新增 ADR-013 增量必验（不用重审已通过领域模块）

- 使用合成 fixture 对 0—9/12/16/17 窗逐步加入、超过 8 窗默认新建、无法新建回退分割、无限分割设置、最小尺寸冲突和新窗来源一致性进行可复跑验证；前 1—8 模板及双窗→三窗行为维持原规格。
- 具体窗口缩略图从另一空间拖入目标空间；click 仅切整个空间，drag/drop 有明确不同的手势路径、身份/权限/版本/容量校验及失败回滚。
- 仅 Presentational State 的改变（完整 UI→只语音→全部隐藏→恢复）**不得改动持久 WorkRect 或普通窗口 frame**；真实原生全屏单独进入 100% 屏幕并恢复 7/8 工作区。
- 按真实窗口/空间数据控制空间调度呈现，多个有效空间/多个受管理窗口下不可因 UI auto-hide 规则把空间区藏掉；单空间单窗则可隐藏空间区但继续显示语音/截图。
- 浮层位置稳定不跳动，只有底层明确交互目标冲突才小幅避让；用户拖动后保持其新的位置。
- 原生/虚拟模式跨 Space 移窗分别通过真实 OS 能力验证后才能允许作用于用户工作窗口。

### P4 新增容量与退出验收（本次决策直接取代第九窗拒绝）

- 8 是默认跨空间新建阈值，不是硬上限；Native 无可信 Space 创建能力时必须回退在原 WorkRect 连续二分，绝不伪造新原生 Space。设置另有持续分割模式，无数量硬上限但需受制于实际窗口最小尺寸和系统能力。
- **第三方 App 自行新开第九窗**与缩略图拖入第九窗均执行同一策略；出现无法创建且无法继续分割的状态时保持原窗打开可访问、明确 unmanaged/overflow，不偷偷丢弃或移出屏幕。
- 主屏和每块副屏 Docked 无论显示、临时隐藏都持续预留，副屏改 Floating 后显隐都没有预留；切换占位形态只按用户设置触发真实单屏布局转换。
- 3→2 窗恢复与剩余窗口精确匹配的已保存双窗自定义比例/方位，没有历史则左右平分；普通 Quit Nearpane 停止接管、恢复原生系统窗口布局；Hide UI 不恢复。

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
- 副屏按需与经用户主动启用的多目标自动出现的触发/去抖、焦点不抢占、系统快捷键/热角冲突、独立配置恢复；全屏默认无空间调度；
- 主、副屏 Docked 持久 WorkRect 与 Floating 不预留；验证第三方普通窗口真实逐步平铺、8 窗阈值双扩容策略、非原生全屏不可侵入预留区、最小尺寸/系统弹窗降级，**Nearpane 真正 Quit 恢复原 macOS 布局，Hide 不恢复**，崩溃/卸载恢复日志。
- 全屏独立 Space 可用性、退出回来源空间、用户主动打开 mini status strip；浮层原位置优先、只对确认的按钮/安全区最小偏移，屏幕共享隐私；
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
- **Core Surface**：单一 Nearpane 产品主表面、Saytile、Riftlet 和安全的基础桌面观察，开发期多仓库不代表必须分开购买。
- **Native Spaces Preview**：只有在具体 macOS 构建和设备矩阵达到门槛后启用完整预览。
- **Nearpane Virtual Workspaces**：产品正式目标，完成虚拟调度与强退恢复验证后可单独开放；不得用虚拟模式伪装成原生 Spaces。
- **Optional Modules**：按模块逐个发布，不要求所有模块同步成熟。
- **Managed Tiling / Fullscreen**：普通主窗真正避让完整侧栏、无重叠平铺及全屏退出来源空间属于正式产品目标；只有取得真实系统能力、恢复与降级验收后才对用户启用，不能用“静态界面已设计”冒充完成。
- **Advanced Orchestration**：更深层的 Spaces 控制或第三方扩展独立评估，不作为基础产品运行的前提。

**最终路线：先把稳定、模式无关的 Host 与完整桌面的 WorkRect/平铺/全屏契约对齐；Native 和 Virtual 分别验证，首次使用默认 Native，模式只在设置中低频切换。Nearpane 是一个整体产品，尚未取得系统证据的窗口操作和全屏能力不得提前宣称可用。**
