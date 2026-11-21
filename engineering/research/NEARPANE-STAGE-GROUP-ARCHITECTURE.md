# 调度组架构裁决与源码差异

## 窗口调度引擎实施复核

本次重新核对 Draft PR 实际起点 `74f1d0a`。产品原有入口位于 `DesktopSurface.windowList` 与 `NativeSpaceNavigator.NativeWindowGroupCard`。单窗和组合成员调用精确选窗，组合背景没有整组显示权限。原目录从当前窗口集合投影，窗口从该集合消失后，身份线索和历史图像都不足以授权一次恢复。

| 层 | 已落地的边界 |
| --- | --- |
| 身份和作用域 | `StageGroupStore` 为现有成员增加普通桌面 UUID。目录按物理显示器和只读的普通桌面 UUID 查询；表内持久组 UUID 与系统 UUID 各自独立。v2 单独写文件，首次读取 v1 保留成员槽位、组 ID 和布局。只有完整重新绑定的成员集才能补齐旧组的桌面归属。 |
| 原生移动 | 已保存成员被观察到跨显示器或跨桌面时保留成员，标记待整理，撤销该组的活动标记。用户可将被移动的成员重新归入实际屏幕和桌面。共享 Spaces、多显示器拓扑不明确、全屏、系统台前调度状态未知时继承只读或暂停策略。 |
| 事务 | `StageGroupCoordinator` 要求完整当前作用域、存活代际、当前实际键盘焦点、已验证旁窗、明确同意及合格驱动。首次从实际焦点组开始。按序退场、恢复、核实布局，再定位成员。动作前原子落盘，保留可能已派发区间；动作后要求两个新读数，整个作用域通过后才持久化活动组和首选成员。全局键盘焦点共享，因此写事务串行；各屏各桌面的目录独立。 |
| 回滚 | 保存原始与已确认后值，校验整个清单、代际、用户输入世代和作用域；可证明仍归本次操作的效果按逆序补偿。未确认派发、用户后来改变窗口或失去原对象见证时保留待恢复日志，避免自动重放。目录的上次已验证活动组不是当前可见性的证明。 |
| 拖放 | 复用 `DesktopAutomaticTiling.place` 与原窗口管理器。拒绝复用在本次操作之前启动的枚举。两份窗口 AX/CG 读回及之后新目录中的两个绝对矩形都吻合才合并成员。 |
| 点击墙纸 | `WallpaperRevealMonitor` 观察系统桌面点击，在系统移动窗口时暂停 Nearpane 的窗口派发和自动布局。恢复以 WindowServer 窗号、真实屏幕命中、AX 所有者及重复读取为条件；不存储标题或桌面内容。 |
| 生产写入资格 | 受控实验复用公开 AX 最小化或修改位置，没有注册任何已通过正式合同的全局隐藏适配器。事务协议可用，正式 Host 的整组显示、停放窗口的可执行卡片和真实崩溃后恢复仍待验。 |

StageKeeper 固定版本将窗移到最右侧显示器角落，以非激活、鼠标穿透的面板盖住残条。Nearpane 的实验仅在一台单屏托管 Mac 临时采样空角背景，按实际残条宽度、完整覆盖、鼠标命中和焦点检验。移窗 setter 成功与遮罩可见分别记录。该工程的跨屏停放及全桌面面板没有进入产品。 [参考实现的坐标与恢复](https://github.com/ninthspace/stagekeeper/blob/23abfdd45998cbe1edcb3f050fd34516d0be4800/Sources/StageKeeper/Engine.swift#L578) · [参考遮罩](https://github.com/ninthspace/stagekeeper/blob/23abfdd45998cbe1edcb3f050fd34516d0be4800/Sources/StageKeeper/Cover.swift#L44) · [本次实验记录](../verification/stage-groups/5.22-90/isolation/RESULTS.md)

审查基线是 GitHub Draft PR #15 的 `a1a3fc35e1465d8c52bc00da2d916cabd8a82bc7`。该 HEAD 的最后一笔变更为验收文档；此前带源码的原生 CI `7ec2423` 成功。Vercel 网站检查独立于原生合同。以下“现有”指该基线，“裁决”指以后实现与验收的约束。 [审查提交](https://github.com/haohongfei2001-png/nearpane/tree/a1a3fc35e1465d8c52bc00da2d916cabd8a82bc7) · [已核实的原生 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/44852061796)

## 实现差异

| 路径与现状 | 裁决 |
| --- | --- |
| `NearpaneUI/DesktopSurface.swift` 从当前屏的 `activeSpaceWindows` 生成普通单窗卡，已支持明确组合。原生分屏由 `DesktopLiveWindowCard.swift` 的 `DesktopSplitViewCard` 单独绘制。 | 保留 R4 卡和真实预览。组列表由本屏组目录投影；原生分屏走只读分支。 |
| `NearpaneUI/ExplicitWindowGroups.swift` 是内存数组，以 Space UUID 和本次 feed 的成员代际记录两个或更多窗口。没有持久化活动组，读不到成员或 Space 变化可导致解散。 | 引入与 Space 独立的组 UUID、成员槽位与每屏目录。观察不完整只撤销操作资格。 |
| `NearpaneCore/VirtualWorkspaceExperiment.swift` 有文件日志、前后值及恢复规则，后端为合成世界。`Workspace.swift` 同时表达旧 Native/Virtual 模式。 | 复用排他写入、已确认前后值、冲突时保留人工改变的做法。已有 Virtual 日志不导入真实产品组。 |
| `NativeSpaceMenu.swift`、Host 状态菜单、`NativeSidebarNavigation.swift`、`CrossSpaceFocusContinuity` 能把选择交给原生 Space 执行器。`NativeSpaceCatalog` 本身只读。 | 撤出原生选择菜单与跨 Space 拖放。保留只读观测和同桌面串行意图。正式 Host 和 helper 双端拒绝 `select/move`，覆盖历史已准入 OS。 |
| 拖放的真实类型为 `NativeSpaceNavigator.swift` 中的 `SidebarWindowDragAndDrop`，指针入口还经过 `SidebarCardPointer.swift`。旧分流可走同桌面 `SidebarPairDrop` 或跨桌面迁窗。 | 复用同屏坐标、身份核验和 `DesktopAutomaticTiling` 的显式排布。真实排布成功后写组布局；原生迁窗分支退出产品。 |
| `WindowGeometryCore/WindowIdentity.swift`、`DesktopWindowGallery.swift`、`WindowWitness.swift`、`SidebarWindowWitnesses.swift` 和 `HostCurrentWindowFocus.swift` 能分别证明进程代际、窗号、保留的 AX 对象和焦点。 | 保留精确身份和逐窗焦点。窗口读者的一次性 UUID 不能跨重启独自授权写。组内同应用两窗沿用原来 10/10 的输入验证方法。 |
| `WindowContentPreview`、`DesktopWindowGallery` 已按窗口/显示器、可见性及权限回收图像；组合卡按真实矩形投影。 | P3 按确认的成员和本屏布局合成；组内每窗独立验证首帧、实时/历史和失效。 |
| `DisplayPanels`、`DesktopDisplayTopology`、Host 的屏幕变化、activeSpace、睡眠订阅及 `CurrentDesktopWindows` 已有按显示器的观察与面板。部分精确选窗和清单路径只认证单屏/独立 Spaces。 | 复用物理 UUID 与坐标变换。每屏分别维护成员和活动组；共享 Spaces 下只跟随系统联动，未知拓扑暂停写。 |
| 台前调度、Mission Control 可见性与专用快捷键让渡已有实测。 | 系统台前调度开启或所有权不明即停止新窗口写。Mission Control、App Exposé、系统保留的快捷键与手势归 Apple。 |

上表源码位于工程的 [Sources](../../Sources)。旧窗口停放实测和同屏选窗/布局收据分别说明了能复用的能力与已知失败。 [普通 App 停放裁决](../verification/P4.2.2-VIRTUAL-TECHNICAL-VERDICT.md) · [正式同屏证据](../verification/native-spaces/5.22-90-sidebar-pair/RESULTS.md)

已安装的早期候选还做过一次真实的系统台前调度交接。开启系统台前调度后，两次读取 Nearpane 都显示零张窗口卡、零条捕获流，语音和托盘工具继续显示。这个结果可以复用为独占调度的基线。它没有证明 Apple 的内部组 ID 与原生 Space ID 有固定对应关系，当前签名候选也仍需重新验收系统交接。 [历史实机互斥与原始读回](../verification/native-spaces/5.22-90-active-display-previews/RESULTS.md)

## 数据、投影与持久化

- 每个活动资料代拥有一个版本化的 `stage-groups-v1.json`。物理显示器 UUID 持有有序组列表、最后一次已证实的活动组引用；组持有独立 UUID、有序成员、选中成员和对应布局。显示器断开时保存分区，再次连接根据 UUID 和实际 WorkRect 重新计算。
- 每个逻辑成员有稳定 UUID。运行时绑定使用签名所有者、PID/进程出生、CGWindowID 和当前代际的窗口见证。持久化可保存不含标题和路径的身份提示与本屏几何。只有同一仍有效的见证或独立的强重绑证据才可授权操作。Host 重启、App 重启、窗号复用及不唯一的恢复标识使相应成员转为待绑定。目录与布局可以读回；实际写入需要对真实窗口重新绑定。首版允许用户明确重新关联已观察到的窗口，后续可为提供稳定文档身份的应用加入经过验证的恢复适配。
- 同一成员和同一已确认活窗各自最多归入一个组。编辑原子地移出旧组、加入新组，并清除失效的活动引用；空组撤出。单个成员移出时可保留为单窗组。逻辑分组本身没有任何 AX、Dock 或 WindowServer 写权限。
- 活动原生 Space 与窗口 Native Membership 来自外部只读快照，包含显示器、拓扑代际、活动项、成员读数与新鲜度。组不以 Space 编号或 UUID 做主键。当前可用集合由已绑定成员和本屏当前普通 Space 相交得出。跨 Space 或只解析出部分成员的组不得降级成“全组切换成功”。对共享/多桌面窗口可以展示，但解释不唯一时不操纵。
- 布局保存为显示器工作区内的相对几何、顺序和比例。拖放成功后读回两个原窗的 AX 与 CG 框，再记录布局。原坐标、用户已修改的位置和之前就最小化的状态分别保存。摄取全屏、Split View、睡眠或系统接管事件只更改瞬时可用性。
- 持久化沿用活动资料代及其单写者锁，完整验证版本、唯一性和引用后原子替换，落盘失败回退内存变更。旧资料没有组文件时从空目录开始；格式未知或损坏时保留原文件，停止写入。上一版可忽略新增文件。观察中断、权限丢失与暂时看不见的窗口均不触发删除。

## 真窗切换状态机

| 状态 | 必须成立的条件与动作 |
| --- | --- |
| 准入与冻结 | 按屏取得一次意图，在全局单键盘焦点写通道中串行。冻结显示器、活动原生 Space、系统所有权、成员活体、同应用兄弟窗、非参与窗、前台/焦点、AX/CG 几何和用户原有最小化状态。全部成员可被独立复核后才开始。 |
| 写前记录 | 在本资料代单写者日志持久化操作 UUID、原组、目标、成员前值/期望值、原焦点及每一步的提交意图。每步重查上下文；新硬件输入、Space 变化或新选择使旧意图失效。 |
| 展示目标 | 仅恢复此前由 Nearpane 停放且仍与日志吻合的目标窗；恢复其布局，逐窗独立确认。后台组的活窗若系统不允许单窗操作，本次拒绝。 |
| 处理旧组与焦点 | 对旧组中需退场的已登记窗逐项调用经过准入的适配器；核对旁窗，再交给已有同桌面精确焦点路径。应用级 Hide 会同时影响其他组成员，禁止作为退路。 |
| 提交 | 两次独立读回目标组全部可见、原组应退场者不占工作区、旁窗未受影响、原生归属未变；指定窗得到 AX/CG/键盘见证。此后才提交 activeGroup 和布局。 |
| 中断与恢复 | 能证明仍是本次写入且上下文未变时，按逆序补偿；已收到新用户指令、窗口消失或观察不确定时停止，保存待恢复项。重启只重验前后值与所有权，不重放旧切换。退出只撤销 Nearpane 拥有的停放。 |

## 单窗显示与隐藏的裁决

公开跨进程候选限于可设置的 AX 窗口属性与动作。优先验证逐窗 `AXMinimized` 加原位恢复，并以 CG 在屏、AX、所有者回读、原生归属、焦点与旁窗联合验收。在旧的非激活副屏夹具中，setter 返回成功却未观察到预期最小化；另一轮 regular 应用的兄弟窗呈现也发生变化。当时系统台前调度已开启，因果归属尚未证明。移动到屏外、整应用隐藏、给别的 Space 的窗激活应用、私有窗口层级写入均不作为回退。P1 的首轮资格试验限定在系统台前调度关闭的隔离普通桌面，使用两款登记的普通 App、同 App 兄弟窗和第三个不参与窗口。在任一读回不明确时暂缓产品写入。当前没有批准新的私有写适配器。既有只读桥保留逐 OS 校验和不支持时降级。 [Apple AX 写属性](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue) · [旧实验逐窗读回](../verification/P4.2.2-REGULAR-APP-PARKING.md) · [AppKit Space 变化通知](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)

## 首批生产实现

Host 菜单、侧栏弹层、调度组背景点击和跨原生桌面拖入的旧入口已撤下。同屏精确选窗保留在成员上。生产 helper 的链接依赖只保留读取器，Host 和 helper 各自拒绝历史写命令。旧执行器源文件、选择菜单和诊断选择流程保存在归档目录。 [历史实现](../native-spaces/archive)

`StageGroupStore` 在活动资料代的 Nearpane 子目录保存每屏有序的组、成员 ID 和相对可用区域的布局。某个进程的窗号、进程出生时间用作查找提示。运行期窗口代际保存在内存。新观察只补录明确的当前普通窗口；暂时缺窗不删除成员。两扇窗同一原生桌面是当前编辑的准入条件，原生桌面 ID 不进入组文件。已有窗在新屏上被实际观察到后可以显式改归属，此编辑只写目录。 [目录实现](../../Sources/NearpaneCore/StageGroupStore.swift) · [生产窗口源](../../Sources/NearpaneUI/CurrentDesktopWindows.swift)

加入组合只移动所选成员。拖放排布要经过原窗口管理器的实际几何确认，再写组布局。读窗暂时中断时，只有原操作仍持有两扇原窗的 AX 对象并完成独立确认，才可更新这次操作的绑定。重开目录时，当前实现允许用户重新关联具有相同进程出生和窗号提示的窗口。应用重新启动后的跨进程自动恢复、组级停放所有权与活动组提交还需实现。 [侧栏入口](../../Sources/NearpaneUI/DesktopSurface.swift) · [排布后读回](../../Sources/NearpaneUI/DesktopAutomaticTiling.swift)

公开 AX 资格试验已独立读回单窗退场与还原。最小化后的原 AX 对象仍可核对，整个窗口列表的旧筛选不能独自裁决身份。还原改变了目标窗的 key 状态，所以完整组切换还须单独确认焦点和输入。当前没有启用生产组级停放。 [实测与未决项](../verification/stage-groups/5.22-90/RESULTS.md)

当前生产侧栏的编辑还需要只读目录能够确认本屏当前普通桌面。在没有独立数值归属读回的系统上，只读窗口列表与夹具的目录成功不构成正式侧栏切组资格。物理外屏和重新连接尚待设备验收。
