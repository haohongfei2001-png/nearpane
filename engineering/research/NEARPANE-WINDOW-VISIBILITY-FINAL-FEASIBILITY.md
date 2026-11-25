> **Route superseded 2026-11-26.** [Current independent replacement decision](NEARPANE-INDEPENDENT-STAGE-DECISION.md) governs. Keep the observations below as historical evidence; do not reactivate Apple Native Integration, Corner, shields, or a fallback on their basis.

# 第三方窗口逐窗隐藏与恢复的可行性

本次比较针对 Nearpane 5.22（90）的逻辑调度组。合格的机制要让同进程的两扇普通窗口可以分属不同组，并让未参与切换的窗口继续接收原来的输入。Dock、原生 Space、窗口内容、尺寸、位置和所有者都要有独立读回。测试使用真正经 Launch Services 注册的两个签名 App、macOS WindowServer 和 Dock。产品工程的起点为 PR #15 的 `bc991d5`。 [已有架构裁决](NEARPANE-WINDOW-VISIBILITY-FINAL-ARCHITECTURE.md) · [此前的三组窗口验收](../verification/stage-groups/5.22-90/isolation/RESULTS.md)

**裁决为 NO-GO。唯一推荐是继续采用现有可见性提供器边界，保持第三方窗口隐藏写入关闭。** 三个候选都触发了产品硬门槛。A 的公开 API 最接近要求，失败点是恢复时抢走真实键盘输入；B 的普通外部连接不能完成隐藏或恢复；C 改变了原生 Space 归属，并允许鼠标事件送达停放窗口。 [macOS 26 原始判定](../verification/stage-groups/visibility-feasibility/runs/44866013086/macos-26/summary.json) · [macOS 27 原始判定](../verification/stage-groups/visibility-feasibility/runs/44866013086/xcode-27/summary.json)

## 实际环境与结论

| 环境 | 实际执行 | 证据范围 |
| --- | --- | --- |
| macOS 26.7.2（25G332） | 托管独立 GUI，SIP 关闭，Stage Manager 偏好缺省，Dock 最小化到应用图标开启 | 271 条有序事件，其中 112 次为独立窗口快照。 [逐项读回](../verification/stage-groups/visibility-feasibility/runs/44866013086/macos-26/replay.json) |
| macOS 27.0.1（26A434） | 相同隔离条件，SIP 关闭 | 271 条事件，112 次独立快照，三项关键失败均复现。 [逐项读回](../verification/stage-groups/visibility-feasibility/runs/44866013086/xcode-27/replay.json) |
| 物理 macOS 27.0（26A428） | SIP 开启，Stage Manager 关闭，Dock 既有偏好开启。已实测动态符号与类的存在、开发构建签名，以及四个实时入口在日常登录会话拒绝派发 | 精确版本缺少独立图形登录会话。窗口、输入和虚拟显示器实测为 BLOCKED。 [本机前后只读收据](../verification/stage-groups/visibility-feasibility/exact-26A428-preflight.json) |

**A · AXMinimized。** 两套系统中，A1 保持工作时，A0 的 AX、所有者及屏上清单均确认单窗最小化。原位置的真实点击只由底下的 B0 接收。恢复 A0 后，内容标记、位置、大小、原生 Space 和其他窗口均保留，Dock 图块从基线到隐藏、恢复一直是 0。恢复之前焦点在 A1，恢复之后、进行任何用户点击之前，AXFocusedWindow 和实际键盘接收者均变成 A0。另一个独立试验直接最小化正在输入的 A0，按键落在 A1。将两窗都设为最小化后，真实点一次 A 的 Dock 应用图标，只恢复了 A1；观察阶段管理器写入数为 0。这个行为仅适用于测过的普通 AppKit 夹具。 [隐藏、恢复、按键及 Dock 逐事件原件](../verification/stage-groups/visibility-feasibility/runs/44866013086/xcode-27/observations.jsonl.gz) · [Apple 的窗口最小化属性](https://developer.apple.com/documentation/applicationservices/kaxminimizedattribute)

**B · SkyLight。** 每个系统分别用四种直接调用方式测试冷启动主连接、初始化 AppKit 的主连接、建立 NSApplication 的主连接及单独分配的连接。每种方式对外窗 Out 和 In 都返回 1000。第五种方式分别提交排序事务。五种方式请求隐藏后，A0 仍在屏上、有序且能收到真实点击；由所有者独立确认已隐藏 A0 后，再用同一外部连接请求恢复，五种方式均未将它恢复，原位置的点击只落到 B0。独立连接有配对的释放读回。所有者使用自己连接时，原始 Out/In 均返回 0，WindowServer 和屏上清单确有变化，但 Out 期间 AppKit 的 isVisible 仍为真，恢复原排序后也不能保证鼠标重新命中 A0。所有者通过 AppKit orderOut 后，已持有的 AX 引用还可能失效，而重新枚举又能找到同一 CGWindowID。这两套环境界定了普通客户端的实测能力。错误码 1000 的内部判定原因仍为 UNKNOWN。没有进入外部排序的双窗扩测。 [原始请求、连接和鼠标收据](../verification/stage-groups/visibility-feasibility/runs/44866013086/macos-26/replay.json)

**C · Hidden Virtual Display。** 创建 800 × 600 虚拟显示器后，独立读取的共享边长是 0。A0 被 AX 移到虚拟屏时仍是 WindowServer 的有序窗口，原生 Space 在最终两套试验中均从 1 变为 23。A1 仍可输入，原物理位置的点击由 B0 接收。通过系统绝对坐标把指针定位到虚拟屏后，一次真实鼠标事件被 A0 接收。物理鼠标自然划过角点未测试。Apple 的 Mission Control 在两种拓扑下都能打开和退出；停放期间系统额外登记了显示器及活动 Space。正常清理时窗口位置、原归属与拓扑均恢复。 [虚拟屏窗口、事件及恢复明细](../verification/stage-groups/visibility-feasibility/runs/44866013086/xcode-27/replay.json)

## 固定提交的源码解释了哪些差别

| 项目及版本 | 实际接受写入的对象、调用方和读回 |
| --- | --- |
| yabai `b2dc8b4` | 额外连接用于 yabai 创建的动画代理。对外部实际窗口的排序有另一条路径，通过载入 Dock 的 scripting addition 派发。其文档说明这部分功能需要调整 SIP。普通独立客户端不具备同样的调用条件。 [动画与代理](https://github.com/asmvik/yabai/blob/b2dc8b4c892d74738a6e865d73048ed2dc3c9ed1/src/window_manager.c#L607) · [排序实现](https://github.com/asmvik/yabai/blob/b2dc8b4c892d74738a6e865d73048ed2dc3c9ed1/src/osax/payload.m#L858-L870) · [运行前提](https://github.com/asmvik/yabai/blob/b2dc8b4c892d74738a6e865d73048ed2dc3c9ed1/README.md#L60) |
| Winby `83b8390` | Swift 源码有 `SLSOrderWindow` 声明。固定提交中的窗口选择执行应用激活、指定窗口聚焦与 AXRaise；全仓 Swift 调用点检查只找到这一条排序声明。其选择窗口的效果不能证明外部客户端可以独立隐藏第三方窗口或维持原焦点。 [符号声明](https://github.com/obra/winby/blob/83b8390ff6b7c06028db0b2ec74b6e2c7b1a065e/Sources/Winby/PrivateAPIs.swift#L24-L25) · [选择入口和焦点实现](https://github.com/obra/winby/blob/83b8390ff6b7c06028db0b2ec74b6e2c7b1a065e/Sources/Winby/WindowManager%2BFocus.swift#L675-L753) |
| JankyBorders `a7297ca` | `SLSWindowIsOrderedIn` 查询外部目标，事务将本进程创建的边框窗口相对目标排序。能查到外窗，或能把自有边框排在外窗附近，都没有改变外窗自身的可见性。 [可见性读取](https://github.com/FelixKratz/JankyBorders/blob/a7297ca7d1933f3a30b12e8f10750e8d84eeee1e/src/border.c#L189) · [边框排序事务](https://github.com/FelixKratz/JankyBorders/blob/a7297ca7d1933f3a30b12e8f10750e8d84eeee1e/src/border.c#L235-L244) |
| AgentDesk `a5f9c70` | E8 在 SIP 开启的 macOS 26.5.2 上记录了外部排序不生效，自有窗口的位置写入另有正对照。实际架构创建虚拟显示器，用 AX 移动已登记测试进程的窗口，适用场景包括另起应用实例。窗口仍在一块真实参与系统调度的显示设备上。其守护进程对新窗口按进程归属处理，不能直接用于含用户旁窗的任意应用进程。 [E8/E9 原始记录](https://github.com/makors/agentdesk/blob/a5f9c705caf51240cbf428c481b55875587cdece/docs/RESEARCH-LOG.md#L45-L52) · [显示器与坐标](https://github.com/makors/agentdesk/blob/a5f9c705caf51240cbf428c481b55875587cdece/src/hidden-display.m#L16-L51) · [新窗口处理](https://github.com/makors/agentdesk/blob/a5f9c705caf51240cbf428c481b55875587cdece/src/agentdesk-daemon.m#L24-L45) |

`kCGSOrderOut` 取 0，`kCGSOrderIn` 取 2。实验区分恢复已有排序位置与显式提到最前。每个外部变体使用独立进程，同一进程持有自己的连接直至隐藏、恢复及读回结束。冷启动主连接在首次访问 AppKit 窗口系统之前建立。其他变体分别调用 `NSApplicationLoad`、建立 NSApplication、创建并释放独立客户端连接，或在主连接提交事务。代码使用得到确认的调用参数，事务返回寄存器的数值没有稳定的状态语义，判定使用窗口和输入收据。 [排序枚举](https://github.com/NUIKit/CGSInternal/blob/c4f6f559d624dc1cfc2bf24c8c19dbf653317fcf/CGSWindow.h#L48-L53) · [固定来源与 Git blob](../verification/stage-groups/visibility-feasibility/pinned-sources.json) · [独立连接及事务生命周期](../verification/stage-groups/visibility-feasibility/poc/Order.m)

## 测量方法

- 两个夹具 App 均为普通签名开发 App。进程 A 有两扇同类文档窗，B 有普通旁窗和位于 A0 后方、不会获得键盘焦点的鼠标接收窗。每扇窗都有独立内容标记、按键和鼠标计数器。观察器核对 bundle、可执行路径、进程出生时间和实际 CGWindowID。全部鼠标及键盘测试只针对登记夹具，Dock 点击还须命中精确 bundle 路径对应的应用图标。 [签名与监督程序](../verification/stage-groups/visibility-feasibility/poc/run.py) · [窗口所有者](../verification/stage-groups/visibility-feasibility/poc/Fixture.m)
- 设置初始焦点后才开始测量。对每次动作分别读取 WindowServer 有序状态、CG 全量及屏上列表、AX、前台进程、实际 AXFocusedWindow 的 CGWindowID、所有者侧状态、原生 Space ID、Dock 图块和窗口几何。另一个进程从初次登记起持续保有 AX 窗口引用。物理屏原位置上的真实鼠标事件由接收者记账，键盘测试也记录具体接收窗口。用户动作造成的焦点变化与程序自行造成的变化分段记录。 [独立观察器](../verification/stage-groups/visibility-feasibility/poc/Inspect.m)
- Dock 偏好只在一次性登录会话设为“将窗口最小化至应用程序图标”。测试结束恢复原始类型、值或缺省状态。虚拟显示器只以会话级配置注册，由独立进程持有。恢复窗口及指针后销毁虚拟显示器，并从独立进程核对拓扑、几何和原生 Space。 [虚拟显示器夹具](../verification/stage-groups/visibility-feasibility/poc/Display.m)

## 崩溃与系统干预

在另外两个新登录会话中分别终止执行最小化的进程和持有虚拟显示器的进程。A0 在 AX 执行器被 SIGKILL 后保持最小化。新的执行器核对日志中的 PID、进程代际、窗口编号、内容标记和原生 Space 后恢复了它，几何和内容一致，下一次按键仍被恢复的 A0 取走。C 的持有者被 SIGKILL 后，两个系统都撤下了虚拟屏并自行将该夹具窗口带回原显示器、原 Space 和原位置；记录了显式清理前的结果。两次单窗结果限定在本次夹具及这两个构建。 [macOS 26 崩溃收据](../verification/stage-groups/visibility-feasibility/runs/44866419114/macos-26/summary.json) · [macOS 27 崩溃收据](../verification/stage-groups/visibility-feasibility/runs/44866419114/xcode-27/summary.json)

真实 Mission Control 截图上，主屏有 A1、B0、B1，新增显示器有自己的一条 Desktop 栏和停放的 A0。Nearpane 若采用 C，用户仍可在原生概览对应的显示器上看见“隐藏”窗口。 [主屏截图](../verification/stage-groups/visibility-feasibility/runs/44866419114/xcode-27/C.crash.withVirtual-display-1.png) · [虚拟屏截图](../verification/stage-groups/visibility-feasibility/runs/44866419114/xcode-27/C.crash.withVirtual-display-2.png)

## 九项评分

2 表示该项在所列条件下达到要求，1 表示部分成立或有明确约束，0 表示存在反例或必要前提不成立，问号表示缺少该条件的独立验证。分发、维护两行为工程风险评价；实际运行能力分别列示。任何窗口、输入、Space 硬门槛失败均阻止产品采用，分数不作加权平均。

| 维度 | A · AXMinimized | B · SkyLight 外部排序 | C · 虚拟屏停放 |
| --- | --- | --- | --- |
| 逐窗隔离 | 2 · A0 单独最小化/恢复，可见性、内容及几何可读回 | 0 · 五种外部调用均不能完成 Out/In | 0 · 窗口仍有序且进入另一原生 Space |
| Dock | 2 · 测试偏好下全程 0 个窗口图块 | ? · 排序未生效，无有效隐藏后的 Dock 样本 | 2 · 此次停放图块数稳定 |
| 鼠标与键盘 | 0 · 隐藏时命中正确，恢复抢焦点和实际按键 | 0 · 原窗口仍收到真实点击 | 0 · 绝对定位后真实点击到达停放窗 |
| 同应用多窗 | 1 · 旁窗状态保存，但跨窗恢复抢焦点；一次 Dock 点击只还原 A1 | 0 · 外部单窗门槛已失败，双窗扩测未执行 | 1 · 同进程的 A0、A1 可分显，归属与输入门槛失败 |
| 多显示器 | ? · 两块实体显示器独立切换未测 | ? · 无可用的单窗操作供组合测试 | 1 · 已测主屏加虚拟屏及回收；两块实体屏、热插拔未测 |
| macOS 26/27 兼容 | 1 · 两套托管系统都可最小化，也都复现抢焦点 | 0 · 两套系统均拒绝或不应用外窗变化 | 1 · 两套系统都能创建虚拟屏，也都改变原生 Space |
| 崩溃恢复 | 1 · 系统保留最小化，日志恢复窗口，焦点仍改变 | ? · 缺少成功的外部状态变更供恢复 | 2 · 两次单窗持有者被终止，系统自行恢复原显示器、几何及 Space |
| Developer ID / 公证风险 | 2 · 公开 AX，需辅助功能权限；本轮无发行或公证结论 | 0 · 关键排序依赖无稳定公开保证的私有接口 | 0 · 依赖私有虚拟显示器类及其生命周期 |
| 长期维护 | 2 · 公开 API，用户 Dock 动作及最小化原始状态仍需核对 | 0 · 私有 ABI 与连接归属需按系统构建重新验证 | 0 · 需跟踪私有类、拓扑、坐标、输入及 Space |

Apple 将公证与面向 App Store 的 API 规则分别定义。当前评分不预判 Apple 对某份二进制的公证结果。本轮环境使用开发签名；公证与发行归入 P6。 [Apple 公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) · [App Review Guidelines 第 2.5.1 节](https://developer.apple.com/app-store/review/guidelines/#software-requirements)

## 正式实施计划与停止条件

1. **当前发布门槛。** 保持 StageGroup 的可见性提供器关闭。生产端沿用已有同屏精确选窗、分组记录和布局能力，整组切换不计为已交付。R4、正式 App、日常配置、安装回滚包与 P6 分发工作不在本次 PoC 的修改范围内。 [原有架构的提供器契约](NEARPANE-WINDOW-VISIBILITY-FINAL-ARCHITECTURE.md#module-contracts)
2. **重新开启写入的前提。** 只有获得新的可复现机制，才在独立登录会话启动下一轮资格验证。先让 A1 持续接收输入，对同进程 A0 执行一轮隐藏与恢复，全程同时检查实际输入、Dock、原生 Space、AX 引用及 CGWindowID。补齐 SIP 开启的准确系统构建、多品牌普通应用与两个物理显示器。一次失败即记录机制与适用范围。关闭 Stage Manager、事后重新抢焦点或要求用户改 Dock 设置都不能消除本轮反例。
3. **通过单窗后再集成。** 将唯一通过资格的提供器接入现有事务及写前日志，复用 Display → StageGroup → Window。每次动作绑定进程代际、CGWindowID、显示器、活的 AX 引用和原位置。先记录用户已有最小化状态；用户点击 Dock、窗口生命周期变化、人工恢复或原生 Space 改变时交还控制。不能确认所有权的日志保留为待核对，不回写窗口。先做一次同应用双窗和跨应用组切换，然后分别进行 10 次、50 次独立输入及恢复验收。
4. **回退与分发。** 通过能力开关停用写入，只恢复具有本次动作凭据、匹配当前代际且没有用户干预的窗口。保留失败收据，验证崩溃恢复、显示器拔插和原生 Mission Control 后才进入 P6。签名分发、公证和正式安装版验收有独立门槛。

可离线重放每个动作、键盘落点、鼠标接收者及清理结果。全部失败和中止试验、原始日志、源码、哈希及固定依赖见证据目录。 [证据目录与复查命令](../verification/stage-groups/visibility-feasibility/README.md)
