# Nearpane — 工程实施路线与交付门槛

**状态：实施规划 · 非执行授权 · 0.1 · 2026-11-09**

## 1. 交付策略

采用阶段式工程路线。每一阶段必须有独立范围、验收收据、可回退边界和用户可理解的状态。不得把设计完成等同于实现完成，也不得在 Spaces 技术能力未证实前将其作为完整交付承诺。

## 2. 阶段总览

| 阶段 | 目标 | 主要交付 | 进入下一阶段的门槛 |
|---|---|---|---|
| P0 产品/设计冻结 | 形成一致的产品、架构、交互与视觉契约 | 本仓库设计文档、原型、资产索引 | 决策无冲突；文档校验通过 |
| P1 平台能力 Spike | 验证显示器、窗口、Spaces 的可观测与操作边界 | Spaces Adapter 原型、OS build 收据、能力矩阵 | 关键场景有证据；降级策略可工作 |
| P2 Nearpane Host Foundation | 建立常驻表面、布局、事件路由、模块注册表 | 独立 Host 工程骨架、模块契约 | 主表面稳定；模块故障隔离 |
| P3 First-party Integration | 集成 Saytile 与 Riftlet domain adapters | transcript surface、screenshot surface、权限与状态桥 | 不复制领域逻辑；既有产品契约通过 |
| P4 Desktop Orchestration | 实现 Space/窗口映射、点击切换与窗口激活 | 可操作真实 Spaces 预览 | 真实设备矩阵验证；无错误目标操作 |
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

尚未验证 Space 切换、窗口激活、separate-Spaces 开启配置、显示器插拔、镜像、Stage Manager、全屏过渡及跨版本兼容性。**P1 退出门槛尚未满足；P2 不因只读基线完成而自动获准。**

## 5. P2 — Host Foundation

实现边界：
- 一个主表面窗口及显示器位置管理；
- Surface layout composer；
- Module Registry / lifecycle；
- Interaction Router；
- Permission Broker；
- Event / snapshot bus；
- 故障隔离与诊断。

首个可运行里程碑只要求：
- 主表面尺寸、边缘位置、无标题结构稳定；
- 合成模块样例可启停、展开和收起；
- 模块异常不影响 Host；
- 配置持久化与恢复正确。

不要在此阶段引入截图采集、语音识别或 Spaces 私有 API 的生产实现。

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

- 先实现只读观察和统一快照；
- 其次实现 Space 行和真实窗口几何映射；
- 最后实现用户触发的 Space 切换和窗口激活；
- 每个动作都要求目标身份、能力状态和快照新鲜度；
- 私有适配器无法确认目标时禁用对应动作；
- 不把窗口像素捕获作为 Space 识别的前置依赖。

关键门槛：在单屏、双屏独立 Spaces 开/关、镜像、全屏、Stage Manager、显示器插拔等场景中，Space 和窗口目标不能错配。

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
- 每阶段独立提交、CI、真实设备收据和回滚点。
- 不允许把历史 44 项设计检查直接写成当前版本通过；保留历史记录，增量验证改动。
- 任何未经真实验证的能力标记 DESIGNED / NOT VALIDATED。

## 11. 发布门槛

V1 可以分层发布：
- **Core Surface**：主表面、Saytile、Riftlet 和安全的基础桌面观察。
- **Spaces Preview**：只有在具体 macOS 构建和设备矩阵达到门槛后启用完整预览。
- **Optional Modules**：按模块逐个发布，不要求所有模块同步成熟。
- **Advanced Orchestration**：更深层的 Spaces 控制或第三方扩展独立评估，不作为基础产品运行的前提。

**最终路线：先把 Nearpane 做成一个稳定、精致、可扩展的统一桌面交互层；再逐步把真实 Spaces 编排提升为可靠能力。任何一个系统 API 的不确定性都不应拖垮整款产品。**
