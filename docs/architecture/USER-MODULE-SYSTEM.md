# Nearpane — 用户自定义模块系统规格

**状态：产品/系统设计规格 · 0.1 · 2026-11-08**  
**依赖：PRODUCT_DEFINITION.md、NEARPANE-VISUAL-AUTHORITY.md、NEARPANE-ARCHITECTURE.md**

## 1. 设计目标

用户可以把真正需要长期放在手边的功能加入 Nearpane。模块系统必须让用户拥有组合权，同时保护 Nearpane 原本的核心体验：Saytile、Riftlet 与当前模式的空间编排（Native Spaces 或 Virtual Workspaces）始终有清晰的位置和职责。按 ADR-011，用户模块和唯一 Saytile/Riftlet 呈现只存在于**主驻留屏**；副屏是纯 Space-only 面板，不复制用户模块和领域实例。

模块系统不是“把任意小组件无限塞进侧栏”。它是一个有约束、可组合、可撤销授权、可隔离故障的常驻能力系统。

## 2. 模块分类

| 类别 | 示例 | 默认行为 |
|---|---|---|
| First-party Core | Saytile、Riftlet、Desktop Orchestration | 首次安装即存在；核心模块不可被第三方覆盖 |
| Built-in Resident | AI Assistant、Notes、Tasks、Calendar、Clock、Weather | 用户主动添加；可固定、收起或停用 |
| Connected Service | Google Calendar 等用户连接的数据源 | 用户连接后可启用；权限独立、可撤销 |
| External Shortcut | 用户添加的网站/应用入口 | 仅启动或打开目标，不获得宿主内部数据访问权 |
| Future Extension | 经审核的第三方模块 | 不属于首版承诺，未来按安全模型单独开放 |

## 3. 主表面空间策略

### 3.1 不改变视觉权威的核心预算

冻结的默认结构保持：
- 侧栏宽度约为屏幕宽度 1/8；
- 无标题、无 Logo、无产品名、无常驻 Header；
- Saytile 与 Riftlet 的核心工具区约占纵向可用空间 3/8；
- 当前模式的 Space/Workspace 预览区约占 5/8；
- Native/Virtual 预览的窗口几何真实性不因模块增加而改变；用户模块不需要知道空间引擎实现细节。

### 3.2 用户模块的呈现方式

新增模块不能默认把原来的 3/8 + 5/8 重新切成更小块。采用三种互补呈现：

1. **Compact Resident（紧凑常驻）**：模块在核心工具区之外拥有一个受约束的轻量入口/状态位。仅显示最有价值的一项状态或下一步，例如下一场日程、一个待办计数、天气温度、便签首行。它不展开为完整卡片。
2. **Expanded Surface（展开表面）**：点击紧凑入口后，在 Nearpane 侧栏内部以覆盖式/浮层方式展开模块内容。展开期间暂时覆盖部分 Space 预览区域，不重新计算或压缩底层真实窗口几何；关闭后原位恢复。
3. **Popover / Quick Action（快速浮层）**：适合添加便签、创建待办、查看时间等短操作，完成后自动回到原表面。操作是否关闭由用户行为决定，不擅自丢弃未保存内容。

### 3.3 空间与密度约束

- 首屏默认只显示用户明确固定的模块。
- 用户可选择“只显示状态”“显示紧凑内容”“点击时展开”。
- 当固定模块过多时，模块区采用独立滚动/分页，不得压缩 Saytile / Riftlet 核心交互或将 Space 行缩至不可辨认。
- 可选模块不得遮挡语音文字流中的当前输入焦点；语音输入正在进行时，展开模块不应强制抢焦点。
- 模块展开必须可通过关闭、点击外部或返回操作退出；若存在未保存编辑，先提供明确保存/放弃语义。
- 模块顺序由用户配置；核心模块的相对顺序和空间预览边界保持稳定。
- 用户可以完全不添加任何可选模块，默认产品仍然完整。

## 4. 首批内置模块设计

### AI Assistant
- Compact：显示一个克制的助手入口，可选展示最近会话/处理中状态。
- Expanded：轻量对话与动作确认界面，不把主侧栏永久变成聊天窗口。
- 上下文默认空白；用户通过选择文本、截图或明确动作附加上下文。
- 任何外部发送、提交、执行动作必须二次确认或遵循清晰的用户触发动作。

### Notes
- Compact：最近便签首行或未完成草稿提示。
- Expanded：快速查看、编辑、创建、搜索便签。
- 自动保存需有明确状态；离线可用；不把临时语音稿自动写入便签。

### Tasks
- Compact：最近到期/下一项任务或未完成数量。
- Expanded：创建、完成、调整优先级和截止时间。
- AI 生成任务只能作为草稿，用户确认后才写入。
- 不默认把日历事件转为任务。

### Calendar
- Compact：下一场事件及开始时间。
- Expanded：当天/近期日程、事件详情和打开来源日历。
- 连接账户、读取日历与写入日历是不同权限；首版可先只读。
- 日程时区必须明确，避免显示错误本地时间。

### Clock
- Compact：本地时间。
- Expanded：可选时区列表、日期和时间格式设置。
- 不需要后台网络权限。

### Weather
- Compact：当前天气图标/温度/地点。
- Expanded：短期预报与地点切换。
- 默认手动选择城市；位置权限完全可选。
- 显示数据更新时间和无法更新状态，不把旧数据伪装成实时。

## 5. 模块 Manifest 与契约

首版 manifest 采用声明式结构，示意字段如下：

```json
{
  "id": "com.holdsnow.nearpane.calendar",
  "version": "1.0.0",
  "kind": "built-in",
  "presentation": ["compact", "expanded", "popover"],
  "lifecycle": ["resident", "on-demand"],
  "permissions": ["calendar.read"],
  "dataScopes": ["calendar.events.read"],
  "actions": ["calendar.open-event", "calendar.refresh"],
  "minimumHostVersion": "1.0"
}
```

字段含义：
- id 全局稳定，不因显示名称或本地化改变；
- presentation 声明可用表面类型；
- lifecycle 声明是否常驻、是否按需启动；
- permissions 使用最小权限集合；
- dataScopes 限制可读写数据范围；
- actions 是宿主可路由的显式动作白名单；
- minimumHostVersion 防止旧宿主加载不兼容模块。

Manifest 不包含可执行代码，不允许声明任意文件系统路径或任意网络访问白名单。首版模块实现随 Nearpane 签名应用交付。

## 6. 模块生命周期

1. **Available**：模块在内置目录可见，未启用。
2. **Enabling**：用户主动添加，检查依赖和必要配置。
3. **PermissionRequired**：仅在用户首次触发相关能力时申请权限。
4. **Resident**：模块出现在用户固定区域并发布状态。
5. **Expanded**：用户打开完整模块表面。
6. **Suspended**：资源受限或用户收起；保留必要状态，不持续执行无关后台任务。
7. **Degraded**：权限撤销、数据源离线或模块内部错误；显示可解释状态，不阻断其他模块。
8. **Disabled**：用户停用；不再刷新或处理事件，保留/删除数据遵循模块明确策略。

移除模块与删除模块数据是两个不同动作。关闭日历模块不能默认断开用户账户；移除 Notes 不能默默删除便签。

## 7. 权限与数据隔离

- 每个模块声明权限和数据范围；宿主统一呈现请求理由。
- 模块只有在启用且用户授权后才可访问对应数据。
- 不允许模块读取其他模块的私有数据库或缓存目录。
- 跨模块数据通过用户触发的 Action Broker 传递最小必要引用。
- 日历账户连接、天气位置、AI 云端请求分别授权。
- 撤销权限后立即停止相关访问，进入 Degraded，并提供恢复入口。
- 日志不得记录语音原文、截图内容、便签正文或账户令牌。

## 8. 设置 IA

设置不进入无标题的常驻主表面。通过独立设置界面提供：
- Modules：添加、停用、排序、固定、展示模式；
- Permissions：按模块查看授权、撤销与解释；
- Data & Accounts：账户连接、数据源与隐私选项；
- Appearance：密度、动效、位置与表面偏好；
- About & Diagnostics：版本、能力等级、诊断导出。

## 9. 首版范围裁决

首版应优先支持：
- Saytile 与 Riftlet 两个第一方核心模块；
- Desktop Orchestration；
- 内置 AI Assistant、Notes、Tasks、Calendar、Clock、Weather 的可添加框架；
- 首批可选模块可以按优先级分批交付，不要求 V1 一次全部实现。

不承诺：
- 任意第三方插件运行时；
- 公开插件市场；
- 任意脚本执行；
- 自动跨模块数据共享；
- 未经用户确认的 AI 自动操作。

**最终原则：用户可以决定 Nearpane 里常驻什么；Nearpane 必须决定模块如何安全、克制且不破坏核心空间结构地呈现。**
