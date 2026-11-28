# Nearpane P1 — macOS Spaces 只读基线

**状态：P1 IN PROGRESS；只读基线已完成；切换与激活尚未验证。**  
**测试日期：** 2026-11-09  
**测试环境：** macOS 27.0（Build 26A428），ARM64  
**本报告性质：** 单机、单系统构建的真实运行证据，不代表跨版本兼容性结论。

## 1. 测试范围

本轮直接进入 P1，没有重新审计三个产品仓库，也没有重做 P0 设计。

执行了两次只读探测，覆盖：

- AppKit / CoreGraphics 显示器拓扑与坐标；
- `NSScreen.screensHaveSeparateSpaces`；
- SkyLight 管理分组及其与公开显示器 UUID 的对应关系；
- CoreGraphics 窗口元数据；
- SkyLight 窗口 Space membership；
- 辅助功能与屏幕录制权限的只读 preflight 状态。

探测程序动态解析 SkyLight 私有符号，不静态链接私有 framework。使用的私有接口包括：

- `SLSMainConnectionID`
- `SLSCopyManagedDisplaySpaces`
- `SLSCopySpacesForWindows`

窗口 membership 查询使用 selector `0x7`。该调用形式与 yabai 的公开源代码声明和调用一致，但这仍是私有 SPI，不是 Apple 对外承诺的 API。

## 2. 真实运行结果

### 2.1 显示器与 Space 分组

两次采样的结构结果一致：

| 观测项 | Sample A | Sample B |
|---|---:|---:|
| `screensHaveSeparateSpaces` | false | false |
| 公开 API 检测到的活动显示器 | 2 | 2 |
| SkyLight managed display scopes | 2 | 2 |
| Scope 1 对应公开显示器 UUID | 匹配 | 匹配 |
| Scope 1 的 Space 记录数 | 3 | 3 |
| Scope 2 对应公开显示器 UUID | 匹配 | 匹配 |
| Scope 2 的 Space 记录数 | 1 | 1 |

每个 scope 均报告一个 current Space。原始 Space type 值分别为 `[0, 0, 4]` 与 `[0]`；本轮不对 raw type 值赋予语义，尤其不把 `4` 擅自认定为全屏。

**关键发现：** 在 `screensHaveSeparateSpaces == false` 的真实配置下，SkyLight 仍返回两个能够分别匹配到公开显示器 UUID 的管理 scope，且 Space 记录数为 3 与 1。

这证明：

1. SkyLight 的 managed scope 可以通过公开显示器 UUID 与当前物理显示器对应；
2. scope 数量、scope 中 Space 记录数与用户设置的 separate-Spaces 布尔值不是同一个概念；
3. 不能把两个 scope 的记录数简单相加，并宣称用户拥有 4 个相互独立的 Spaces；
4. 也不能把每个 managed scope 直接当作一组独立的用户桌面。

**当前尚未证明** 第二个显示器的单条 Space 记录在共享 Spaces 模式下究竟代表什么运行时语义。需要通过受控 Space 转换观察两块屏幕的 current Space 和窗口行为，才能裁决。

### 2.2 窗口 Space membership

| 观测项 | Sample A | Sample B |
|---|---:|---:|
| CGWindow 元数据记录 | 354 | 344 |
| Layer-zero 窗口记录 | 291 | 285 |
| 返回非空 Space membership 的 layer-zero 记录 | 46 | 43 |
| 返回 inventory 之外 Space ID 的记录 | 0 | 0 |
| 当前可见且 bounds 正面积的窗口 | 18 | 14 |
| 上述可见窗口中取得非空 membership 的数量 | 18 | 14 |
| 上述可见窗口中 unresolved 数量 | 0 | 0 |

两次采样中，所有当前可见且具有正面积 bounds 的 layer-zero 窗口都取得了非空 membership，且返回的 Space ID 均能在当前 inventory 中解析。

但全部 layer-zero 记录中，只有一部分返回非空 membership。其余记录尚未分类，不能直接认定为普通应用窗口，也不能把空 membership 当成某个默认 Space。

窗口数量在两次采样间变化，属于动态桌面窗口清单；两个样本的显示器 scope、每个 scope 的 Space 数量及 UUID 对应关系保持一致。

### 2.3 坐标系

第二块显示器处于 90° 旋转状态。其 AppKit frame 与 CoreGraphics display bounds 的原点不一致。

因此，Nearpane 不得直接复制 `NSScreen.frame` 坐标作为 `CGWindowBounds` 坐标。窗口几何映射必须显式处理：

- AppKit 与 CoreGraphics 的坐标原点差异；
- 显示器旋转；
- backing scale；
- 多显示器全局坐标；
- 窗口跨显示器边界的情况。

几何真实性仍然优先于缩略图排布的视觉整齐。

## 3. 权限与副作用

两次探测均为只读：

- 未采集屏幕像素；
- 未切换 Space；
- 未激活或改变任何窗口焦点；
- 未请求新权限；
- 只读取辅助功能与屏幕录制 preflight 状态。

探测宿主的两个 preflight 在本机当时均为 true。这只说明当时的权限状态，不代表 Nearpane 已经完成权限 UX 或生产权限验证。

## 4. 当前技术裁决

### 已验证（仅限该 OS build）

- 公开显示器列表、几何和旋转信息可读取；
- SkyLight 的三个目标符号在该构建上可解析；
- managed display scope 的 UUID 可以与公开显示器 UUID 对应；
- 两次采样得到相同的 scope 数量与每屏 Space 记录数；
- 当前可见的正面积 layer-zero 窗口在两个样本中均能取得 Space membership；
- AppKit / CoreGraphics 坐标不能直接混用。

### 仍未验证

- `Displays have separate Spaces` 关闭时的实际同步切换语义；
- `Displays have separate Spaces` 开启时的独立切换语义；
- 由 Nearpane 发起 Space 切换；
- 点击缩略图激活窗口；
- 全屏 Space 的 raw type 语义；
- Stage Manager 开启/关闭；
- 显示器插拔、主显示器变化、镜像和虚拟显示器；
- Space 动画期间的 transient 检测；
- 所有 offscreen / 非普通窗口的 membership 完整性；
- 其他 macOS build 的符号、ABI 与行为。

因此，本轮只读基线**不是 P1 完成，也不是 P2 的进入门槛收据**。

## 5. 下一步 P1 验证

1. 在当前 separate-Spaces 关闭配置下，进行一次受控、可恢复的 Space 切换观察；记录切换前后两个显示器的 current Space、窗口 membership 与可见状态，并恢复原始桌面状态。
2. 在明确授权后测试 separate-Spaces 开启配置；切换设置前后保存状态，测试结束后恢复原设置。
3. 使用独立测试窗口验证用户触发的窗口激活；每个操作都必须先验证窗口身份、Space 归属和快照新鲜度。
4. 补充全屏、Stage Manager、显示器插拔、镜像和 transient 场景。
5. 只有当目标映射和切换行为在矩阵内可重复时，才允许将完整 Spaces Preview 标记为 VALIDATED。

在完成上述会改变当前桌面或系统设置的测试前，不自动切换用户的桌面，不修改 Mission Control 设置。

## 6. 证据文件与隐私边界

仓库中保存：

- `experiments/macos-spaces-readonly/spaces-mapping-probe.swift`：只读探测源码；
- `experiments/macos-spaces-readonly/evidence/p1-readonly-summary.json`：脱敏汇总；
- `experiments/macos-spaces-readonly/SHA256SUMS.txt`：源码与脱敏汇总的 SHA-256。

原始 JSON 含显示器 UUID、设备名称和窗口几何，未上传到公开仓库，已保存在 Mac 本地私有目录：

`~/Documents/Nearpane-P1-private-evidence/2026-11-09/`

本地原始证据 SHA-256：

- `spaces-mapping.json`: `1f4b9e610cb178911df035b260b5257ec667622526b15b491a9f6119fdfcc7e2`
- `spaces-mapping-repeat.json`: `ae53b596aabef6c7d82368fcb287e2bd05c8a5b8ea5aa5bf87214cc312972d65`

## 7. 参考资料

- Apple — [NSScreen.screensHaveSeparateSpaces](https://developer.apple.com/documentation/appkit/nsscreen/screenshaveseparatespaces)：该属性反映 Mission Control 中的 Displays have separate Spaces 设置，不是完整 Space inventory。
- Apple — [NSScreen](https://developer.apple.com/documentation/appkit/nsscreen)：公开显示器对象及几何信息。
- Apple — [CGDisplayCreateUUIDFromDisplayID](https://developer.apple.com/documentation/applicationservices/applicationservices_functions)：用于将公开显示器 ID 转为显示器 UUID。
- yabai — [SkyLight function declarations](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/misc/extern.h) 与 [window Space membership call](https://github.com/asmvik/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/src/window.c)：第三方实现参考，不是 Apple API 合约。

**最终状态：P1 只读基线已取得真实证据；Spaces 的共享/独立语义与写操作仍未验证。Nearpane 继续采用 fail-closed、能力分级和非 Spaces 模块独立运行的架构。**
