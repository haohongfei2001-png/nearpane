# Nearpane P1 独立技术关口审查

**审查日期：** 2026-11-09  
**审查类型：** Independent Technical Gate Review（文档与证据审查；未执行新的系统操作）  
**审查基线分支：** `spike/macos-spaces-20261109`  
**审查基线 HEAD：** `159dc5b6f1c4d5d511ddf4e4fcac35be2a535f0e`  
**设计基线：** `design/integrated-architecture-20261108` @ `6151eb0209491e23ae550798aa521b7f731fb330`

## 0. 最终关口结论

| 关口 | 结论 | 含义 |
|---|---|---|
| P1 只读基线（macOS 27.0 / 26A428 / ARM64） | **PASS** | 当前设备上的显示器 UUID 对应、SkyLight 只读 inventory、可见窗口 membership 和坐标差异已有两次一致采样证据 |
| 完整真实 Spaces 预览的实现准入 | **BLOCKED** | 尚未证明 separate-Spaces 关闭/开启时的切换语义、完整窗口归属、窗口激活与坐标命中正确性 |
| P2 Host Foundation（不含真实 Spaces 生产能力） | **CONDITIONAL PASS** | 可与剩余 P1 并行推进，但必须使用 mock / fixture Adapter；禁止接入私有 API 写操作、真实 Space 切换和生产窗口激活 |
| Nearpane 整体架构 | **CONDITIONAL PASS** | Host/Domain 边界正确；P4 前必须补齐坐标变换契约、快照一致性与窗口身份映射契约 |

**总裁决：P1 不能关闭，完整 Spaces Preview 不得标记 VALIDATED；但不需要冻结 Nearpane 全部工程。允许启动受限的 P2 Host Foundation，与 P1 后续验证并行。**

本审查没有运行新的探测、改变桌面状态、修改系统设置或执行窗口激活。结论基于指定 P1 分支中的基线报告、脱敏 JSON、探测源码、Spaces 技术可行性报告、整体架构和工程路线。

---

## 1. 两块显示器分别出现 3 和 1 条 Space 记录，且 separateSpaces=false，实际证明什么？

### 1.1 已经证明的事实

P1 两次样本均报告：

- `NSScreen.screensHaveSeparateSpaces == false`；
- 公开 API 检测到 2 个活动显示器；
- SkyLight 返回 2 个 managed display scopes；
- 两个 scope 的 Display Identifier 分别匹配公开显示器 UUID；
- Scope 1 有 3 条 Space 记录，Scope 2 有 1 条；
- 每个 scope 都有一条被标记为 current 的 Space 记录；
- 两次采样的 scope 数量、UUID 对应关系和 Space 记录数保持一致。

这足以证明：**在 macOS 27.0（26A428）本次测试配置下，SkyLight managed display inventory 暴露了两个可分别关联到公开显示器 UUID 的管理 scope，其 Space 列表长度分别为 3 和 1；这个内部 inventory 形态不等于 separate-Spaces 设置布尔值。**

这是一项有价值的真实系统观察，足以否定以下错误假设：

- separateSpaces=false 时，SkyLight 必然只返回一个 display scope；
- 一个 managed display scope 必然对应一条 Space；
- 将两个 scope 的数组长度相加，就得到用户可独立切换的 Space 总数。

### 1.2 尚不能证明的事实

**不能据此宣称用户有 4 个彼此独立的桌面。** 也不能证明第二块显示器的单条 Space 记录代表：

- 独立于第一块显示器的一个 Space；
- 与第一块显示器某个 Space 共享的映射；
- 共享桌面模式下的显示器局部投影；
- 或者 WindowServer 内部用于 display scope 管理的特殊占位/当前状态。

同样不能仅凭两个 scope 都有 current 标记，就推断两块显示器可以独立切换。

需要把概念拆开：

1. **Managed display scope**：SkyLight 内部管理分组；
2. **Space record**：某个 scope 中的内部 Space 记录；
3. **User-visible Space / desktop transition**：用户实际通过 Mission Control 或快捷键看到的桌面切换语义；
4. **Window membership**：某个窗口被私有查询关联到的一个或多个 Space ID。

它们之间的映射尚未被行为实验完整证明。

### 1.3 本问题的裁决

<badge>CONDITIONAL</badge> 3+1 结果可用于继续构建只读解析器和测试夹具；**不得用于确定产品 Space 数量、跨屏共享规则或切换目标语义。** 这部分必须由受控切换实验裁决。

---

## 2. 当前窗口 membership 是否足以支持真实 Space 预览的下一步实现？

### 2.1 当前结果的价值

两次采样显示：

| 指标 | Sample A | Sample B |
|---|---:|---:|
| Layer-zero 窗口记录 | 291 | 285 |
| 返回非空 membership 的记录 | 46 | 43 |
| 当前可见且正面积窗口 | 18 | 14 |
| 上述可见窗口取得非空 membership | 18 | 14 |
| 上述可见窗口 unresolved | 0 | 0 |
| 返回 inventory 外 Space ID | 0 | 0 |

这证明在两个样本时刻，所有被探测器判定为“当前可见且正面积 bounds 的 layer-zero 窗口”均取得非空 membership，且返回 ID 可以在当次 inventory 中解析。对只读观察器来说，这是积极结果。

### 2.2 为什么仍不足以实现真实预览

不够。至少存在六个未关闭的问题：

1. **样本覆盖范围不完整**：全部 layer-zero 窗口只有 46/291、43/285 返回非空 membership。剩余记录没有分类，不能默认它们是系统窗口、无效窗口或当前 Space 的成员。
2. **可见不等于完整**：当前屏幕可见窗口的 membership 已取得，不代表 offscreen、最小化、隐藏、全屏、跨 Space 或过渡态窗口的归属完整。
3. **membership 语义未行为验证**：尚未证明一个窗口返回多个 Space ID 时，代表真正跨多个用户可见 Space，还是私有 API 的其他内部语义。
4. **窗口到显示器归属未闭环**：bounds 与 display scope 的关联需要通过旋转、跨屏窗口、窗口边界相交和窗口迁移实验校验。
5. **坐标变换未完成**：第二块显示器旋转 90°，AppKit 与 CoreGraphics 坐标原点不同。现在只证明“不能直接混用”，尚未证明转换公式和点击命中区域正确。
6. **动作目标没有验证**：membership 读取成功不等于可以可靠切换 Space 或激活窗口。

### 2.3 允许的下一步

允许实现一个**只读、非 UI 生产依赖的 Space/Window Snapshot Parser**，并建立 fixture 测试：

- 解析 managed scopes 和 Space records；
- 保留原始 ID 的会话内身份，不持久化为用户稳定 ID；
- 保留 membership 的 0 / 1 / 多条结果；
- 将 unknown / unresolved / stale / transient 显式表达；
- 对窗口 bounds 执行纯函数坐标转换实验；
- 使用合成窗口和合成 Space fixture 测试布局计算。

暂不允许：

- 把 3+1 直接显示成 4 个独立桌面；
- 对未分类 layer-zero 窗口强行分配 Space；
- 以 membership 返回非空作为可点击窗口的唯一条件；
- 启用真实 Space 点击切换或窗口激活。

**结论：membership 足以支持只读 Adapter 的下一轮实现，不足以支持面向用户的真实 Space 预览实现。**

---

## 3. SkyLight 私有 API 的调用签名、selector、数据类型和生命周期还需要哪些验证？

P1 探测器使用动态符号解析，声明大致为：

- `SLSMainConnectionID: () -> Int32`
- `SLSCopyManagedDisplaySpaces: (Int32) -> Unmanaged<CFArray>?`
- `SLSCopySpacesForWindows: (Int32, Int32, CFArray) -> Unmanaged<CFArray>?`
- membership selector：`0x7`

指定版本的 yabai 源码提供了重要交叉参考：

- `SLSMainConnectionID(void)` 返回 `int`；
- `SLSCopyManagedDisplaySpaces(int cid)` 返回 `CFArrayRef`；
- `SLSCopySpacesForWindows(int cid, int selector, CFArrayRef window_list)` 返回 `CFArrayRef`；
- yabai 使用 selector `0x7`；
- yabai 构造 window list 时使用 `CFNumberSInt32Type` 包装窗口 ID。

这只能证明 Nearpane 当前声明与一个固定版本第三方实现的声明形式一致，**不能证明 Apple ABI 合约，也不能证明所有系统版本保持一致。**

### 3.1 必须补充的验证项

**A. C ABI 与参数宽度**

- 在测试代码中用 C shim / Clang 声明复核真实 C 类型宽度和 Swift 函数指针 ABI；
- 确认 `int` / `Int32`、窗口 ID 的宽度、Space ID 的 64-bit 解析和有无符号转换；
- 不要把 Swift 的 `[NSNumber] as CFArray` 当成与 yabai 的 `CFNumberSInt32Type` 等价。下一轮必须显式构造 SInt32 CFNumber window ID 数组，再与当前桥接方式做同窗口结果对照；
- 检查空数组、单窗口、多窗口、重复窗口 ID 和无效窗口 ID 的行为。

**B. Selector 语义**

- `0x7` 有第三方源码使用依据，但仍需在当前 OS build 做受控差分测试；
- 固定同一个已知窗口，比较单窗口、多窗口和空窗口数组的返回；
- 验证返回值是否去重、排序是否稳定、窗口属于多个 Space 时是否返回多条；
- 不要仅凭 selector 数字或函数名称给它附加未证实语义；
- 记录所有失败、NULL 和空 CFArray 的区别。

**C. Core Foundation 数据类型与所有权**

- 验证两个 Copy 函数的返回值是否按 Create/Copy 规则转移 +1 所有权，并确保每次成功返回最终恰好 Release 一次；
- 确认 managed array 的元素确为 NSDictionary，字段类型和缺失字段行为稳定；
- 确认 `id64` 的真实 NSNumber / CFNumber 类型与 64-bit 读取方式；
- 确认 membership array 元素类型是 64-bit Space ID，而不是把其他对象桥接成 NSNumber；
- 明确区分 NULL、空数组、无法解析元素和未知 Space ID；
- 通过重复调用和 Instruments / Allocations 或等效手段排查 CF 对象泄漏。

**D. Connection 与动态符号生命周期**

- 保持 `dlopen` handle 生命周期覆盖所有函数指针调用；不得在仍持有函数指针时 `dlclose`；
- 确认 `SLSMainConnectionID` 的连接是否为进程级主连接、线程使用限制及 session/sleep-wake 后失效条件；
- 不得把 main connection 当作由本模块创建的连接随意 release；
- 对 logout/login、display reconfiguration、sleep/wake、WindowServer 重启或连接失效进行失效处理；
- 每次异常后重新建立 connection / inventory 的策略必须在独立实验进程中验证；
- 私有调用放在隔离 helper 中，异常、崩溃或 ABI 不匹配不能拖垮 Nearpane Host。

**E. 系统版本矩阵**

- 至少在当前目标 macOS build 形成完整收据；
- 后续每个支持的 macOS major/minor/build 都必须重新探测符号、调用、字段和行为；
- 不允许把一个 build 的成功调用升级为跨版本支持承诺。

### 3.2 本问题的裁决

<badge>BLOCKED FOR PRODUCTION</badge> 当前私有 API 声明可继续用于隔离实验，但签名、参数编码、所有权和生命周期尚未达到生产封装标准。先完成上列验证，再决定是否保留该 adapter 作为可选实现。

---

## 4. 如何验证 separate Spaces 关闭时两块显示器的真实切换关系？

目的不是证明 API 返回值“看起来合理”，而是证明用户可见行为与内部状态之间的对应关系。

### 4.1 测试前置

- 维持当前两显示器拓扑，记录显示器 UUID、排列、旋转、主显示器和系统 build；
- 记录 `screensHaveSeparateSpaces=false`；
- 记录两 scope 的 current Space ID（仅本次测试匿名化保存）；
- 准备两个可识别、不会丢失工作内容的测试窗口；窗口标题/进程/几何可区分；
- 记录测试前所有窗口的 PID、CGWindowID、bounds、层级、onscreen、membership；
- 关闭或记录 Stage Manager；不要同时改变其他 Mission Control 设置；
- 不采集窗口像素，不修改用户窗口，不自动关闭任何应用。

### 4.2 用户可控切换序列

第一轮只用 macOS 原生用户操作（Mission Control / 系统快捷键）切换，不用 Nearpane 私有写 API：

1. 记录显示器 A、B 的 current Space ID 和可见窗口 membership。
2. 只在显示器 A 上由用户切换到另一个可识别的 Space。
3. 稳定等待系统动画结束，连续采样直到 inventory 连续数次一致。
4. 记录 A/B 的 current Space ID、窗口 membership、窗口 onscreen 状态。
5. 回到原始 Space，再重复至少 3 次，检查可重复性。
6. 在显示器 B 上重复相同序列。
7. 记录切换前后两个 scope 的 ID 是否变化、哪个 scope 的 current 变化、另一显示器是否同步变化，以及实际可见窗口是否符合预期。
8. 测试结束由用户恢复原来的 Space 与窗口布局。

### 4.3 判读标准

- 若 A 上的用户切换导致 A/B 的用户可见桌面同步变化，且系统行为可重复，才有证据支持当前配置下的共享/联动语义。
- 若只改变 A 的 current 而 B 不变，必须继续查明是否为 display-local 行为、内部 scope 更新时序或采样解释错误，不能先入为主。
- 如果 B 只有一条 Space 记录但其 current 与 A 的切换存在稳定映射，需记录映射关系，而不是将它补成三条或简单复制 A 的列表。
- 对照用户可见系统行为、managed inventory 和窗口 membership 三者；任何一个不一致都标记 unresolved。
- 每个方向至少 3 次重复，要求结果一致；失败样本必须保留。

**关闭独立 Spaces 时的验收不是“两个 scope 都存在”，而是两块显示器在用户实际切换时的 current-state 关系被重复证明。**

---

## 5. 开启独立 Spaces 后需要验证哪些差异？

更改设置属于用户桌面配置变更。必须先取得用户明确授权，记录原值，并在测试结束后恢复。若 macOS 提示注销/重新登录才能生效，必须把 session restart 作为测试步骤，不得假设热切换已经生效。

开启后，在相同显示器拓扑、相同测试窗口和相同操作序列下重复第 4 节测试，比较：

1. `screensHaveSeparateSpaces` 是否确实变为 true；
2. managed scopes 是否仍然分别与公开显示器 UUID 对应；
3. 每个 scope 的 Space count、current Space 和 Space ID 关系如何变化；
4. 在 A 切换时 B 的 current Space 是否保持不变；
5. 在 B 切换时 A 的 current Space 是否保持不变；
6. 窗口 membership 是否仍可解析，是否出现跨 scope / 多 Space membership；
7. 窗口从一个显示器拖到另一个显示器后，其 bounds、membership 和 scope 归属如何变化；
8. 全屏应用是否产生新的 Space record，退出全屏后是否正确恢复；
9. 系统退出/重登录、sleep/wake 后 ID 是否变化、旧快照是否正确失效。

### 开启/关闭对比的最低通过标准

- 关闭模式与开启模式均有独立收据；
- 两种模式下切换行为均至少 3 次可重复；
- 对每次用户切换，系统可见状态、current Space 和窗口 membership 一致；
- 没有把一个显示器的窗口映射到另一个显示器的错误 Space；
- 设置恢复后再次采样，回到原始模式的行为与基线一致。

未完成此对比前，Nearpane 不能声称支持双显示器 Spaces 独立/共享切换。

---

## 6. 如何可靠验证窗口激活和几何映射？

这两个问题必须拆开测试。

### 6.1 窗口身份与激活

先建立一个专用测试应用或无损测试窗口组：

- 至少两个不同应用窗口；
- 至少同一应用的两个窗口；
- 窗口分布在不同 Space；
- 至少一个窗口位于旋转显示器；
- 每个窗口具有可区分的 PID、标题、AX role/subrole、frame 和 CGWindowID。

建立身份匹配链：

1. CGWindowList 获取 PID、CGWindowID、bounds、layer、onscreen；
2. Accessibility 获取应用窗口列表、标题、role/subrole、position、size；
3. 用 PID + 可区分标题 + frame 进行匹配；
4. 若不能唯一匹配，窗口标记 ambiguous，不得生成可点击热区；
5. 对同 App 多窗口、无标题窗口、最小化窗口、隐藏窗口分别记录。

激活验证优先走公开 Accessibility 路径（例如对已匹配 AX window 执行可用的 raise/focus 操作，并按需激活所属应用），但必须实测其跨 Space 行为。仅调用 `NSRunningApplication.activate` 不能证明激活了指定窗口；激活 App 与激活 App 内某一个 window 是两个不同动作。

对每个测试窗口执行：

- 从当前 Space 激活当前 Space 的非主窗口；
- 从另一 Space 的预览目标激活该窗口；
- 同一 App 两个窗口之间切换；
- 重叠窗口点击可见露出区域；
- 测试目标消失、窗口关闭、PID 重启、CGWindowID 重用后的 stale target 保护。

成功判据：激活后目标 PID/window identity 成为预期前台窗口，系统当前 Space 与窗口可见状态符合目标，未激活错误窗口。每个案例至少重复 3 次。

如果必须使用私有窗口激活 API，另开实验，不与只读 membership 结论混为一谈。

### 6.2 几何映射

当前第二显示器旋转 90°，且 AppKit frame 与 CoreGraphics bounds 原点不同。禁止直接复制坐标或盲目乘 backing scale。

必须建立显式转换：

- 输入：显示器 UUID、AppKit frame、CoreGraphics display bounds、rotation、backingScale、窗口 CG bounds；
- 输出：统一桌面坐标中的窗口矩形及该 Space 缩略图坐标；
- 所有窗口使用同一显示器/Space 变换，不逐窗 fit；
- 处理负坐标、多显示器排列、90°/270° 旋转、跨屏窗口和可用区域；
- 变换必须有可逆性/往返误差测试。

用已知测试窗口进行实测校准：将 AX frame 与 CGWindow bounds 对照，改变窗口位置和尺寸，检查预测与实际误差。至少覆盖四角、中心、宽度占满、高度占满、非对称分屏、跨显示器边界和重叠窗口。

几何验收建议：
- 位置误差不超过 2 个逻辑 point；
- 宽高误差不超过 2 个逻辑 point；
- 转换往返误差不超过 1 个逻辑 point；
- 旋转显示器上无镜像、轴交换或错误原点；
- 命中测试点映射到唯一预期窗口；重叠区域按真实 z-order 和可见区域处理。

上述阈值是 Nearpane 工程验收建议，不是 Apple API 保证。

---

## 7. P2 Host Foundation 是否可以与剩余 P1 并行推进？

**可以，但必须限制 P2 范围。结论为 CONDITIONAL PASS。**

允许 P2 同步开展：

- Nearpane Host 独立 App 工程骨架；
- 常驻边缘 Surface 的窗口生命周期与位置管理；
- 纯 UI Layout Composer；
- Module Registry / Lifecycle；
- Interaction Router；
- Permission Broker 的接口与 mock；
- Event / Snapshot Bus；
- mock DesktopOrchestration Adapter；
- 合成窗口、Space 和多显示器 fixture；
- 模块故障隔离、日志脱敏、配置持久化。

P2 必须使用明确接口隔离 Spaces，例如：

```swift
protocol DesktopObservationProvider {
    func snapshot() async throws -> DesktopSnapshot
    var capabilities: DesktopCapabilities { get }
}

protocol DesktopActionProvider {
    func switchToSpace(_ target: SpaceTarget) async throws
    func activateWindow(_ target: WindowTarget) async throws
}
```

上面仅是契约示意，不是本轮授权写入生产代码。实际契约必须包含 snapshot revision、timestamp、source/build、freshness、identity confidence 和 unsupported/degraded 状态。

P2 暂时禁止：

- 将当前私有 SkyLight 探测器直接编入 Host；
- 把 3+1 显示成 4 个用户独立 Spaces；
- 使用未验证的 selector 或未经验证的 Swift CFArray bridge；
- 实现真实 Space 切换、窗口激活和跨屏窗口重排；
- 依赖 Space ID 作为持久化主键；
- 因 P2 UI 已完成而把 P1 标记为通过。

**并行策略：** P2 使用 mock provider 完成 Host 的架构和 UI 骨架；P1 独立完成只读私有 ABI 验证、两种 separate-Spaces 模式行为和真实窗口激活/几何测试。两条线通过稳定协议契约衔接，不互相等待，也不提前锁死未经验证的系统语义。

---

## 8. 是否存在必须先解决的架构问题？

没有发现必须推翻 P0 整体架构的问题。Host / Domain 所有权、Saytile/Riftlet 自治、Spaces Adapter、能力降级和模块隔离方向正确。

但在进入 P4 Desktop Orchestration 之前，必须补齐以下架构细节：

### A. 坐标系统一模型（P4 blocker）

当前架构提到统一坐标变换，但没有定义变换对象、输入坐标系、旋转和 backing scale 的数学契约。必须建立 DisplayCoordinateTransform，并为每个显示器单独保存可验证变换。窗口跨显示器时不能只归属一个未经验证的 display。

### B. Space identity 与 display scope 分离（P4 blocker）

不能把 managed scope 当作 Space，也不能把 Space ID 当作永久身份。模型必须分别表达：
- display scope identity；
- Space runtime identity；
- user-visible current-space relation；
- window membership set；
- relation confidence / provenance。

### C. Snapshot consistency 与 freshness（P4 blocker）

Space inventory、窗口列表、display topology 来自异步接口，不能假设同一时刻原子返回。需要 snapshot revision、采样起止时间、拓扑 fingerprint、重复采样稳定判定和 transient 状态。跨采样发生 display change 或 Space change 时，整份 snapshot 应失效或标记 inconsistent。

### D. Window identity 与 AX / CGWindow 对应关系（P4 blocker）

CGWindowID 可能随窗口销毁重用；PID 也可能重启。必须使用进程生命周期、窗口 ID、可区分 AX 属性和快照 revision 组成短期 target identity。无法唯一匹配时禁用激活操作。

### E. Observation 与 Action 分离（P2/P4 boundary）

只读观察 Adapter 与切换/激活 Adapter 必须分离。不能因为成功读取 membership 就自动启用 action capability。Capabilities 必须按系统 build、权限、操作类型独立报告。

### F. P1 关闭条件需要细分

P1 不能被定义成“所有 macOS 特殊场景全做完”才结束，否则会无限扩张。建议分两道门：
- **P1-Core Gate**：当前目标 macOS build 下，两种 separate-Spaces 模式的切换语义、窗口 membership、几何、激活行为和故障降级通过；允许进入 P4 的有限实现。
- **P1-Compatibility Expansion**：镜像、Stage Manager、全屏、插拔、虚拟显示器及其他 macOS builds 逐项建立兼容矩阵；每项未验证时关闭对应能力，不阻止 Host 和非 Spaces 模块交付。

---

## 9. 交给 Codex 的具体执行建议

以下指令是本次审查后的执行任务。Codex 应在 P1 分支或其新建的子分支上执行，不得修改 Nearpane main、Saytile main 或 Riftlet main。

### Workstream A — P1 私有 API ABI / 数据契约验证

1. 固定当前 macOS build 26A428。
2. 将私有 API 调用留在独立命令行 helper 进程，不进入 Host。
3. 用 C/Clang shim 对照固定版本 yabai 声明，验证三个函数的 ABI 和返回类型。
4. 显式构造 SInt32 CFNumber window list，与现有 Swift bridge 对同一批窗口逐项比较。
5. 验证 selector 0x7 的空/单/多窗口输入、重复输入、返回元素类型、去重和排序。
6. 验证 CFArray / NSDictionary / NSNumber 类型、NULL 与空数组差异、Copy 所有权和释放。
7. 做重复调用、异常输入和 sleep/wake 后连接失效测试。
8. 记录原始脱敏收据、OS build、函数符号、返回类型和 SHA-256。
9. 不做任何写操作，不调用 Space 切换或窗口激活函数。

### Workstream B — separate-Spaces off/on 行为实验

1. 先在 false 状态下由用户手动切换 A、B 两块显示器的 Space。
2. 每次操作前后连续采样 managed inventory、current IDs、window membership 和 onscreen。
3. A、B 两个方向分别至少 3 次，保留失败样本。
4. 取得用户明确授权后再把设置改为 true；如系统要求 logout/relogin，按系统要求执行。
5. 在 true 状态下重复相同测试。
6. 记录两种模式的 current Space 变化矩阵和用户可见结果。
7. 测试结束恢复用户原设置和桌面布局。
8. 不把测试切换实现成 Nearpane 生产功能。

### Workstream C — Window activation / geometry proof

1. 建立可识别的测试窗口组，覆盖不同 App、同 App 多窗口、不同 Space 和旋转显示器。
2. 建立 CGWindow 与 AX window 的唯一匹配表。
3. 验证公开 AX raise/activate 路径能否激活指定窗口并跨 Space 工作。
4. 用 AX frame / CG bounds 校准坐标变换。
5. 覆盖旋转、负坐标、跨屏、非对称布局、重叠和窗口关闭重用。
6. 输出误差分布、重复性和 stale-target 拒绝收据。
7. 不采集用户窗口内容；使用测试窗口。

### Workstream D — P2 Host Foundation（允许并行）

1. 从 P1 当前基线创建独立 P2 实现分支。
2. 建立 Host 工程骨架、主表面、Layout Composer、Module Registry、Action Router、Permission Broker 和 Snapshot/Event bus。
3. Desktop Provider 使用 mock/fixture，不连接真实 SkyLight。
4. 使用合成数据覆盖 1–3 个显示器、3+1 scope、共享 Space 映射未知、旋转显示器、窗口 membership unknown 和 transient snapshot。
5. 主表面严格遵守既有视觉权威，不重做原型和产品设计。
6. 验证模块崩溃隔离、状态恢复和配置持久化。
7. P2 不得宣称真实 Spaces Preview 已完成。

### Codex 交付格式

每个 workstream 独立提交并给出：

- 分支与基线 SHA；
- 文件变更清单；
- 实际执行命令；
- 原始/脱敏证据路径；
- SHA-256；
- 通过/失败/未测试矩阵；
- 已知限制；
- 下一道 gate 的建议。

不得只提交“测试通过”的文字结论；必须保留可复核收据。失败结果不得删除或覆盖。

---

## 10. P1 Core Gate 的最终验收清单

只有以下项目全部有证据，才可申请关闭 P1-Core：

- [ ] 私有 API 的 ABI、selector、CF 类型和所有权完成当前 build 验证；
- [ ] `separateSpaces=false` 下两显示器切换关系重复验证；
- [ ] `separateSpaces=true` 下两显示器切换关系重复验证；
- [ ] 3+1 inventory 的用户可见语义得到行为解释；
- [ ] 可见与测试窗口 membership 的完整性和多 Space 返回语义得到验证；
- [ ] AppKit / CoreGraphics / AX 坐标变换误差达标；
- [ ] 不同 App 与同 App 多窗口身份映射唯一；
- [ ] 用户触发的指定窗口激活正确，跨 Space 行为明确；
- [ ] snapshot stale / transient / display reconfiguration 能 fail closed；
- [ ] 私有 API 不可用或失败时回退到安全降级模式；
- [ ] 证据、命令、系统版本、SHA-256 和失败样本均归档。

兼容性扩展（Stage Manager、全屏、镜像、插拔、虚拟显示器和其他 OS build）单独跟踪；未验证时关闭相应能力，不得伪装成已支持。

## 11. 最终裁决

Nearpane 的 P0 架构不需要推倒重来。P1 只读基线的质量足以支持继续做只读解析与 P2 Host 的 mock-based 工程准备，但不足以证明完整 Spaces 预览、跨屏切换或窗口激活已经可用。

**明确决策：**

- P1 Read-only Baseline：**PASS**；
- Full Spaces Preview / switching：**BLOCKED**；
- P2 Host Foundation：**CONDITIONAL PASS，可与 P1 并行**；
- P4 Desktop Orchestration：必须等待 P1-Core Gate；
- Nearpane 整体架构：保留，补齐坐标变换、身份映射、快照一致性和 Observation/Action 分离契约。

不要让一个尚未验证的私有 API 阻断 Nearpane Host、Saytile、Riftlet 和可选模块的工程推进；也不要因为 Host 能运行，就提前宣称 Nearpane 的真实桌面编排能力已经成立。
