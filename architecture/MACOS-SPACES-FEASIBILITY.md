# macOS Spaces 技术可行性与证据边界

**状态：架构裁决草案 / 证据分级版**  
**日期：2026-11-08**  
**范围：Nearpane 对真实 macOS Spaces、显示器与窗口的只读观察和用户触发操作。**

## 1. 执行摘要

Nearpane 可以把真实 Spaces 与窗口编排作为产品核心，但必须把系统能力分成三个问题：

1. **显示器拓扑与几何**：公开 API 能够可靠取得当前连接的显示器、显示模式、坐标边界和窗口元数据。
2. **Space inventory / display association**：macOS 没有提供足以构建完整、稳定、公开支持的“所有显示器 × 全部 Spaces × 每个 Space 的窗口”枚举 API。公开的独立 Spaces 设置值不能替代运行时 Space 分组事实。
3. **切换与激活**：公开 API 对任意 Space 的枚举、指定切换和窗口跨 Space 操作存在明显限制；部分实现依赖辅助功能、自动化或 SkyLight 私有接口，必须单独评估授权、沙箱、系统版本和分发风险。

**裁决：采用 capability-based Spaces Adapter。公开 API 为默认基线；私有 API 只能作为隔离、可关闭、版本化的实验适配器，不能成为首版正确性或安全性的唯一依赖。** 若运行时无法可靠确认某个 Space 的窗口成员关系，界面必须明确降级为部分可观测，不能猜测、合并或伪造布局。

## 2. 为什么公开设置与私有分组结果不一致

### 2.1 两者回答的是不同问题

NSScreen.screensHaveSeparateSpaces 表达的是用户是否启用了“显示器使用单独的 Spaces”这一偏好/配置状态。它并不直接返回当前有多少个可枚举 Space、每个 Space 属于哪个物理显示器、每个窗口属于哪些 Space，或当前 Space 与其他显示器当前 Space 的映射。

SkyLight 的 SLSCopyManagedDisplaySpaces / CGSCopyManagedDisplaySpaces 等私有接口返回的是 WindowServer 当前管理的内部结构。它可能包含按显示器或内部管理 scope 分组的记录，但该结构属于未公开实现细节。私有结果中的数组条目不应未经验证就解释为“一个物理显示器”，也不能只凭 Display Identifier、Main 字符串或数组顺序建立永久映射。

因此，公开布尔值与私有接口分组数量或分组内容不一致，并不自动意味着其中一个接口错误。它们的语义、抽象层级、采样时刻和内部管理对象可能不同。

### 2.2 需要纳入验证矩阵的解释变量

- 镜像显示器：多个物理输出可能对应同一个逻辑桌面或共享 Space 管理状态。
- 主显示器/辅助显示器重配置：系统可能在显示器变化后重建或重排内部记录。
- 全屏应用与全屏 Space：全屏窗口会触发额外 Space 状态；它不等同于普通桌面窗口。
- Stage Manager / 窗口集合：窗口可见性、所在集合与传统 Space 归属并非同一维度。
- Space 创建/销毁与动画过渡：公开设置、AppKit 屏幕列表、WindowServer 私有状态可能在不同时间点更新。
- 虚拟显示器、远程会话、Sidecar/AirPlay：显示器拓扑与 WindowServer 管理 scope 不一定一一对应。
- 私有 API 数据结构演进：字段、符号、参数约定及返回对象可能随系统版本改变。

这些是需要纳入验证矩阵的解释变量，不代表本轮已经逐项复现。

## 3. 证据分级

| 能力/接口 | 证据等级 | 可用于产品决策的范围 | 不允许的推断 |
|---|---|---|---|
| NSScreen / CGGetActiveDisplayList / CGDisplayBounds | A：公开 API | 当前显示器列表、几何、像素尺寸、旋转、镜像关系 | 不能由此枚举全部 Spaces |
| NSScreen.screensHaveSeparateSpaces | A：公开 API | 读取用户设置状态 | 不能将 true 解释为私有返回数组必然按物理屏一一分组 |
| CGWindowListCopyWindowInfo | A：公开 API | 窗口列表、窗口号、层级、可见状态、bounds 等元数据（受权限与系统限制） | 不能单独得到完整 Space membership；不能保证拿到窗口内容 |
| Accessibility API | A：公开 API | 用户授权后读取部分应用窗口属性、执行允许的辅助操作 | 不是完整、统一的 WindowServer Space 数据库 |
| SLSCopyManagedDisplaySpaces 等 SkyLight 符号 | C：私有 API | 研究性适配、特定系统构建上的受控探测 | 不得承诺稳定 ABI、审核接受或跨版本一致 |
| SLSCopySpacesForWindows 等私有成员查询 | C：私有 API | 在受控版本验证窗口与内部 Space ID 的关联 | 不得把返回值未经验证直接映射为用户可见 Space 身份 |
| AppleScript / Mission Control UI 操作 | B/C：行为/自动化依赖 | 经用户授权后的有限切换/激活实验 | 不可视为稳定的任意 Space API |

**历史证据说明（2026-11-08）：** 上一轮执行记录确认曾编写并运行只读 SkyLight 探测程序，但该次完整原始 JSON 未恢复。因此，2026-11-08 的具体结果仍标记为 **OBSERVED-HISTORICAL / RAW-RECEIPT-NOT-RECOVERED**，不作为本轮实测证据。2026-11-09 的新一轮真实只读基线见第 8 节及 `docs/engineering/P1-READONLY-BASELINE-20261109.md`。

## 4. 产品与工程裁决

### 4.1 建立 Spaces Adapter 抽象

上层产品逻辑只消费规范化模型，不直接依赖 SkyLight 字段：

- DisplayDescriptor：稳定显示器标识（可用时）、几何、方向、镜像关系、可用区域。
- SpaceDescriptor：运行时匿名 ID、所属 display scope（置信度）、类型、当前状态、可见状态、证据来源。
- WindowDescriptor：窗口 ID（进程会话内有效）、所属应用、bounds、层级、可见性、Space membership 及置信度。
- ObservationSnapshot：采样时间、系统版本、权限状态、各字段来源、完整性与新鲜度。
- CapabilityReport：每个能力是否可用、降级原因、所用适配器及系统版本范围。

Space ID 仅作为短期运行时身份，不作为持久化用户数据或跨重启主键。窗口 ID 同样必须按进程/会话生命周期管理。

### 4.2 分级运行模式

**Tier 0 — Display & Window Observation（公开基线）**
- 显示器拓扑、几何与窗口元数据。
- 不声称已完整枚举全部 Spaces。
- 可以呈现当前可确认的桌面窗口状态，但不可把无法确认的窗口归入某个 Space。

**Tier 1 — Confirmed Spaces Mapping（经系统版本验证）**
- 只有当适配器能对当前系统构建确认 Space inventory、display scope 与窗口 membership 时，才显示完整可交互的逐 Space 预览。
- 每次系统状态变化后重新验证快照一致性。
- 不完整或冲突的映射进入 degraded 状态。

**Tier 2 — Experimental Private Adapter（可选实验）**
- 私有接口封装在单独模块中，动态符号解析，不静态链接私有 framework。
- 按 OS build 建立兼容性白名单和探测收据。
- 私有 API 异常、字段缺失、结构变化或一致性失败时立即停用并退回 Tier 0。
- 不允许私有 API 故障导致主界面崩溃或错误切换窗口。

### 4.3 一致性验证规则

一次完整映射必须同时满足：
1. 显示器拓扑采样前后稳定；
2. Space inventory 的 scope 可解释，且不存在重复或无法解析的身份；
3. 当前 Space 状态与系统可观察行为一致；
4. 选取的窗口样本，其 bounds、显示器归属和 membership 在同一快照内一致；
5. 同一窗口不应被无理由映射到互斥的普通桌面 Space；
6. 全屏、镜像、显示器插拔、Space 切换过渡期间标记为 transient，不发布为稳定快照；
7. 任何无法证实的字段必须保留 unknown，不得用猜测填充。

### 4.4 交互降级

- **完整映射**：显示真实 Space 列表、窗口几何及可确认的点击目标。
- **部分映射**：保留已确认内容；未知 Space 或窗口显示为不可操作/待系统状态稳定，不伪造占位布局。
- **仅显示器与窗口可见性**：不展示虚构的多 Space 预览；给出轻量状态提示，并保留 Saytile、Riftlet 等其他模块。
- **私有适配器不可用**：产品仍可启动、其他模块仍可工作，不要求用户关闭系统安全保护。

## 5. 分发、权限与风险

- 使用私有 SkyLight API 存在 App Store 审核、代码签名、系统兼容性和维护风险。是否允许上架必须以 Apple 当期规则和实际审核结果为准，不能在设计阶段承诺。
- Mac App Store 与 Developer ID 直发的技术边界、沙箱能力和审核策略不同，应在发布路线中单独决策。
- 辅助功能权限与屏幕录制权限是不同授权；不能为了窗口元数据访问而默认索取屏幕录制权限。
- 窗口元数据不等于窗口像素。截图/内容缩略图涉及独立的屏幕录制权限、数据处理与隐私设计。
- 对系统私有 API 的探测必须只读、最小化、可关闭；不注入进程、不修改系统偏好、不操作 Mission Control 私有状态。

## 6. 验证矩阵（后续工程阶段执行）

| 场景 | 需要验证的事实 |
|---|---|
| 单显示器、独立 Spaces 关闭 | Space 数量、当前 Space、窗口 membership |
| 双显示器、独立 Spaces 开启 | 两显示器当前 Space 与 inventory 的对应关系 |
| 双显示器、独立 Spaces 关闭 | 共享/同步行为及窗口映射 |
| 镜像显示器 | 物理显示器与逻辑 display scope 的关系 |
| 全屏应用 | 全屏 Space 的发现、窗口身份和切换行为 |
| Stage Manager 开启/关闭 | Space membership 与窗口集合/可见状态是否可区分 |
| 插拔/排列/主屏变更 | 快照失效、重新映射和 UI 稳定性 |
| Space 动画过渡 | transient 检测和防止旧快照误操作 |
| 远程/虚拟显示器 | 未知 display scope 的安全降级 |
| 权限未授权/撤销 | 不崩溃、不循环弹窗、其他模块继续工作 |

每项验证都必须记录 macOS build、设备显示器拓扑、系统设置、权限状态、API/符号可用性、原始 JSON、判定规则和 SHA-256。未完成的项标记 NOT_TESTED。

## 7. 最终技术决策

1. **产品方向不变**：Nearpane 仍然以真实 Spaces 与真实窗口几何作为核心差异化能力。
2. **不把公开设置当作 Space inventory**：screensHaveSeparateSpaces 只是一项设置状态。
3. **不把私有分组当作物理显示器真相**：SkyLight scope 必须通过窗口样本与显示器拓扑交叉验证。
4. **首版架构采用适配器与能力降级**：公开 API 为稳定基线；私有 API 不得成为唯一依赖。
5. **允许技术可行性与发布策略分开**：某个系统版本可探测，不等于该方案适合 App Store 或长期维护。
6. **证据缺口不阻断其他设计**：完整产品架构、模块系统、交互设计和工程路线可以继续；但完整 Spaces 支持在系统矩阵验收前仍为 DESIGNED / NOT VALIDATED。

---

**状态摘要：** 技术方向已裁决；历史不一致观察保留但原始收据未恢复；跨版本可靠性、完整 Space inventory 和切换行为仍需后续实机验证。


## 8. P1 live read-only baseline — 2026-11-09

本轮在 macOS 27.0（Build 26A428，ARM64）执行两次真实只读探测。脱敏汇总位于 `experiments/macos-spaces-readonly/evidence/p1-readonly-summary.json`。

核心观察：

- `NSScreen.screensHaveSeparateSpaces` 为 false；
- 公开 API 检测到 2 个活动显示器；
- SkyLight 返回 2 个 managed display scopes，两个 scope 均通过显示器 UUID 匹配到公开显示器；
- 两个 scope 的 Space 记录数分别为 3 与 1，两次采样保持一致；
- 两次采样中，当前可见且 bounds 为正面积的 layer-zero 窗口均全部取得非空 membership；
- 全部 layer-zero 窗口中只有部分记录返回非空 membership，剩余记录保持 unknown；
- 第二显示器存在 90° 旋转，AppKit frame 与 CoreGraphics bounds 的原点不同，必须使用显式坐标变换。

**解释边界：** 该结果证明私有 scope 可在该系统构建上与公开显示器 UUID 对应，但不证明 3+1 条记录是 4 个独立的用户 Spaces。共享 Spaces 的切换语义、窗口跨显示器行为和写操作尚未验证。不能将 scope 直接当作用户可见 Space 列表，也不能将其记录数简单相加。

本轮没有采集像素、切换 Space、改变窗口焦点或请求新权限。Space type 保留 raw 数值，不推断 `type=4` 的语义。P1 仍为 IN PROGRESS。
