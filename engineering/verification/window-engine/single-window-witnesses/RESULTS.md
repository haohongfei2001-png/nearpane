# StageGroup 单窗口验证 · 2026-11-22

正式 Host 的 Spaces 和 Corner 单窗口资格均为 **BLOCKED**，生产资格为 **0/2**。目标机为 arm64、macOS 27.0（26A428）、SIP 开启。5.22（90）的新签名候选已在隔离目录构建。标准路径的日常安装使用同一单实例 Bundle ID，PID 59938 始终在运行。启动器只读核对了内核进程和 Launch Services，候选启动、窗口写入、Space 写入和系统输入投递均为零。[新候选启动预检](06-staged-image-readiness.json) · [日常安装核对](07-daily-image.json) · [机器总表](verification.json)

| 项目 | 结果 | 本轮证据 |
| --- | --- | --- |
| Spaces 自有面板 | 正式 Host **BLOCKED**，面板周期 **NOT_RUN** | 观察器现在保留每次运行的随机编号，并独立读取已落盘的 16 个有序操作。它将 Host 进程代、系统启动代、目标显示器、两次双向归属与操作前后四次原生桌面清单关联。原先脱敏会破坏随机编号，已保留复现记录。[原失败](02-prior-canary-projection.json) · [修复 CI](09-canary-ci.json) |
| Mission Control 与第三方窗口 | **NOT_RUN** | 自有面板清理后，正式 Host 在隔离桌面读取系统 Mission Control 的可见桌面条两次；关闭后须两次读回原焦点。登记外部窗之前需要上述结果及面板归档。现有透明普通夹具仅覆盖身份、几何和归属。可见签名窗口的键盘输入、同应用旁窗和 Dock 行为仍待实测。[正式入口](../../../../scripts/acceptance/window-engine/spaces/README.md) · [修复后 CI](10-overview-ci.json) |
| Corner 裁片及输入 | 离屏 **PASS**，正式 Host 单窗 **NOT_RUN** | 裁片由生产静态库按显示器和已登记的实际窗口绘制。独立观察器读取该面板的窗口号、前后顺序和像素。隔离单窗入口只停放一扇窗，分别验证裸露边缘和 resize 边缘的按下、拖动、释放，并核对同应用旁窗收到相同标记的三段事件。既有停放窗实际收到按下的失败仍然有效。[本机离屏回归](08-local-source.json) · [原接收者失败](../../stage-groups/5.22-90/isolation/qualification/corner.json) |
| Guardian | 正式签名 **PASS**，恢复资格 **NOT_RUN** | 正式 Host 内固定的 Guardian 摘要与实际签名二进制一致。完成构建的隔离验收器要求写前租约、停放读回、恢复责任确认，以及恢复后带相同进程代和窗口号的解除回执。它的控制器与正式 Host 分别记账。[签包](05-signed-candidate.json) · [隔离构建](12-corner-kit-build.json) |
| 默认引擎、正式侧栏及性能 | **NOT_RUN** | 没有合格默认引擎。A→B→C→A、10/50 次和两后端速度、资源、焦点、输入及兼容性对照均无有效样本。 |

Corner 的离屏测试用夹具自己生成的像素图验证带显示器偏移的裁片，并用未投递的 Quartz 事件验证标记、进程和阶段过滤。真实事件监听、实际窗口接收者、Guardian 接手以及对系统界面的影响仍需独立验收。生产裁片当前支持可识别、只读系统卷上的静态壁纸和已知缩放模式。动态及自定义壁纸的还原质量尚未取得资格。[引擎源文件与 MIT 来源](04-license-final.json) · [原始本机日志与包收据](local-source-logs.zip)

## 提交和回归

| 源码 | 变更 | 验证 |
| --- | --- | --- |
| `4af44bf` | 修复操作编号和持久化面板证据的关联，增加操作结束后的独立读回 | [源码 CI 通过](https://github.com/haohongfei2001-png/nearpane/actions/runs/44930180384) |
| `3d818c2` | 接入 Mission Control 可见桌面和第三方窗口的准入条件 | 一项验收器单测依赖托管机本地已安装 Nearpane，首次 CI 失败。[失败原始日志](03-initial-hosted-test-failure.log) |
| `1064999` | 单测改用自身临时目录，区分正式 Host 明确拒绝和可能已发生写入的未知响应 | [源码 CI 通过](https://github.com/haohongfei2001-png/nearpane/actions/runs/44932037456) |
| `4a84113` | 接入生产 Corner 裁片和隔离单窗输入、接收者与 Guardian 解除回执 | 本机与 GitHub CI 各通过 101 项 Rust、86 项 Swift、77 项 Python 及生产 C ABI。离屏 Quartz 和像素验证均通过。[GitHub CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/44933262446) · [CI 收据](13-final-ci.json) |
| `341834d` | 整包检查逐字验证正式 Host 使用的 Developer ID 规则和已登记的夹具 CDHash。弱签名、附加条件及独立夹具函数继续触发拒绝。 | 原检查将正式规则匹配成测试代码，已在新旧签包中复现。10 项本机包与依赖回归通过，整包 CI 已完成实际构建和离线资源校验。[原始 CI 失败](15-initial-package-failure.zip) · [新候选只读复核](14-package-rule.json) · [修复后完整 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/44934325263) |

同一源码的托管 25G332 实验中，两个签名普通应用的真实窗口目录和重开后的成员关系通过。已存档的旧角落原型在对照中触发 `dockWindowTiles`，其 **FAIL** 及录像均已保存。该运行的正式 Host、整组切换和 10/50 次均为 **NOT_RUN**。[目录与生命周期](hosted-25G332/stage-group-lifecycle.json) · [旧原型原始收据](hosted-25G332/corner.json) · [旧原型实录](hosted-25G332/corner.mp4) · [原生协议 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/44933262459)

分支起点为 `e4d11b8`。新候选 Host CDHash 为 `64e2214263f2b8e028923973bee68002f8e512ac`，Guardian CDHash 为 `1d5d5ecb1ec101841420d0c66d5af98d1112a86d`。两者均经 Developer ID 严格验签。检查签名 Host 的 Mach-O 文本段，确认其包含 Spaces 面板与登记窗口入口、Corner 裁片、PressGate、事件监听和窗口顺序读取。新候选可用于隔离验收，包检查仍列出 14 个分发签名缺口。[完整签包收据](05-signed-candidate.json) · [链接符号](16-linked-engine.json)

本机保存的候选归档为 `build/verification/window-engine/staged-5.22-90/4a84113/Nearpane-5.22-90.zip`，SHA-256 为 `1366b7639e6ec407f12c0434d770f48a5494dd0938eb328d5c80b087a1205e74`。从同一份 ZIP 解包两处，Host 与 Guardian 的二进制摘要、CDHash 均一致。私有临时目录中严格验签通过。项目工作区中的外层 App 验签返回 `resource fork, Finder information, or similar detritus not allowed`，原因尚未细分。两处均未启动候选。[解包原始收据](17-archive-roundtrip.json) · [各源码对应的 GitHub 检查](18-github-checks.json)

下一项实体操作是在有现成授权的隔离普通桌面上，由标准路径的签名候选执行一次自有面板。启动时须没有占用同一标识的进程。先读取候选自己的权限，清理后核对真实可见桌面清单，随后分别验收第三方可见窗和正式 Guardian 的恢复责任。日常包的签名与原进程出生代均已复核。源码回退点依次是 Corner 前的 `1064999` 和本轮之前的 `e4d11b8`，回退时保留本目录及此前的失败记录。
