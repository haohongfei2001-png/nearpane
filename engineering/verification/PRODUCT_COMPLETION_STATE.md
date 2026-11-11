# Nearpane 产品完成状态（持续维护入口）

从本文件和当前分支 HEAD 接手。权威顺序：[产品定义](../../PRODUCT_DEFINITION.md)、[ADR-010](../../decisions/ADR-010-DUAL-WORKSPACE-MODES.md)、[011](../../decisions/ADR-011-MULTI-DISPLAY-PRESENTATION.md)、[012](../../decisions/ADR-012-DESKTOP-WORK-AREA-AND-FULLSCREEN.md)、[013](../../decisions/ADR-013-STABLE-WORKRECT-AND-EIGHT-WINDOW-TILING.md)、[视觉权威](../../design/NEARPANE-VISUAL-AUTHORITY.md)。固定分支 `implementation/host-foundation-20261109`；总任务开始于 `b2af573876aa120a1db003d9b82542daee6409e4`。个人资料、主屏工作窗口不作为验收对象。

**读法：** IMPLEMENTED＝有可运行实现，尚缺相应现场证据；VERIFIED＝仅在写明的环境实际通过；PARTIAL＝同一能力中仍缺部分路径；BLOCKED＝前置未满足；NOT_IMPLEMENTED＝没有产品实现。算法、隔离系统实测、真人环境是三种证据；后两者不互相替代。

| 正式能力 | 状态 / 实际边界 | 证据、依赖与下一步 |
|---|---|---|
| 普通窗逐窗选择、预演、授权/撤销、同应用隔离 | VERIFIED · 当前 build 的副屏标准 AppKit 窗口；全局自动接管关闭 | [P5.4 原生](P5.4-REAL-AX-ACCEPTANCE.md)；产物源码 `8613465`。达到真实 AX/CG/焦点条件才能发放许可。无普遍第三方兼容声明。 |
| 成员增减、渐进平铺、用户比例、超八窗分流 | VERIFIED · 副屏无专用协议的标准 AppKit 普通窗逐窗授权后 1–8 窗实测；新兄弟窗不自动纳入。成员关闭/历史恢复仍 PARTIAL | [本轮九个阶段](../../build/verification/p54/ordinary/a56be84a-0e3d-4625-b094-652a62aa9750/density.json)：17 个布局事务、停止后 8 次原位恢复，Owner/AX/CG 最大误差 0 pt；第九未授权窗零写入、同焦点、零残留。没有将第九窗当成硬上限；9–17 仍为布局模型验证。旧包在第五/六窗的拒绝经 BSD 代际、可执行文件及动态签名共同重验修正。关闭第三窗时原 AX 对象已销毁但 CG 仍保留编号，保留恢复记录，待有界只读分析。 |
| 工作区预留、排除、暂停、停止与恢复 | VERIFIED · 副屏 Docked/Floating、排除、可证明时恢复；进程重启没有持续见证时保留待处理日志 | [故障回合](P5.4-REAL-AX-ACCEPTANCE.md)、[随包应用](P4.6-NATIVE-ACCEPTANCE.md)。主屏可独立保存配置，未开放普通工作窗口写入。 |
| Stage Manager、跨屏和系统调整 | PARTIAL · 正常几何可管，几何不一致拒绝；移动/编辑不能可靠归因时不覆盖 | [P4.8](P4.8-STAGE-MANAGER-COMPATIBILITY.md)。不重做 TextEdit 异常试验；未证明缩略几何的具体成因。 |
| 空间、窗口、显示器只读映射 | VERIFIED · 可见几何轮廓、z-order、按显示器呈现；仅有可见 Space 见证时成行 | [P4.0](P4.0-readonly-desktop-closeout.md)。未将内部记录数当成桌面数；无证据时只显示可见窗口。 |
| Native 行点击切换、保留焦点、返回 | BLOCKED · 无获准且可控的独立 A/B 环境；产品动作关闭 | [P4.3](P4.3-ACTION-ADMISSION.md)。Apple 的[变化通知](https://developer.apple.com/documentation/appkit/nsworkspace/activespacedidchangenotification)不提供源/目标身份；[moveToActiveSpace](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/movetoactivespace)是本窗口激活时的行为，不是切换到指定任意桌面的公共命令。只在有两屏初态、A/B 与可靠回程的专用时段执行。 |
| Native 跨 Space 拖窗、新窗新空间、清理空空间 | BLOCKED · 已拆分窗口拖放/整行意图及归属、扩容策略；未实现可准入的系统写适配器 | [动作门槛](P4.3-NATIVE-SPACE-BEHAVIOR.md)。实际移窗/创建/删除各需权限与独立结果见证；无能力时只做可行分割，不虚构新 Space。 |
| Virtual 逻辑归属与真实隔离 | BLOCKED · 已有模式互斥及逻辑模型，未获可靠的第三方单窗口停放/恢复机制 | [P4.2.2 裁决](P4.2.2-VIRTUAL-TECHNICAL-VERDICT.md)。Apple 的 [orderOut](https://developer.apple.com/documentation/appkit/nswindow/orderout%28_%3A%29) 属于目标 NSWindow 实例，且可能改变 key/main，不提供普通外部管理器的逐窗授权；不重复旧停放、Hide 或最小化。 |
| Saytile 实时文字、编辑保护和复制 | VERIFIED · 原生文字、手改与复制及本地资料重开已验证 | [P4.5](P4.5-ALPHA-CORE-WORKFLOWS.md)、[版本延续](P5.3-PROFILE-MIGRATION.md)。未授权时不向外部编辑器输入。 |
| 中文采集、声级、待命/说话/暂停与纠错 | PARTIAL · 本地中文合成 PCM 有本次 Attempt 的 completed+final；物理麦克风、真人说完待命未验 | [工作流](P4.5-ALPHA-CORE-WORKFLOWS.md)。不录私人语音、不调用付费服务；本轮已在设置接通显式同意、逐资料凭据、本机/API 切换和撤销；原 Saytile 单专家+融合控制器，五项临时资料/凭据替身测试通过。未用实际服务。 |
| Riftlet 系统截图、托盘、历史队列和共享锁 | VERIFIED · 隔离副屏截图、滚动/展开/收起、重新打开与顺序已证实 | [P4.8 成品](P4.8-ALPHA-DELIVERY.md)、[P5.2 对齐](P5.2-UPSTREAM-INTEGRATION.md)。仅明确授权后监听用户选中的截图目录，不创建第二套队列。 |
| 截图点击附加到草稿、不发送、UNKNOWN | PARTIAL · 普通 Alpha 已接入真实适配器；本地无界面浏览器及真实领域回执守卫通过。真实服务端终态 BLOCKED | [P5.0](P5.0-CHATGPT-ATTACHMENT.md)。只需专用已登录的非私人草稿；不重新代用户上传、不补传 UNKNOWN。 |
| 一套领域实例、唯一主驻留屏、副屏 Space-only | VERIFIED · 角色切换、跨模块状态延续已有副屏/合成拓扑组合实证；物理拔插、两块个人工作屏同时操作未验 | [P5.2](P5.2-MULTIDISPLAY-ACCEPTANCE.md)，`4ac8a84`。镜像/失效身份/旧事件降级。 |
| 原生全屏与 Fill、主动精简工具、位置保存、返回 | PARTIAL · 实现运行链及手动副屏工具、源身份检查；真实第三方系统全屏覆盖和返回未验 | [P5.1](P5.1-FULLSCREEN-RUNTIME.md)。本机缺不扰动主屏的全屏试验；不猜 Space，不暂停领域。 |
| 连续宽高、按屏 pt/%、图标及恢复默认 | VERIFIED · 原生图标/默认/窄高/展开已有实拍；本轮副屏实测“模块”和“本屏全部尺寸”的预览、取消、应用 | [P4.8.1](P4.8.1-RESPONSIVE-ALPHA.md)、[本轮 Settings 实测](../../build/verification/product-closeout/settings/7924e58d-b891-42c7-aa0d-db30a8cc38da/result.json)。只复原模块时独立预留保持 119 pt；确认全屏尺寸重置后才恢复跟随。另一屏配置不变、管理写入零。P5.4 同时操作普通窗口和图标的一次焦点分歧不按通过。 |
| 默认布局、玻璃、文字、截图动效、键盘可及性 | PARTIAL · 有副屏单窗实拍/滚动/焦点；动态玻璃和真实选区磁力仍缺连续可归因证据 | [P3.8](P3.8-native-experience-closeout.md)。禁止采集个人桌面，不用静态替代动态。本轮补齐按模块/当前屏恢复尺寸，应用前提示 Docked 预留变化；显示器拓扑变化原地刷新设置页并作废旧确认。Host 相关回归 203/203；提交 782e2df；新设置的副屏操作另验。 |
| 用户可选模块及隐私 | VERIFIED · 时钟默认不启用，沿用既有 ID、启停、顺序。已在真实副屏侧栏展开和收起，能显示本地时间；可选额外时区 | [真实展开](../../build/verification/product-closeout/settings/7924e58d-b891-42c7-aa0d-db30a8cc38da/clock-expanded.png)、[时区回归](../../build/verification/product-closeout/domains/local-clock.log)。候选隐藏无实际数据源的样例；日历、天气、AI 等在产品定义中是可选扩展方向，没有作为已实现集成。 |
| 升级、资料契约、备份、失败回退 | VERIFIED · P5.2 → P5.3 隔离副本实测，P5.4 沿用相同格式/身份；旧操作、TCC 和窗口票据不继承 | [升级回退](P5.3-UPGRADE-ROLLBACK-ACCEPTANCE.md)，`cc36d14`。更早版本按标记和真实 schema 拒绝不兼容；本轮不迁移个人资料。 |
| 驻留、退出屏障、权限及资源 | PARTIAL · 领域进程排空、关闭观察器、睡眠/唤醒和历史一小时驻留有证据；不是普通窗口观察长期电量基准 | [P3.7](P3.7-hardening-closeout.md)、[P5.2](P5.2-MULTIDISPLAY-ACCEPTANCE.md)。新加入的长期观察以限定目标、有限采样和退出清理测量。 |
| Apple Silicon、安装及公开发行 | PARTIAL · 本地开发签名，6 个 Mach-O 均有 arm64，按各自部署下限验签；正式签名、公证、干净设备验收仍 BLOCKED | [打包检查](../../scripts/check-alpha-distribution.py)、[发布门禁](../../build/verification/product/distribution-gate.json)。[Apple 公证要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)：按授权签名并加固、时间戳、公证、干净机安装验证。已在一次性副本按嵌套顺序加固、重新计算 3 项助手指纹、重新封签 6 个 Mach-O；[原包保持一致](../../build/verification/product/signing-rehearsal.json)。未使用发布凭据或上传；窗口/资料助手仅使用已安装的 Apple 签名 Python，缺失时拒绝、不触发安装。 |

## 接续点

可运行：[P5.5 Alpha](</Users/hhf/Applications/Nearpane P5.5/Nearpane P5.5 Alpha.app>)；[P5.4 回退包](</Users/hhf/Applications/Nearpane P5.4/Nearpane P5.4 Alpha.app>)。P5.3 起共用稳定资料契约及写锁，须先退出再换版，不拷贝数据库，不自动回放外部操作。本轮只用标记的隔离目录。

- 提交：`daf477b` 建立状态；`782e2df` 恢复尺寸；`182ae05` 领域设置和真实时钟。`d9adbe2` 固定八窗、按屏预演、资料锁及安装验收。对应 P5.5 首份安装 Host SHA-256 `bba64dfbb083f904a9120e9843732e11cdb2d97da9b65c8817d86f056867a104`。安装与回退边界见[使用帮助](../../docs/ALPHA-HELP.md)。
- [集成 271/271](../../build/verification/product/integrated.log)、[独立 Host 221/221](../../build/verification/product/foundation.log)、[Debug/Release](../../build/verification/product/packages.log)、[安装资源](../../build/verification/product/installation.log)、[资料事务 13/13](../../build/verification/product/profile-transactions.log)。171 份固定输入均验证；资料锁持有者退出释放的并发回归已通过；原先失败保留在 integrated-current.log。
- [真实密集窗口几何/采样](../../build/verification/p54/ordinary/a56be84a-0e3d-4625-b094-652a62aa9750/geometry.json)：42.88 秒交互，Host CPU 累计由 0.28 增至 1.35 秒，RSS 峰值 94,288 KiB；窗口助手 CPU 0.04→0.86 秒，RSS 峰值 15,600 KiB。不能外推电池续航。
- 正在接续：关闭第 3 窗时残留 CG 编号的语义；已授权成员被 App 排除时不应暂停其他成员，逐窗排除的持久化与撤销；确保关闭或最小化 Settings 后不继续读取所选应用。待验证实际产品后更新此处。
