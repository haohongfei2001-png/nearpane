# 最新仓库基线与冲突审计

审查日期：2026-11-17（Asia/Shanghai）。范围是 GitHub 文档、源码树、关键实现、开放 PR 与仓库自述证据；本轮没有启动原生应用、没有复验用户 Mac。以下“仓库记录已验证”不能读成“本轮实机通过”。

## 1. 基线必须同时锁定三条线

| 用途 | 固定来源 | 结论 |
|---|---|---|
| 默认分支与旧定义 | [main `e3f26bbaa1ba4da87da56b475f5fa6fa5daa8766`](https://github.com/haohongfei2001-png/nearpane/tree/e3f26bbaa1ba4da87da56b475f5fa6fa5daa8766) | 只有官网、早期产品定义和旧视觉规范，不是最新原生实现。 |
| 初审原生源码快照 | [implementation/host-foundation-20261109 `1d7fc062b2b7e99ad56721c3fc012e3c48f4f4b0`](https://github.com/haohongfei2001-png/nearpane/tree/1d7fc062b2b7e99ad56721c3fc012e3c48f4f4b0) | 状态入口记载个人安装为 P5.13 Alpha（64），成品源码 `b5fe7871adc6102eed4098abfebd4ea7583666e2`。提交与安装包源码不可混用。 |
| 最终原生审查快照 | [implementation/host-foundation-20261109 `beeccbaa80ea1239042338b48cf5f53011a74c22`](https://github.com/haohongfei2001-png/nearpane/tree/beeccbaa80ea1239042338b48cf5f53011a74c22) | 交付前补审9个提交、44个变更文件。新增P5.14受限捕获及会话/重启保护，没有新的安装版本收据；不能把head等同个人安装源码。 |
| 历史重大产品决定 | [双模式设计 `bbe693b3`](https://github.com/haohongfei2001-png/nearpane/tree/bbe693b3cb32911793254664fb7193fb2e2966c8/docs) | ADR-010—013 已扩充 Native/Virtual、持久 WorkRect、八窗渐进布局和新窗策略。原生分支保留了这些正式决定。 |

[PRODUCT_COMPLETION_STATE.md](https://github.com/haohongfei2001-png/nearpane/blob/beeccbaa80ea1239042338b48cf5f53011a74c22/engineering/verification/PRODUCT_COMPLETION_STATE.md) 是当前状态入口。README 与 NEARPANE-PRODUCT-COMPLETION-MAP.md 仍含 P4.8 时期概括，不能用旧表否定后来实现。

所审查的 main、最新 implementation 与历史设计树未发现 AGENTS.md；不据此推定其他未审查路径不存在规则。

## 2. 最新实现实际具备什么

| 能力 | Designed / Implemented / Validated 的正确读法 |
|---|---|
| 原生侧栏与多屏角色 | 已实现唯一 Host、唯一 Saytile/Riftlet 领域实例、主驻留屏工具、副屏 Space-only、按屏设置。仓库记录副屏与合成拓扑验证；物理热插拔、多个个人工作屏同时运行仍有缺口。 |
| 界面外观 | P5.13 已有浅/深色分层玻璃、等宽四边留白、14 pt 苹方语音、原图 Fit 双列托盘、随产品强调色。不能将隐藏窗口合成渲染当作动态桌面模糊、录音或上传验收。 |
| 档案与设置 | P5.12 已交付同一主窗口中的“语音档案”“截图档案”和模块设置。语音支持搜索、分页及存在原音时主动回听；截图档案包含原尺寸、日期、托盘状态与附加回执。新方案应扩展这个入口，不再创建另一套重叠档案中心。 |
| 语音 | 原生文字、手改保护、复制、资料重开已存在。已接通手动插入，但真实前台输入框未验；物理麦克风完整链也未验。不能把替身输入框或合成 PCM 当真人全过程。 |
| 截图 | 系统截图、两列托盘、展开/收起、历史、共享锁与重开已实现且有受限实证。普通 Alpha 已接真实草稿适配器；真实服务端附加终态仍阻塞。 |
| 普通窗口管理 | 已从早期随包协议发展到副屏标准 AppKit 普通窗逐窗授权，1—8 窗真实布局、停止恢复有仓库证据。不是任意第三方全局自动接管。鼠标按住期间不可穿越的“硬边界”尚未实现。 |
| Native Spaces | 可见几何及有证据的归属展示已存在；普通 A→B→A 仍为 0/3，跨空间移窗 0 次，产品行点击/跨空间拖放关闭。独立创建过副屏 B 不能等同完整切换准入。 |
| 全屏 | 2026-11-13 的隔离 Host、自建副屏全屏窗口完成进入/退出和手动工具浮层开合。不能推广为所有第三方 App 全屏、多显示器组合都通过。 |
| 可选模块 | 生命周期、顺序、固定/展开、停用与快照隔离基础已实现；只有时钟为可用内置扩展，其他 notes/tasks/calendar/weather 是样例并在产品目录隐藏。 |
| 本轮新增功能 | 完整独立笔记、计算草稿、待办连接、通用文件中心、剪贴板历史、翻译语言笔记、音乐/播客没有对应产品领域实现。应标 Designed；语音/截图档案不等于通用笔记/文件系统。 |

证据：[P5.12](https://github.com/haohongfei2001-png/nearpane/blob/1d7fc062b2b7e99ad56721c3fc012e3c48f4f4b0/engineering/verification/P5.12-UNIFIED-ARCHIVES-AND-SETTINGS.md)、[P5.13](https://github.com/haohongfei2001-png/nearpane/blob/1d7fc062b2b7e99ad56721c3fc012e3c48f4f4b0/engineering/verification/P5.13-VISUAL-FIDELITY.md)、[P5.11](https://github.com/haohongfei2001-png/nearpane/blob/1d7fc062b2b7e99ad56721c3fc012e3c48f4f4b0/engineering/verification/P5.11-APPEARANCE-DOMAINS-AND-WINDOWS.md)、上述持续状态入口。

## 2.1 交付前新增9个提交的审查

[增量比较：1d7fc062 → beeccbaa](https://github.com/haohongfei2001-png/nearpane/compare/1d7fc062b2b7e99ad56721c3fc012e3c48f4f4b0...beeccbaa80ea1239042338b48cf5f53011a74c22)。以下是已加入当前源码的能力与其证据边界，不能以初审P5.13概括漏掉，也不能反过来扩写实证范围。

| 增量 | 对下一代设计的约束 |
|---|---|
| 会话可用性 | 新增锁屏、睡眠、显示器变化的挂起/清除流程；恢复要求新快照。不能把屏幕重新点亮当作可读取、可编排的用户会话。新布局应复用该闸门。 |
| 用户窗口布局 | 普通窗口自定比例、左右交换及正常Quit保留用户布局意图已有实现；下一代不能以恢复旧几何为由丢弃明确用户改动。应用排除规则跟随选定live controller，选择按应用名称呈现。 |
| 可撤销窗口快照 | 用户经系统单窗选择器明确选窗后的一次静态图像；内存持有，60秒清除，身份/拓扑/位置/权限与隐藏状态变化可提前撤销。不是任意窗口连续实时预览，不能与文件货架60秒生命周期混为一个机制。 |
| P5.14证据 | 只验证独立开发签名、无正文的后台AppKit自建窗口：外部只读AX身份、受限窗口号与两色块像素读回。标准角色/子角色联合检查未通过，该窗没有普通用户窗口准入。生产Host选择器→显示→撤权清除端到端仍待验。 |
| 更新重启保护 | 更新安装延后与真正termination barrier均重核当前录音/识别/回听、截图/附加和窗口恢复活动；持久UNKNOWN不当作活跃上传。新文件导入/迁移及草稿flush需接入相同保护，不另开一条不安全重启路径。 |

证据：[P5.14记录](https://github.com/haohongfei2001-png/nearpane/blob/beeccbaa80ea1239042338b48cf5f53011a74c22/engineering/verification/P5.14-OWNED-WINDOW-CAPTURE.md)、[会话可用性](https://github.com/haohongfei2001-png/nearpane/blob/beeccbaa80ea1239042338b48cf5f53011a74c22/Sources/NearpaneCore/DesktopSessionAvailability.swift)、[窗口内容快照](https://github.com/haohongfei2001-png/nearpane/blob/beeccbaa80ea1239042338b48cf5f53011a74c22/Sources/NearpaneUI/WindowContentPreview.swift)、[更新器](https://github.com/haohongfei2001-png/nearpane/blob/beeccbaa80ea1239042338b48cf5f53011a74c22/Sources/NearpaneHost/ApplicationUpdater.swift)。

这批增量没有补齐Native A→B→A或跨Space迁窗证据，域锁未被替换；本轮设计不改变原准入。现有Nearpane仍为开发签名，正式Developer ID签名、公证和干净设备验收不得标为已完成。

## 3. 视觉与历史权威，不能只读 main

最新版 [视觉权威 V2](https://github.com/haohongfei2001-png/nearpane/blob/1d7fc062b2b7e99ad56721c3fc012e3c48f4f4b0/design/NEARPANE-VISUAL-AUTHORITY.md) 明确：2026-11-15 用户重新提供的 [1672×941 界面原图](https://github.com/haohongfei2001-png/nearpane/blob/1d7fc062b2b7e99ad56721c3fc012e3c48f4f4b0/design/assets/2026-11-15-v2/interface-reference-original.png) 是正式图像来源。旧 480×270 webp 有像素错乱，只能保留历史。品牌为黑色拱形 n 与橙色竖柱；完整侧栏继续无标题、Logo、Header。三个圆角层次、外实内透、同心边界、截图完整比例是当前视觉依据；本轮新布局是替代提案，不应宣称本来就被旧规范授权。

[ADR-010](https://github.com/haohongfei2001-png/nearpane/blob/1d7fc062b2b7e99ad56721c3fc012e3c48f4f4b0/decisions/ADR-010-DUAL-WORKSPACE-MODES.md) 已明确覆盖 main 的“只支持 Native、不做 Virtual”。[ADR-013](https://github.com/haohongfei2001-png/nearpane/blob/1d7fc062b2b7e99ad56721c3fc012e3c48f4f4b0/decisions/ADR-013-STABLE-WORKRECT-AND-EIGHT-WINDOW-TILING.md) 又确定新普通窗默认新 Workspace、空来源空间清理、退出保留用户布局、重新启动全面接管等目标；系统能力未准入时仍须回退，不能因为产品决定被接受就越过能力检查。

本轮“保护真实 macOS Spaces”与保留 Virtual 长期目标可以并存：Native 不伪造、Virtual 明确命名且保持关闭，分别验收。没有必要静默删掉早已接受的长期目标，也不应让 Virtual 阻塞笔记与文件等独立工作。

## 4. 新方案必须显式登记的冲突

| 现有规范/实现 | 下一代建议与修改依据 |
|---|---|
| 默认工具 3/8、空间 5/8；工具不随空间数量自动缩小 | 改成“工具独立滚动＋底部空间稳定预算”。当前用户明确要求取消固定比例；按可读最低高度、用户锁定边界及空间数分配，比固定比例更适合可选模块。 |
| 核心 voice/tray/desktop 固定顺序，可选模块在横向 rail | 工具编排统一加入布局描述，支持用户排序、折叠和独立关闭；领域生命周期与视觉展开彻底分离。避免继续把新增模块堆在底部横栏。 |
| 可选展开覆盖空间区 | 详编在工具区或临时向内展开的检查器；底部空间锚点保持。覆盖不是现有 BUG，而是旧规范明确选择，修改需列 ADR。 |
| 所有尺寸精细调整、主界面无拖拽把手 | 默认只提供少数可理解选项，保留现有用户数值为“高级”；新增分隔线直接调整作为明确替代决定。不得静默覆盖旧尺寸、透明度或字体偏好。 |
| 原截图专属托盘及领域队列 | 通用文件中心增加独立 FileStore，与 Riftlet 以受控引用和动作连接；60 秒退出展示只用于新通用文件/临时展示策略，不偷偷改写 Riftlet 原生待附加/失败重生生命周期。 |
| 工作区显隐与持久 WorkRect 独立 | 必须保留：内部伸缩、模块关闭、临时展开不移动第三方窗口。只有用户应用预留宽度或 Docked/Floating 变化才重算对应屏 WorkRect。 |
| 同一产品只有语音/截图档案 | 扩充主窗口导航到独立数据域；“统一入口”不是合并数据库，跨域明确复制/引用/导出。 |

## 5. 可直接复用的代码边界

以下路径均相对最新 implementation 基线：

- `Sources/NearpaneCore/Layout.swift`：当前 SurfaceLayout 固定 voice/screenshots/desktop；可选 rail 在 desktop 底部、expanded 覆盖桌面区域。新 LayoutEngine 应替换这一组合协议，而非在 EdgeSurfaceView 再插若干 if。
- `Sources/NearpaneCore/DisplayPresentation.swift`：已具备按屏 pt/%、响应式 compact/icon、旧高度计算和独立预留。迁移必须保存自定义值及 referenceHeight 语义。
- `Sources/NearpaneCore/Modules.swift`：现有 ModuleRegistry、运行实例、修订 epoch、错误隔离、启停/悬挂可继承；样例 IDs 不能冒充真实领域 ID。现有故障隔离不是进程隔离，崩溃仍可能影响同进程宿主。
- `Sources/NearpaneUI/SettingsView.swift`：现有档案+设置导航直接扩展；不建立第二个配置总入口。
- `Sources/NearpaneSaytileBridge/NearpaneManualInsertion.swift`：按手势捕获 PID/AX 窗口/元素/浏览器文档，要求 canSetSelectedText 和观察能力。当前明确禁止域层 clipboard fallback；剪贴板新模块不能通过复用名义绕过原约束。可抽取共享目标验证服务，动作政策仍按领域独立。
- `Sources/NearpaneUI/DesktopSurface.swift`：只有 snapshot.capabilities.spaceSwitching 成立才安装交互命中；未知归属展示“此屏可见窗口”。新原型里的模拟 Spaces 必须标注演示。
- `Sources/CReadOnlySpaces/ReadOnlySpaces.c`：直接使用私有 SkyLight 与 `_AXUIElementGetWindow`，且限定 arm64 与 OS build `26A428`。这是特定系统构建的读取适配器，不是通用公开 API；不可给全版本兼容或 Mac App Store 能力承诺。

## 6. 三个未合并 PR 不是一条可直接升级的主线

| PR | head | 与最新 implementation 比较 | 本轮处理建议 |
|---|---|---|---|
| [#7](https://github.com/haohongfei2001-png/nearpane/pull/7) | `f9671d15` | ahead 4 / behind 51 | 抽查共享视图契约，保留 P5.13 最新领域与档案。 |
| [#8](https://github.com/haohongfei2001-png/nearpane/pull/8) | `d7905558` | ahead 22 / behind 51 | 评估真实窗口内容缩略图与几何对照，不能整支覆盖新玻璃/设置。 |
| [#9](https://github.com/haohongfei2001-png/nearpane/pull/9) | `bcfeb954` | ahead 36 / behind 51 | 仍锁定 Saytile 内测 0.10；最新实现锁定 Saytile 0.18。应做差异移植决定，不能把较新的 PR 编号当较新的产品版本。 |

三者共同分叉点 `fb0badc4597d2eff1ea81186c53403604103244d`；GitHub compare 状态均为 diverged。比较依据：[implementation…PR9](https://github.com/haohongfei2001-png/nearpane/compare/beeccbaa80ea1239042338b48cf5f53011a74c22...bcfeb9544c15f3f6183e59b4bd819597699c68f8)。P5.13 锁定 Saytile `012999c2018f591f3cf9a529e4c0ae81e7b81f21`、Riftlet `189782dd943f5215da43539b30db27e482a78b3c`，见 [domains.lock.json](https://github.com/haohongfei2001-png/nearpane/blob/1d7fc062b2b7e99ad56721c3fc012e3c48f4f4b0/Dependencies/domains.lock.json)。

## 7. 下一阶段的实施前置条件

先在独立实现分支从最新原生 head 建基线，记录与本次固定 SHA 的增量；设计 PR 仅加入新提案目录。建立权威映射与迁移决定，保持 P5.13 已有档案、数据代际、模块锁、用户外观和 WorkRect。首先交付布局宿主、统一编辑外壳及独立本地数据域，再接通系统服务。高风险 Spaces/第三方插入/音乐歌词应各有独立能力报告，阻塞一项不阻塞其他已可开发模块。每项最终报告必须分别列 Designed、Implemented、Validated；引用仓库测试数量时写清源版本与场景，禁止把旧测试总数累加成新产品全通过。
