# 已确定的产品与技术决策

**窗口调度路线已更新。** 当前工程采用[StageGroup 裁决](../research/NEARPANE-STAGE-MANAGER-PRODUCT-DEFINITION.md)。下文涉及原生桌面切换、跨 Space 迁窗与双模式的历史要求均为 ARCHIVED。

本文件适用于 [原生空间专项](README.md)。这里的方案是待实现决定，不是性能或系统能力已实测的声明。

## 当前产品交互修订 · 2026-11-18

正式侧栏仅列当前显示器、当前桌面的实际窗口。一窗一项，从工具区下方开始排列，同屏使用相同的几何缩尺。普通点击仅选择这个窗口。此前 D02 中的桌面行、全空间地图和迁窗拖放移出该界面，原技术记录与验证结果保留。用户单独授权的窗口管理入口独立运行。

## D01｜产品语义

系统拥有真实 Space、窗口与原生全屏。Nearpane 提供可视侧栏和窗口管理。切换、系统 Mission Control 与系统手势应相互同步。运行时空间身份不能用“桌面 2”这样的显示编号代替。

沿用 Native 默认、Virtual 明确选择的既有定义。本轮不开发 Virtual 停放后端，也不把它用作 Native 失败的替代验收。普通窗口自动管理是独立政策，单纯切 Space 不顺带重排全部窗口。

## D02｜主界面与具体交互

- 每个真实 Space 一行，保持系统次序与所属显示器；内部按真实 frame、比例和遮挡绘制窗口。真实空空间照常显示，可被切换；未知内容不能画成空空间。
- 点击行背景/留白：切到该 Space，让系统保留该桌面的正常焦点语义。空 Space 不要求存在 key window。
- 点击可命中的具体窗口：必要时先切 Space，再精确激活该窗口。仅把应用带到前台不算成功。
- 拖动具体窗口超过现有 6 pt 阈值后进入迁移意图；悬停只给落点反馈，drop 才执行。取消不迁移；拖动不误触点击。
- 重叠区域按真实层级命中；不穿透上层窗选到被完全遮挡的下层窗。保留逐窗列表以访问完全遮挡/最小化成员；列表与真实 Space 地图共用同一库存，卡片列表不能替代全部 Space 的真实地图。
- 保留 5.19 已合入的工具顺序、工具之后的当前桌面窗口单列排列，以及玻璃背景与文字/图像分层；不回退成随窗口数压缩的网格。新增全部 Space 导航位于同一空间区中可直接到达的独立区域，与逐窗列表分区滚动；不在最后工具与第一张窗口卡之间新增标题或大块空白。具体布局仍须在实际侧栏验证导航可达性、真实几何和窗口卡可读性，不能只做离屏排版。
- 不因一次采样刷新、无关窗口变化或截图更新取消有效点击/拖动。释放时核对相关身份与目标，不比较整个快照是否逐字段相同。
- 保持简洁透明表面、少按钮、无标题/Logo。宽度约 1/8 是参考而非硬验收等式；尊重用户保存尺寸、已合入的 5.19 视觉修订和 PR #10 Revision 02 的不冲突修订。本轮不实施被用户否定的旧提案图。
- 原生全屏默认隐藏空间调度，按既有规则保留用户主动开启的语音等精简工具。普通侧栏可进入全屏 Space；全屏中返回使用系统原生方式或已有合法入口，不为验收新增强制覆盖全屏的空间面板。普通最大化仍遵守 WorkRect。

这明确更新旧 PRODUCT_DEFINITION / INTERACTION-SPEC / ADR-013 中“整行点击且窗口不可单击激活”的限制。

## D03｜后端选择与固定来源

| 用途 | 首选与固定版本 | 集成方式 |
| --- | --- | --- |
| 原生 Space 切换 | InstantSpaceSwitcher v3.1，`f7616e42651b1ed8d81625e3640eceed6efa8018`，MIT | 提取 ISS C target 的必要代码和 macOS 27 事件格式，封装独立适配器 |
| 真实窗口迁 Space、空间观察对照 | yabai `b2dc8b4c892d74738a6e865d73048ed2dc3c9ed1`，MIT | 研究并窄范围采用对应窗口/空间实现，不启动另一套自动平铺 daemon |
| 普通 AX 窗口兼容与布局 | 保留 Nearpane 现有成果；按需引用 Rectangle MIT 实现 | 不为复用重写已经通过的 WorkRect、历史布局和恢复 |
| 创建/删除测试及产品空间 | 经验证的系统 AX / Mission Control 路线作为候选 | 与高频切换分离，接受必要的系统界面反馈，不能伪称无闪动私有直达 |
| 诊断参考 | Hammerspoon hs.spaces | 不作为每次高频切换都开关 Mission Control 的默认实现 |

先验证上表主候选和对照，使用功能最小、可证明达标的实现。开工可检查与当前系统 build 相关的新修复；更新 pin 必须记录具体原因、差异和重测结果，不盲目追 main。

不安装/要求用户配置 Homebrew、yabai、ISS 独立应用或快捷键。禁止把外部 CLI 每次启动和等待串成用户主路径；需要 helper 时随包提供、长期服务或按合理生命周期管理。

不自动降低 SIP，不加载 Dock scripting addition，不修改系统安全策略。源码中的多种 fallback 不能原封不动全部启用；只启用已经审阅、符合本轮边界并在目标系统验证的路径。

AltTab 的 GPL-3.0 代码整合需要分发许可兼容判断，本轮可研究其行为但不直接引入未审阅的代码。AeroSpace 的模拟 workspace 不作为 Native 底座。

## D04｜ISS 的已知边界必须显式补齐

1. 上游 `iss_switch_to_index` 使用顺序 index；Nearpane 外部接口必须接受 session + displayUUID/scope + SpaceID，执行前映射最新次序。Space 重排不得切错。
2. 上游按鼠标屏幕读取状态，没有已完成的显式显示器接口。扩展按目标屏读取与路由；侧栏点击在目标屏这一事实仍须系统回读验证。跨屏请求不得悄悄变成操作鼠标所在屏。
3. 拆分 `iss_init/destroy` 的核心状态、自然滚动通知与可选全局 event tap。侧栏只初始化必要核心；不接管系统手势，不默认启用全局键盘监听。通知注销不应错误依赖 globalTap 存在。
4. 上游成功返回和预测 callback 只表示已发起，不构成到达确认。连续请求必须由 Nearpane 调度器与真实系统读回收敛。
5. 空 Space、全屏 Space、多屏、连续操作和非相邻目标均须专项证明；不得从源码结构推断成实机 PASS。

## D05｜动效决定

默认目标是原生式平滑、连续、不闪黑、不跳错桌面的过渡，并遵循系统“减少动态效果”。保留系统自己的手势。用户不需要决定后端、速度、校准方式或实验开关。

ISS 在 macOS 27 的 modern 路径写死近零 progress 与高 velocity；`iss_set_gesture_speed` 不控制该路径。不能用“调一个速度参数”冒称已经保留原生动画。

实施时先将原有快路径作为内部技术对照，再在复用事件格式的基础上验证平滑的时序 profile 或另一个有来源的系统原生路径。若使用手势 profile，需要验证 began、随时间推进的 changed、ended/cancelled、自然滚动方向和系统接管；非相邻目标不能明显逐个桌面闪过。保持改动局限在适配器，禁止无依据扫描私有 selector 或猜参数。

默认动效需要在最终产品中同机录屏对照原生，按 ACCEPTANCE 判定。只获得瞬切证明时可继续其他工程，但“原生式动效”保持未通过，不能用另一套动画策略偷换验收。无需承诺 Apple 合成器逐像素一致。

## D06｜统一系统状态服务

建立单一真源，合并旧 Host 观察和 CurrentDesktopWindows 的重复 inventory；保留现有快速更新能力，不退回纯低频轮询。

- Space 身份：WindowServer/登录会话 + native SpaceID；可靠 UUID 只辅助重识别。次序与显示器归属是会变化的属性。
- Window 身份：PID + 进程启动代际 + CGWindowID；AX 对象是可更新句柄。关闭/进程重启后不得沿用旧目标。
- 独立建模：Space membership、屏幕几何、可见性、最小化、原生全屏、Stage Manager 呈现和实际焦点。
- 空 Space/后台 Space 不依赖可见窗口锚点或访问历史才能存在。结构/成员未知与确认空必须不同。
- NSWorkspace、显示器和 AX 通知驱动更新，低频校对补漏；采样缺失和动画 transient 不把整张空间地图反复清空。
- 单个窗口的 AX 失败只降低相关动作，不拖垮其他 Space 和窗口。

## D07｜动作能力与完成状态

只读 Reader 继续只读。另设正式 NativeActionService，分别公布 switchSpace、focusWindow、moveWindow、tile、createSpace、removeSpace 的可用性、后端和原因。UI 接这个服务，不能把旧 false 翻成 true 当作实现。

异步状态至少区分 queued、executing、issued、confirmed、failed、outcomeUnknown、superseded、cancelled。每个意图有唯一 ID 和相关对象；confirmed 只能由独立系统观察满足后置条件产生。

- 切 Space：系统目标 scope 的 current 与目标一致；不要求把焦点归还原应用。
- 精确选窗：目标 Space 正确，目标 PID/代际/窗口号与 focusedWindow 一致；测试中还需独立输入落点。
- 迁窗：同一窗口 membership 真正改变。后续平铺失败时报告部分结果，不能谎称未迁移。
- 已投递后超时：先读回实际状态，不能盲目重发。取消 Task 不能撤销已经发出的事件。
- 仅恢复明确由本事务改变、身份仍匹配且未被用户后续覆盖的对象；不因切换超时随意强制回原桌面。

串行管理全局焦点动作；未投递的多次切换可合并为最后意图。已投递的先确认实际状态，旧回调不能抢走用户的新焦点。迁移/创建/删除不按无副作用点击的规则任意丢弃或重放。

## D08｜预览与隐私

用 ScreenCaptureKit 获取实际可捕获的单窗内容；沿用现有合格部分。稳定窗口身份是缓存 key 的一部分；不同进程代际不得串图。

显示可用最新画面，后台采用有效的最近画面；用简洁视觉区分历史/不可捕获状态，不铺工程解释。几何和身份仍可交互时不能因为没图就全禁用。空 Space 保持可切换。

锁屏、撤销权限、明确关闭缩略图时停止采集并撤回敏感像素；普通空间切换与短暂采样失败不要等同撤权后把全部有效内容清零。截图只在内存缓存，本专项不建立用户桌面截图档案。

## D09｜窗口管理保持的产品规则

保留 ADR-013 的 WorkRect、渐进布局、最小尺寸、用户意图、排除与恢复语义：

- 1 窗填满；2 窗平分；第 3 窗占左半、旧两窗分右半；4 窗四分；5–8 继续既定渐进分割。
- 双窗自定义比例和槽位可保存；加入第三窗用三窗模板，移除后恢复对应历史。
- 新普通窗口默认进入独立空间，可设为加入现有；这与“超过 8 窗”的溢出策略是两件事。
- 第 9 窗按设置优先真实新建或继续分割；8、16 都不是硬上限。受最小尺寸限制时窗口仍须可访问，不能移出屏外藏起来。
- 来源最后成员移出后的空空间清理必须确认真实完整成员集合，不能把没有可见窗口当空；不批量删除用户原有空桌面。
- Exclude App/Window 不自动移动或平铺；异常窗口不被硬塞入模板。
- Docked 的 WorkRect 不随 UI 显隐改变；Floating 不预留；原生全屏使用整屏。明确 Quit 撤销自动改动、保留用户主动布局意图。

迁窗和排布在实现上解耦，按用户已选管理政策衔接。不能因目标窗口不支持 resize 而禁止切空间。创建/删除需独立能力与验收；其未达标不抹掉已验证的基本切换，也不能把整体工作标为完成。

## D10｜系统兼容与多屏

用经过验证的系统版本/架构矩阵、符号/结构探测和 helper 隔离取代永久单一 build 白名单。只对实测组合报告支持；未知或失败版本按动作局部降级，暂时故障应退避重试。不得宣称任意未来 macOS 兼容。

独立 Spaces 开启时，操作正确目标屏；关闭时尊重原生跨屏联动。镜像屏按逻辑显示器处理，不伪造额外独立空间。旋转、缩放、负坐标与插拔使用已有坐标转换并补实际覆盖。操作期间拓扑变化先读回，不按旧序号猜回程。

## D11｜权限、安装和分发

固定 Host/helper 的 bundle ID、安装路径和签名身份。屏幕画面与 AX 控制分开引导；不为窗口功能索取完全磁盘访问或不必要的输入监控。

开发签名候选可完成内部功能验收，必须是真正安装并通过 Launch Services 启动的 Nearpane。已有授权的验收进程不能代替交付身份。公开分发采用 Developer ID + 公证；公证不同于 App Store 审核。无发行证书不应阻止实现和内部验收，但不得因此宣称可公开发布。

可逆的测试窗口、测试空间、构建和候选安装属于开发验收范围。系统必须账户所有者确认的 TCC 操作，只在所有其他可完成工作准备好后集中提出最小必要动作；不得修改 TCC 数据库或借另一已授权应用身份代替产品。

## D12｜来源

- [ISS v3.1](https://github.com/jurplel/InstantSpaceSwitcher/releases/tag/v3.1)；[ISS.c](https://github.com/jurplel/InstantSpaceSwitcher/blob/f7616e42651b1ed8d81625e3640eceed6efa8018/Sources/ISS/ISS.c)；[MIT](https://github.com/jurplel/InstantSpaceSwitcher/blob/f7616e42651b1ed8d81625e3640eceed6efa8018/LICENSE)。
- [yabai macOS 27 更新](https://github.com/asmvik/yabai/commit/b2dc8b4c892d74738a6e865d73048ed2dc3c9ed1)；[窗口迁 Space 实现](https://github.com/asmvik/yabai/blob/b2dc8b4c892d74738a6e865d73048ed2dc3c9ed1/src/space_manager.c)；[CHANGELOG](https://github.com/asmvik/yabai/blob/b2dc8b4c892d74738a6e865d73048ed2dc3c9ed1/CHANGELOG.md)；[SIP 边界](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection)。
- [Hammerspoon Spaces](https://www.hammerspoon.org/docs/hs.spaces.html)；[Rectangle](https://github.com/rxhanson/Rectangle)；[AltTab](https://github.com/lwouis/alt-tab-macos)；[AeroSpace workspace 语义](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces)。
- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/scshareablecontent)；[Spaces 变化通知](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)；[公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution/)。

