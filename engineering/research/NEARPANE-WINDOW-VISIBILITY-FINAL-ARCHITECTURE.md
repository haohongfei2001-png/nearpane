# WindowVisibilityProvider 技术裁决

2026-11-25 修订，适用于 5.22（90）。[产品定义](NEARPANE-STAGE-MANAGER-PRODUCT-DEFINITION.md)确定 Display → StageGroup → Window 的语义。[当前状态和实测](../native-spaces/STATUS.md)

## 产品写入边界

Swift 保有唯一组目录、事务、写前日志及恢复协调权。每一批窗口同时只允许一个调度所有者。A 优先委托系统调度；B 或 C 经独立资格验证后才可用 Rust 静态库和版本化 C ABI 执行其获准的窗口动作。所有路线均保护用户可见桌面的数量、顺序和当前桌面。系统接管会撤销新动作。

| 机制 | 产品裁决与依据 |
|---|---|
| A · Apple 原生调度 | 首选。仅在用户已启用系统台前调度时观察 WindowManager、WindowServer 和 AX。R4 从独立核实的成员精确选窗，由系统调度整组，再读回活动集合与焦点。最小化、还原、隐藏、退出和相应输入继续由系统拥有。单次观察到系统开关关闭仅说明当前会话无法运行 A。 |
| B · 应用自有隐藏私有 Space | A 经实测无法满足完整 R4 需求时的第二路线。只处理已登记且有恢复责任的目标。创建、停放、双向归属、归还、销毁、零残留及用户可见桌面清单不变须在目标 build 上全部独立证实。用户的普通桌面、原生全屏及原生 Split View 均不接受写入。历史试验入口和返回码不赋予产品资格。 |
| C · Rust Accessibility Corner | 仅当 A 和 B 都有不能满足合同的实证时评估。需要完整的 sliver、Z-order、PressGate、事件 tap、画面覆盖、真实输入接收者和 Guardian。已有失败、恢复责任和原始证据一并保留。 |
| AXMinimized、旧角落遮罩 | 历史 FAIL 独立保留。前者产生 Dock 图块，后者将真实鼠标按下交给停放窗。 |
| 外部 SkyLight 排序、应用级隐藏、屏外或虚拟屏停放、穿透遮罩 | 无满足此合同的准入证据。符号、返回码、应用级前台或局部画面均不足以判定窗口隔离。 |

此次顺序取代历史上的双后端并行晋级和 Corner 唯一候选裁决。已有实验结果保持原判。[历史逐项实验与上游资料](https://github.com/haohongfei2001-png/nearpane/blob/7d099c7/engineering/research/NEARPANE-WINDOW-VISIBILITY-FINAL-ARCHITECTURE.md) · [Dock 和鼠标失败原始读回](../verification/stage-groups/5.22-90/isolation/qualification/)

## 资格与证据

每个 Provider 声明适用系统 build、SIP、正式 Host 的权限、窗口类别和所需实测。资格绑定引擎源码、Host CDHash、硬件和显示器拓扑。当前受测类别为普通、可交互、可唯一识别的标准窗口。Sheet、系统窗口、原生全屏、Split View 和已有的用户最小化状态应由系统保留。Corner 需 AX、输入监听、事件投递和录屏可用；运行中失去必需权限即停止新操作。

自管路线 B/C 的单窗资格要求同一受控窗口完成退场及恢复。读取原 AX、CGWindowID、PID、出生代、AppKit/WindowServer 几何、活性及正反向原生归属。停放时独立核对画面和命中，向受控接收者投递完整鼠标按下、拖动、释放和唯一键盘标记，查验同应用旁窗、另一应用、Dock、菜单、焦点以及文档。恢复时须双读原几何、原焦点和归属并核对活动租约归零。B 必须单独证明还原原生归属和销毁自有空间。C 要求 Guardian 在正式 Host 中断后履行经核实的恢复责任。对一项能力的 UNKNOWN、FAIL、BLOCKED 或 NOT_RUN 均阻止该能力晋级。

同桌面实验使用普通桌面、原焦点、HID 和真实窗口归属双读。Mission Control 的演示用于其兼容试验；B 须独立证明临时资源未改变用户可见桌面。单窗物理资格允许在隔离资料中验证整组。通用产品写入另需整组、稳定性、生命周期及同机性能合同全部通过。读取历史组、窗口预览和已有同屏选窗不依赖 Provider 的可写资格。

恢复只针对原执行器已持有、仍可独立确认的窗口。未知后像、未结日志或无法接收恢复责任时保留所有权并停止新派发。正式运行拒绝任何仅来自用户偏好、历史实验或自行声明的资格。[实施与验收](NEARPANE-STAGE-MANAGER-CODEX-INTEGRATION-PLAN.md)
