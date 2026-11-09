# P4 真实 Spaces 与窗口编排准入

**合成几何与命中实验可复跑。真实 Spaces 观察接入、切换和指定窗口激活继续 BLOCKED，等待 P1-Core Gate。** 本轮从当前工程分支读取三条 P1 实验分支的固定 Git 对象。没有切换分支、调用真实 Spaces API、激活用户窗口或修改 Mission Control。副屏的展示窗口仅属于 P3.8 原生验收。[P1 只读基线](../P1-READONLY-BASELINE-20261109.md) · [P1 技术准入审查](../../docs/reviews/P1-TECHNICAL-GATE-REVIEW.md) · [视觉权威](../../design/NEARPANE-VISUAL-AUTHORITY.md)

## P1 能力矩阵

| 能力 | 历史实证 | 缺口及对 P4 的约束 |
| --- | --- | --- |
| 显示器与 membership | macOS 27.0、26A428，`separateSpaces=false`。两次真实只读采样，两个 display scope 均能关联公开 UUID，内部记录分布 3+1。可见且有正面积的 layer-zero 窗口有 18/18、14/14 取得非空 membership。 | 当前可见只是采样子集。非当前窗口、空 membership、多 Space 返回和 raw type 的用户语义仍未知。不能直接生成四个真实桌面行。 |
| 私有 ABI、selector、所有权 | P1-A `0a704fd7aef3155152e4ac793165780ca17048df`，修正后的证据限固定 selector 7，15 类输入、45 行矩阵，离线转换、CF 类型和夹具所有权有收据。 | 历史特权样本曾枚举 selector 且暴露无符号最大值被读为 -1，已从准入证据中排除。纠正后真实 SkyLight 调用为零；系统对象的 Copy 所有权、连接生命周期、睡眠唤醒未验证。 |
| 用户看到的 Space 与 scope 的对应 | P1-B `545c1185b06a5b7f76d43a0d0d576d4b673725b4`，合成 15 个事件、12 个样本，其中稳定 3、瞬态 8、稳定但不完整 1。 | 原收据的行为实验为 NOT TESTED。两种 separate-Spaces 配置下，跨屏同步、独立切换、全屏及 3+1 用户语义仍缺设备观察。 |
| 坐标、窗口身份与前后层级 | P1-C `89073c3095e304dd0c219d72668225f0112b3712`，43 项测试通过，纯几何/身份、Release 及静态边界通过。 | 可见测试窗口当时未构建、未启动。实时 AX↔CG 匹配、几何校准、指定窗口激活、Space 切换均为 NOT TESTED。 |
| 本轮 Nearpane 投影 | 对已明确指定的合成 Space、可用几何和顺序完成 4 个实验，分别纳入集成及独立 Host 测试。 | 代码只在测试 target。当前 Host 仍使用 `UnavailableDesktopProvider`，实际动作能力关闭。 |

三组历史收据来自各提交内的 `experiments/macos-spaces-abi/evidence/20261109/p1-abi-summary.json`、`experiments/p1-spaces-behavior/evidence/fixture-verification.json` 和 `experiments/window-geometry/evidence/20261109-preparation-05/receipt.json`，可用 `git show <提交>:<文件>` 离线核对。

## 最小 Adapter 契约

1. **观察快照。** 沿用 `DesktopSnapshot` 的 session、revision、采样起止、拓扑指纹、一致性和 freshness。增加或提供由观察来源证明的“用户可见 Space 与 display scope”对应关系。保留 unknown、transient、stale 和 unsupported，按系统 build、配置、权限与操作独立报告能力。失去证据时清空相应可操作目标。[现有快照与能力](../../Sources/NearpaneCore/DesktopObservation.swift)
2. **显示器与几何。** 由 Adapter 将 CG、AX、AppKit 的坐标统一为目标显示器局部、左上原点的逻辑点。公开的 global frame、scale、rotation 与真实可用桌面矩形都须绑定同一快照；可用矩形可能因菜单栏或 Dock 有偏移。每行使用对应显示器的可用区域和统一缩放，窗口只在边界裁剪。负原点和横竖屏不可以重复翻转或重复旋转。[现有布局](../../Sources/NearpaneCore/Layout.swift)
3. **窗口与可点区域。** 提供 Space membership、窗口 session 内身份、所属进程生命周期、唯一的 AX↔CG 匹配、显示器局部 frame 及可信前后顺序。仅相同标题、应用名或 URL 不能区分同一应用的两个窗口。显式记录层级不明、完全遮挡和身份不唯一。已知窗口的可见区域按真实前景遮挡做几何减法；完全遮挡的窗口在本模型中无可点区域，此视觉门槛保留未满足。
4. **动作提交。** 观察与动作 Adapter 分离。已有 `DesktopTarget` 带 session、revision、runtimeID；将来提交时仍需核对 scope/Space、拓扑和窗口进程生命周期，并重新确认目标及能力。一次用户点击只指向一个明确目标。动作后的稳定观察须能确认指定 Space 或窗口；失效、歧义、用户改变桌面或超时都返回未确认。P4 现场实验通过前继续使用现有的 unsupported 动作实现。

## 合成验证

`FixtureSpacePreview` 只接受源为 `synthetic-fixture`、身份可信且新鲜的完整快照。夹具显式列出每一行所代表的 Space、显示器可用边界及前后顺序。未知 membership、缺失或重复的 z-order、会话/revision/拓扑变化及过期快照均拒绝命中。现有 P2 的内部 Space 记录不会自动被解释成真实用户桌面。[实验实现](../../Tests/NearpaneCoreTests/FixtureSpacePreview.swift) · [四个实测用例](../../Tests/NearpaneCoreTests/SpacePreviewTests.swift)

| 场景 | 验证结果 |
| --- | --- |
| 全宽、全高、未铺满和部分重叠 | 单一缩放系数、局部可用边界裁切和留白符合给定 frame。前景、可见后景、桌面空白各命中预期身份，行内留边无目标。 |
| 两至六行、负原点的竖屏 | 行数与显式 Space 数一一对应。增加行数只压缩下方预览，各行仍在桌面区内，640×720 窗口保留宽高比。 |
| 快照与身份失效 | 缺失或重复排序、未知归属与瞬态数据拒绝建模；新 revision、新 session、拓扑变化和超时均拒绝旧目标。 |
| 2/3 与 1/3、同应用完全遮挡 | 前景与相邻窗口保留 96/48 的宽度。后方同应用窗口仍保留原 frame，但没有可点区域；前景外的实际可见部分可以精确命中。 |

工程提交为 `32f234cf8084f17c70ab8a3bf359f76229bf9743`。最终集成回归 85/85、独立 Host 53/53，全量指标见 [P3.8 收据](P3.8-native-experience-closeout.md)。仅四个几何试验使用合成窗口身份，均无 OS 桌面操作接口。

## 允许进入真实实现前的最小条件

- 在专用测试登录会话或设备上明确授权**只读桌面元数据和自建测试窗口**。记录该 build 的 ABI、selector 7、对象类型和连接/释放行为；两种 separate-Spaces 模式分别取稳定的前后快照，证实 3+1 中每个已支持记录与真实 Space 的关系。更改系统模式可能需要注销，须另行授权。
- 在同一专用测试环境，单独授权**移动、调整大小和激活自建窗口**以及必要的辅助功能权限。至少覆盖同应用双窗口、双屏、旋转与重叠，按 P1 标准测量位置和宽高误差各 ≤2 逻辑点、往返误差 ≤1 点，并验证实际命中和前后顺序。
- **切换真实 Space 和跨 Space 激活**另需明确授权。记录用户动作前后的目标、两个 scope 的 current、窗口归属及前台所有权，再测一次过期目标拒绝和能力降级。两种模式及失败恢复均有证据后才申请 P1-Core 放行。全屏、镜像、Stage Manager、插拔、虚拟显示器和其他系统 build 继续按项准入。

现有主屏保留给用户；上述设备实验本轮均未执行。
