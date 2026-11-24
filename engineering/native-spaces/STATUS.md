# Nearpane 当前工程状态

## 5.22（90）侧栏工作集合交付状态

**当前签名开发候选为 `5bd0732`，回滚包为 `e105c1e`。** 修复前，旁窗卡片出现或离开会通知红窗重新读取预览。修复后，在同一台 26A428 Mac 上，红窗的这项通知为零。返回红窗的首帧复用了原位图，新增捕获为零。红窗变绿时，蓝窗保持蓝色，两扇夹具关闭后前台与此前一致。标准安装版的三指手势观感为 **NOT_RUN**。日常应用仍为 `bec6cb2`。[源码](https://github.com/haohongfei2001-png/nearpane/commit/5bd0732b44d6f54c67c54ca1ba74482e9450609c) · [实测及签名候选](../verification/native-spaces/5.22-90-active-display-previews/card-mount-5bd0732.json) · [前后对照与卡片图像](../verification/native-spaces/5.22-90-active-display-previews/card-mount-5bd0732.zip)

Guardian 已在允许退场前核对 Swift 选中的前台窗口，并在写入恢复记录后复核焦点和输入。隔离管道回归中，缺少选窗记录、缺少实际焦点对象、焦点仍在待退场窗、选错同应用旁窗、进程换代，五种情况的可执行回执均为零。真实单窗退场和归位仍为 **BLOCKED**，侧栏整组往返及 10/50 次仍为 **NOT_RUN**。[引擎源码](https://github.com/haohongfei2001-png/nearpane/commit/e105c1eb4eaa60d29af11da231d2dbb4b287a02a) · [引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45447195303)

11 月 25 日 01:33，实体 Mac 读到普通桌面。01:35 输入已静止 13.98 秒，启动前读到的桌面已转为全屏。此后四分钟没有收到系统桌面变化通知。本次第三方窗口夹具没有启动，窗口操作为零。同源码的隔离 Host 已完成签名封装。预览定向与实机检查共 11 项通过，完整 Swift 回归 828 项通过、4 项跳过。[原始桌面读数与机器收据](../verification/native-spaces/5.22-90-active-display-previews/card-mount-5bd0732.json)

GitHub 在 `5bd0732` 上的原生协议作业因没有空闲 ARM64 runner 而结束，未执行任何步骤。覆盖修订 `6828bb5` 在相同产品源码上完成原生 CI，帧流与缓存两个测试套件均通过。macOS 27 专项桌面文件作业按条件跳过。[首次作业记录](https://github.com/haohongfei2001-png/nearpane/actions/runs/45448568514) · [预览修复 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45451855949)

此前签名开发候选为 `d11d101`，回滚包为 `009d330`。一扇窗口首次取得缩略图或被缓存移出时，只通知它自己的卡片。26A428 实体机上，两扇受控窗口验证了回到红窗时直接复用原位图，首帧新增捕获为 0。旁窗首次出图和被移出时，红窗卡片两次均未收到刷新通知。红窗变绿后，蓝窗仍保持原色。[实机记录、签名候选和回滚包](../verification/native-spaces/5.22-90-active-display-previews/sibling-refresh-d11d101.json) · [原始数据及卡片画面](../verification/native-spaces/5.22-90-active-display-previews/sibling-refresh-d11d101.zip)

修正了隔离验收包中旧焦点函数名导致的 Guardian 编译失败，两个构建配置均已编译。完整 Swift 回归 827 项通过、4 项跳过，预览和引擎源码 CI 通过。实体机在准备时为普通桌面，启动前已转为全屏，签名夹具未启动。单窗退场、实际输入隔离与整组往返仍待实机验证。[预览 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45442008068) · [引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45442724977)

此前签名候选为 `009d330`，回滚包为 `a34161a`。修复了工作集合缩略图的一分钟失效。切到另一桌面期间，近期开过的组合继续在原有内存预算内保留画面。回到原桌面时，侧栏复核成员、进程及原窗口身份，再显示同一张图。已退场窗口仍由原恢复事务管理。[源码](https://github.com/haohongfei2001-png/nearpane/commit/009d330dae1f007f040731974ead1bac553fa641) · [签名候选、回滚与 CI](../verification/native-spaces/5.22-90-active-display-previews/group-return-009d330.json)

修复前，组合成员按时间到期和显示器暂时被系统覆盖两项均复现失败。修复后，在受控目录中将单调时钟推进一小时，两张组合原图均可取回，另一原生桌面的目录读到零张。实体机上另用两扇真实窗口验证了返回卡片首帧零新增捕获，以及单窗变色后另一窗保持原图。完整回归 827 项通过、3 项跳过。日常安装版 `bec6cb2` 的签名指纹在前后核对一致。[修复前后原始记录和卡片图像](../verification/native-spaces/5.22-90-active-display-previews/group-return-009d330.zip)

上一份候选为 `a34161a`，其回滚包为 `1fe783c`。 滑动切换桌面或切回窗口时，侧栏可以在取到新帧前直接绘制原窗口上次确认的画面。重新收到相同内容时复用原位图，内容变化时只更新对应窗口。读到新桌面目录前，旧卡片仅供显示。确认桌面为空、窗口换代或共享被撤回时，会撤下原画面。[源码](https://github.com/haohongfei2001-png/nearpane/commit/a34161a180163bd86b0275f8b3a61923e6796708)

在 macOS 27.0（26A428）实体机上，红、蓝两扇测试窗提供了真实 WindowServer 画面。重新呈现红窗卡片时，首帧直接使用同一张红色位图，新增捕获次数为 0。后台恢复采集后，相同画面仍复用原图。红窗变绿时，蓝窗像素保持原值。两扇测试窗均已关闭，前台保持原样。该项覆盖生产卡片渲染与测试进程自己的窗口。标准安装版三指滑动的端到端观感为 **NOT_RUN**。首次实机复现、修复前后的像素、清理结果及签名候选均可复核。[实测与候选收据](../verification/native-spaces/5.22-90-active-display-previews/preview-return-a34161a.json) · [原始读数和卡片图像](../verification/native-spaces/5.22-90-active-display-previews/preview-return-a34161a.zip)

上一份 Corner 开发候选为 `1fe783c`，其回滚包为 `9aa87c9`。 已修复窗口到达角落后画面或输入隔离未能确认时的归位路径。原 Host 先记录这扇窗的恢复意图，再核对它的位置、旁窗、原焦点和用户最新选择。原 Guardian 同意后，Rust 最多发出一次归位操作。原 Host 和 Guardian 各自复核原位，Swift 才结清该窗。若 Host 在归位后、确认前退出，Guardian 须取得内核退出和原写入者已离开的证据，再连续两次读取原窗。工作集合的活动状态继续以整组切换结果为准。[源码](https://github.com/haohongfei2001-png/nearpane/commit/1fe783c940d6001bf51d4abde754bae0bcfdc74c) · [候选、回滚包和实测边界](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/development-candidate-1fe783c.json)

隔离回归覆盖正常归还、旁窗移动、用户快速改选和终结回执丢失。Swift 完整回归 822 项通过，3 项跳过，Rust 126 项通过。两项源码 CI 均通过。开发包及 14 个可执行组件通过验签和解压复验，候选与回滚包均已从 GitHub 草稿下载核对。本轮第三方窗口写入次数为零。[原始记录](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/live-measured-corner-return.zip) · [引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45413909975) · [原生协议 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45413910060)

**真实工作集合切换仍为 BLOCKED。** 在 26A428 实体机上，首次检查因 12 秒内有 60 次输入计数变化而在启动前停止。输入安静后，隔离签名 Host 实际启动，确认了原焦点，并连续两次读到原生全屏桌面（type 4）。随后四分钟内系统没有发出桌面改变通知。Host 自读辅助功能、输入监听和事件投递均已授权，屏幕录制未授权。已有实机证据确认独立观察器可以读取登记测试窗口的独立画面。Corner 绘制退场区域所需的壁纸画面仍由执行 Host 自己读取。本次未创建测试窗。Host 已正常退出，观察通道已清理，日常 Nearpane 在前后两次均处于停止状态，签名、配置和恢复记录指纹一致。[实机原始读数、清理、交互与回归收据](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/display-marker-and-card-input.zip)

下一次实机操作是在系统自然回到普通桌面、且执行 Host 具有现有合法画面权限时，由正式执行器让一扇签名测试窗口退场，独立核实画面、完整鼠标手势、键盘收件和 Guardian 归位。登记窗口在物理显示器上的新色标核验、退场窗口恢复、正式侧栏 A→B→C→A、10/50 次和同机性能对照均为 **NOT_RUN**。

### 此前的候选和真实窗口证据

**此前签名开发候选为 `9aa87c9`，回滚包为 `b204a44`。** 若 Guardian 在 Host 退出后把一次未完成退场的窗口送回原位，并连续两次核实原窗，重启的 Host 可以读取原写前记录、实测停放位置及终结收据，只结清该窗。批次中此前的操作和其他窗口的责任继续保留，活动组不会因此变更。回归在隔离资料中验证了这条路径，窗口写入为零。Swift 821 项通过、3 项跳过，两项源码 CI 通过。两份开发签名包均已校验。[候选与验收结果](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/development-candidate-9aa87c9.json) · [修复前后的原始收据](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/guardian-measured-return.zip)

**此前签名开发候选为 `b204a44`，回滚包为 `cc1aa89`。** Rust 在同一扇窗口的实测停放位置连续两次一致后，立即通过该窗口原先认证的管道交给 Guardian。若 Host 在稍后的画面核验期间退出，Guardian 可以继续核对原 AX 对象、几何、归属、焦点和写前日志。实测位置发送前发生中断，仍保留未决责任。正式侧栏快速改选时，只有原 Rust 引擎排除已受理的请求，且原 Guardian 核实窗口仍在原位，才会撤回对应写前记录。

本机真实管道验证了发送端全部关闭后仍可收到完整位置记录，错误窗号、变化的坐标和截断消息均被拒绝。上述验收的窗口写入次数为零。Swift 819 项通过、3 项跳过，Rust 125 项通过。两项原生源码 CI 成功，候选的 14 个可执行组件通过验签；候选和回滚包均从未发布的 GitHub 草稿下载核对。[源码与签名收据](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/development-candidate-b204a44.json) · [修复前后的原始证据](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/guardian-worker-landing.zip)

此前的开发候选为 `cc1aa89`，回滚包为 `c055dc4`。 两个退场窗口在角落重叠时，Nearpane 现在会逐一核对 WindowServer 预测的窗号和 Quartz 事件报告的收件窗号。发现两者矛盾时，立即中止使用该窗口顺序。能确认收件窗归属时，继续拦截本次手势直到抬起。事件报告的 PID 与窗口所有者矛盾时，整次手势交还系统。修复前，两个不同窗号会被同一次匹配误判为正确，已保留可复现的失败记录。Rust 全部 125 项、Corner 定向 84 项通过，链接最新静态库的 Swift 完整回归 818 项通过、3 项跳过。当前源码的 Rust、Swift 与生产 C ABI CI 通过，托管桌面作业跳过。两份签名包均已从 GitHub 内部草稿下载并核对。修复的验收使用可控的事件字段和窗口顺序，物理桌面上的真实收件仍待单窗验证。[当前候选和各项资格](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/development-candidate-cc1aa89.json) · [修复前后的原始日志](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/parked-recipient-identity.zip)

上一份签名开发候选为 `c055dc4`，其回滚包为 `504e588`。点击组合预览的重叠处会选中前窗，点击后窗露出的部分可选中后窗。拖动时沿用相同的窗口身份和前后顺序。把成员拖出侧栏并释放到同一显示器的工作区域，可以将它移出组合。窗口换代、前后顺序不明、跨显示器释放或在菜单栏释放时会取消操作。36 项定向检查在连接实体显示器的 AppKit 测试面板中通过。完整本机 Swift 回归 818 项通过、3 项跳过，首轮受限环境中的失败已保留。两项源码 CI 通过。候选整包及 14 个可执行组件已严格验签，候选与回滚包均已用 GitHub 内部草稿下载核对 SHA-256。[候选、回滚、CI 和分项结果](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/development-candidate-c055dc4.json)

恢复过程中，如果窗口已经两次读回原位、Guardian 的最终回执稍后才落盘，侧栏现在会在原 Guardian 退出后处理这份回执。它重新核对窗口代际、几何、原生归属、旁窗和焦点，只读取已登记的同一次归还记录。用户已经移动窗口、回执仍缺失或还有未确认的窗口动作时保留恢复责任。已在故障注入中复现修复前窗口已归位而事务无法结束的问题；实际退场窗口上的迟到回执仍待实机验收。此次完整 Swift 回归 815 项通过、3 项跳过。[修复前失败、修复后与完整回归](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/guardian-release-after-return.zip)

前一签名开发候选为 `504e588`，回滚包为 `539eb42`。两个草稿附件均已核对完整 SHA-256，14 个可执行组件通过严格验签。该源码的两项 CI 通过。[候选、回滚及两项 CI](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/development-candidate-504e588.json)

前一候选 `539eb42` 已验证侧栏成员选取和遮挡层级。本机完整 Swift 回归 814 项通过、3 项跳过，Corner 定向 83 项通过。侧栏与引擎两次源码提交触发的三项 CI 均通过；托管桌面作业跳过。ARM64 开发包及 14 个可执行组件通过严格验签。已从 GitHub 内部草稿独立下载当前候选并核对 SHA-256，上一候选 `74fc1cc` 的回滚包也已复核。日常版本继续运行。产品仍缺少一扇真实退场窗口的画面及键鼠收件证据，正式工作集合切换保持关闭。[签名、回滚和 CI 收据](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/development-candidate-539eb42.json) · [WindowServer 原始读数、回归及失败记录](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/workset-member-and-sheet-order.zip)

在 26A428 实体机上，AppKit 完成遮挡面板重排时，WindowServer 仍返回旧顺序。Corner 现在原位移动同一面板，每次提交一次层级指令，再独立读回。同一签名测试进程的三个窗口中，首次确认新顺序在指令发出后 15.4 毫秒，第二次在 28.6 毫秒。未确认请求到期后没有再次派发。三个测试面板全部关闭，前台、HID 和原生桌面保持一致。此项为面板层级验收；第三方窗口退场及实际输入隔离仍未执行。

非活动组合的历史画面现在可选择具体窗口。按下和抬起必须命中同一批画面的同一成员；真实切换事务会再核对该成员的 AX 对象、窗口代际、桌面归属和恢复责任。标题及画面空白处仍恢复上次焦点。26A428 上的定向验证已覆盖同应用两窗重叠、缺图、拖动、按下后换代及整组恢复的焦点选择。此次指针事件只交给未显示的 R4 测试面板；实体机第三方窗口退场和键盘输入仍待验收。

**R4 侧栏整组切换尚未取得生产资格。** 目标实体机 26A428 上，Guardian 已在测试 Host 正常退出和异常退出后，将屏内偏移 24 点的签名普通窗口恢复到原位。独立观察器也已两次验证正式引擎面板完全遮住受控色块。[正常退出归位](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/visible-return/session.json) · [异常退出归位](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/abrupt-visible-return/session.json) · [实际遮挡读回](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/occlusion-control.json)

产品源码 `74fc1cc` 修复了切换中断后的恢复及旁窗输入。系统面板短暂遮住退场区域，也会撤回当次切换。窗口全部归还且焦点连续两次核实后，协调器可以结束恢复日志。系统只给出旁窗的窗号，或只给出另一应用的收件进程号时，执行器会让该收件人收到完整的按下、拖动和抬起。若用户已在保护区域外重新点到原窗口，引擎会交还控制权。修复前，只有外部进程号的按下被错误拦截，现已通过同一条件的回归。[窗口归还与旁窗收件](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/workset-input-ownership.zip) · [跨应用输入失败和修复收据](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/development-candidate-74fc1cc.json)

**实机读回。** macOS 27.0（26A428）、ARM64、SIP 开启。普通桌面 6 上，AppKit 两轮查询四角各 5 个位置，返回的点击目标与截屏面板的前后关系一致。两轮均有 16 个目标在 Apple 截屏面板下方、4 个在上方，面板自身为 0。前台、桌面及输入计数稳定。全程发送事件 0、采图 0、窗口写入 0。退场区域的实际画面及键鼠收件仍待证明。隔离执行 Host 的录屏准入为 **BLOCKED**，单窗完整隐藏恢复、R4 A→B→C→A、10/50 次及性能对照均为 **NOT_RUN**。[实体机采样与未执行项](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/workset-input-ownership.zip) · [执行 Host 的原始准入](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/result.json)

**前一签名候选。** `74fc1cc` 的 5.22（90）ARM64 包已解压复验，整包及 14 个可执行组件均通过严格签名检查。本包和前一包 `fa59777` 均已从 PR #15 原有的内部草稿附件独立下载，两包的 SHA-256 各自与本机严格验签的原包一致。最新 Rust 整库 124 项通过，Corner 定向 83 项通过。相同 Swift 源码的完整本机回归 812 项通过、3 项跳过。三次源码提交各自触发的 CI 均通过，托管桌面作业跳过。日常应用保留在原安装路径。[候选、回滚与校验和](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/development-candidate-74fc1cc.json) · [最新引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45329279105) · [Swift 和原生协议 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45326180839)

### 此前的角落、桌面与构建记录

**真实单窗退场的准入为 BLOCKED。** 源码 `0c7f590` 用同一份 WindowServer 层级和 Dock 读数检查本屏候选角落。局部遮挡时可选用另一个安全位置，现有成员、鼠标保护和后续恢复继续绑定到已选角落。侧栏在恢复窗口或移交键盘焦点之前核对所有即将退场窗口的高度，避免把高窗停在会露出过长边缘的上角。

26A428 实体机上，链接正式静态库的只读程序用 49.7 毫秒读到四个角落均为 53（其他窗口层占用）。前后均为普通桌面 4，前台和输入计数稳定。此前已确认 Apple 截屏界面有覆盖整屏的窗口层，它的实际截屏活动未知。[四角读数与回归](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/display-corner-selection.zip) · [原始窗口层证据](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/retirement-site-raw.zip)

Finder 的整屏滚动区域与桌面图标层共享显示范围。连续两轮读回中，区域内 17 个图标控件各自都能对应到同一个真实 WindowServer 桌面窗号。右下、左下、右上、左上候选区分别与 1、0、8、0 个控件矩形相交。直接查询控件中心时，两轮各 17 次均未返回对应控件；左侧区域的画面和真实输入归属仍为 **UNKNOWN**。只读程序仅保存计数，文件名、文档和图像读取数均为零。[原始对象对应与几何计数](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/finder-item-binding-and-system-ownership.zip)

源码 `798ab74` 在协调器恢复目标组或移交焦点之前检查角落层级，移动待退场窗口前复查。正式 Host 仅对本进程、同一显示器、处于正确层级且能接收鼠标的真实 R4 面板作专门处理。隔离执行 Host 的录屏检查仍返回 21，日常 Host `bec6cb2` 缺少新版认证观察接口。第三方窗口退场及键鼠隔离、R4 的 A→B→C→A、10/50 次、多显示器及 Apple 同机对照均为 **NOT_RUN**。[执行 Host 的实机准入](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/result.json) · [独立观察器对测试窗口的读回](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/registered-pixels.json)

源码 `007eb02` 修复了侧栏在桌面读取失败后继续沿用上次调度状态的问题。读回丢失、显示器拓扑变化或系统接管时，Host 立即撤回当前操作。只有重新确认原登录会话、原显示器和原普通桌面，才开始核对待归还窗口。此次通过了快照中断回归；真实退场期间系统接管仍为 **NOT_RUN**。[中断与恢复条件的回归收据](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/workset-home-regression.zip)

源码 `d3f4770` 修复了系统台前调度开关在准入期间出现时仍可能被读成关闭的问题。Host 和执行引擎只查询这一个设置。设置读取有矛盾时让渡调度权，执行引擎在实际移动或归还窗口前再次核对登录会话、系统台前调度和安全输入。实体机上，两次只读核对均确认系统台前调度关闭，两端结论一致。窗口退场途中发生系统接管仍为 **NOT_RUN**。[实机读回及针对性回归](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/finder-item-binding-and-system-ownership.zip)

源码 `d3f4770` 的 5.22（90）ARM64 开发候选已解压复验，整包及 14 个可执行组件严格验签通过。Swift 本机回归 811 项通过、3 项跳过，Corner 定向 78 项通过。窗口引擎及原生协议两项 CI 通过，各有一项桌面作业跳过。`0c7f590` 保存在本机，可供回滚。[候选签名与校验和](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/development-candidate-d3f4770.json) · [上一候选及 Rust 全库回归](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/development-candidate-0c7f590.json) · [窗口引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45321563840) · [原生协议 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45321563860)

### 工作集合退场后的恢复责任

Host 现在从 Guardian 接受窗口前起持有对原签名进程的内核观察，直到该窗归位。PID 和出生时间相同但进程更换映像时会停止新的健康、显示和退场派发。窗口归还后，Host 须核对同一份准备记录、角落位置及两次原位读回。若应答丢失，只有原映像已正常退出并有完全匹配的持久化最终收据，才能解除责任；不确定时保留日志。

26A428 实体机上，受控子进程保持 PID 和出生时间更换映像时，内核检查将其拒绝，并正确识别另一观察期间的真正退出。独立临时文件和管道复现应答端关闭，最终收据仍可读。该试验的窗口写入数为零。Corner 回归 76 项、完整 Swift 回归 809 项通过，3 项跳过。普通窗口真实角落退场、退场后的输入收件和正式侧栏整组循环仍为 **NOT_RUN**。上一源码 `e32738c` 的签名包已保留作回滚。[原始内核事件与回归](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/guardian-lease-lifetime.zip) · [回滚包签名指纹](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/development-candidate-e32738c.json)

重复点击已聚焦的工作集合时，协调器会核实执行引擎健康、当前显示器与桌面、成员和旁窗、真实焦点与已保存布局。连续读回一致时保留原恢复日志，与集合目录一起原位核验。用户已手动移窗时保存新布局，核验中焦点被用户移走时立即让渡。22 项协调器回归通过。完整回归首次在命令沙箱内出现图像解码及测试文件书签错误并停滞，保留为失败。正常测试环境完整串行回归 808 项通过、3 项跳过。整组实机切换仍为 **NOT_RUN**。[针对性与完整回归收据](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/focused-workset-selection.zip)

## 实体机上的窗口遮挡与鼠标透明度

在 26A428 普通桌面 4，签名观察器将自己的 16×16 点彩色小窗放在正式引擎的面板下方。两次从 WindowServer 取实际叠放画面，每次 60,544 个像素。采样中排除面板时，均出现 1,024 个高对比像素；包含面板时，整个区域与前后两帧实时壁纸的差异像素均为零（每通道容差 1）。引擎分别读到面板画面不透明度 1、鼠标命中权重 0。两扇自有窗口已连续两读确认退出，前台进程和原生桌面保持一致。首次采样未取得结论，原始记录保留为 **UNKNOWN**。[实机读回](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/occlusion-control.json) · [两次原始记录和回归](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/occlusion-control-raw.zip)

Corner 现在按 WindowServer 的真实透明度、矩形和层级验证遮挡；忽略鼠标的窗口仍可遮住另一扇窗口。签名普通窗口的隔离验收已改为采样实际叠放的窗口和对照画面，画面无法确认时先还原已登记目标。隔离 Host 的录屏准入仍为 **BLOCKED**。第三方普通窗口真实退场、退场后鼠标和键盘收件、R4 整组循环和 10/50 次均为 **NOT_RUN**。生产调度资格尚未取得。

源码 `47109e5` 的 5.22（90）ARM64 开发候选已完成解压复验，14 个可执行组件及整包通过严格签名校验。Host CDHash 为 `72fef02744d8309cc1c124316c39a5946e6563f1`，压缩包 SHA-256 为 `843f55754b43dae403fd41bb74fa3cec0369f940c1f762345cb55a50f6cfa185`。GitHub 的窗口引擎与原生协议两项 CI 均通过，两项桌面作业跳过。开发包和前一版回滚包保存在本机，公证与发行验收尚未执行。[候选签名与校验和](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/development-candidate-47109e5.json) · [引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45298541506) · [原生协议 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45298541617)

## 工作集合切换期间的输入与画面连续性

同一应用在停放窗口上方新建旁窗时，Quartz 可能先报告新窗接收按下事件，稍后才在窗口列表中列出它。Corner 现在会把整次按下、拖动、释放保留给这个旁窗，并撤销不一致的输入读数。显示器、原生桌面、面板几何和实时前后顺序均一致时，组成员增减可复用仍有效的面板画面。壁纸刷新逐像素一致时保留已绘画面。实机停放后键鼠命中、R4 整组循环与多屏调度仍待验证。

Rust 全部后端 116 项、Corner 定向 75 项通过。Swift 首次并行回归有 3 项超时或未满足限时断言；这 3 项单独串行通过，随后完整串行回归 806 项通过、3 项跳过。首轮失败与复测均已保留。上一源码 `d300d3c` 的 ARM64 开发候选通过 14 项签名及压缩包解压复验。[完整回归](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/workset-continuity-regression.zip) · [签名候选指纹](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/development-candidate-d300d3c.json)

## 2026-11-24 · 正式遮挡面板的实际画面

在目标实体机普通桌面 4 上，签名观察器使用正式引擎创建一个非激活面板，置于普通窗口下方。WindowServer 为面板 84616 和 Apple 壁纸分别提供画面，连续两次对比整块 86×176 点区域，所有像素均不透明，各通道相差不超过 1。关窗后第一次系统读回仍能看见面板，随后连续两次确认消失。前台进程与原生桌面均保持一致。第一次只检查一次清理的总结果保留为 **UNKNOWN**，随后独立确认当时的窗号已消失。[实机记录](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/rendered-panel.json) · [原始收据及完整回归](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/rendered-panel-raw.zip)

引擎在承认角落遮挡前，现须核对真实壁纸与实际面板的逐像素结果，并持续核对窗口层级、显示器、桌面及输入保护。已去掉仅凭本地文件推定当前壁纸的路径。本机两次画面对比分别耗时 654 与 742 毫秒；这只测量可见性验证，工作集合切换延迟仍待实测。隔离 Host 的录屏权限仍缺失。真实第三方窗口退场和输入隔离继续 **BLOCKED**，正式侧栏循环及 10/50 次稳定性继续 **NOT_RUN**。

## 2026-11-24 · 保持其他停放窗口的画面和输入保护

正式引擎恢复一扇窗口时，会继续遮住其他已核实的停放窗口。只有正在移动的窗口所在显示器的角落会进入输入归属重新确认。Rust 双后端回归 115 项及 Corner 定向 74 项通过。多屏实体切换尚未执行。[回归原始日志](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/sibling-protection-regression.zip)

在 26A428 上独立比较实际壁纸与系统默认 HEIC 的居中填满结果，连续两帧各 60,544 个不透明像素中，只有 6 个的各颜色通道均相差不超过 1。该文件作为本机角落替代画面为 **FAIL**。签名观察器只在规定的壁纸区域内计数。5.22（90）源码 `0c16a9d` 的本地签名候选完成 14 项可执行签名和压缩包还原校验，原安装保留。[实机逐帧结果](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/sealed-default-comparison.json) · [候选指纹](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/development-candidate-0c16a9d.json)

## 2026-11-24 · 同一扇窗口的独立画面读回

在 26A428 的普通桌面 4 上，隔离 Host 59465 和已授权的签名观察器 59461 通过本地连接相互验签，共同定位到测试窗 84451。观察器只采集该窗自己的内容，两次均识别出 16/16 条一次性标记。跨进程传递的是计数和时间戳。第一次采用后台视图绘制时，两次结果均为 0/16；在窗口所属应用内确认绘制次数为零后，夹具改为主动提交自己的图层。三次运行均核对了日常 Host 的身份、权限和配置。第二次提前退出，原始关窗回执仍为 UNKNOWN，后续读回已确认该进程退出且属于它的系统窗口数为零。[实机结果](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/registered-pixels.json) · [原始收据及回归](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/registered-pixels-raw.zip)

**当前边界**　隔离 Host 自身的录屏读数为 false，正式 Rust 停放预检返回详情 21。独立观察器取得的是单窗内容。实际角落遮挡、退场后的鼠标及键盘收件、正式侧栏 A→B→C→A 和 10/50 次仍为 **NOT_RUN**。生产窗口写入保持关闭。

引擎现在会在用户改选或停放超时时撤销写入权。已经发出的移动最多保留 500 毫秒供只读测量把精确位置交回 Guardian。窗口身份、原生归属或位置不完整时，保留待恢复责任。源码 `d3db323` 的 Rust 整库 86 项与 Corner 定向 73 项通过。

## 2026-11-24 · Host 中断后的真实窗口归位

R4 工作集合现在保留用户自己最小化的组成员。点击整组时，焦点可落到仍能交互的同组窗口；明确点名字的单窗仍须精确命中。协调器持续核对受保护窗口，用户通过 Dock 恢复非活动窗口会撤销活动集合的判断。历史组合只绘制离开时独立可见的成员。本机完整源码回归 805 项执行通过、3 项跳过，包含同应用双窗和相互矛盾的画面读数。整组实机切换仍为 **NOT_RUN**。[完整 xUnit 收据](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/protected-worksets-xunit.zip)

**PASS，限屏内归位。** 在 26A428、ARM64、SIP 开启的普通桌面 4 上，隔离 Host `8c5ddf8` 向 Guardian 交接后直接退出，跳过 Host 的清理。内核对同一 PID 50655 返回 `NOTE_EXIT | NOTE_EXITSTATUS` 和原始状态 19200（退出码 75）。Guardian 50674 随后只写入一次，把签名夹具窗口 84388 从 (649, 407) 送回 (625, 407)，尺寸 220×143。两次独立 AX / WindowServer 读回和夹具自己的 AppKit 读回一致。日常 Host 的身份、权限、配置和已有恢复记录指纹相同。已归档该次夹具的原始文件并移除两个临时会合目录。角落退场、退场后输入隔离及 R4 整组循环仍待实测。[实机读回](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/abrupt-visible-return/session.json) · [内核退出和清理](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/abrupt-visible-return/cleanup.json)

## 2026-11-23 · 真实窗口与恢复责任

正式 Rust 引擎已在实体机的普通桌面 4 验证包括阴影的 **86×176 点完整材质区域**。同一个无窗口写权限的句柄首次用时 359.2 毫秒，复用用时 34.2 毫秒，两次都返回 Apple 壁纸窗口合成来源。运行者为持有自身录屏授权的签名观察器。实际窗口遮挡、键鼠接收者和整组切换仍为 **NOT_RUN**。每次停放前，执行 Host 继续核验自己的权限和 Guardian 的恢复责任。[两次读回与签名](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/material-readback.json) · [离线回归与原始收据](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/material-regression.zip)

在同一块实体屏幕上，上游的显示器正向窗口过滤方式取得了两帧完整的壁纸样本。过滤器仅包含经签名核验的 Apple 壁纸窗口，8×8 点在本机对应 16×16 像素，两次 256/256 像素均完全不透明。完整遮挡区域和退场窗口输入仍待验。`3384cf1` 的 5.22（90）ARM64 开发候选已打包，14 个可执行组件及整包签封已核对。[原始画面计数](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/material-readback.json) · [候选签名与校验和](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/development-candidate.json)

切换时如有窗口需要退场，协调器现在会先核对该显示器的角落是否可用，再恢复目标窗口或移交键盘焦点。定向 Swift 回归 41 项通过。Rust 测试确认这次预检不接受窗口写入参数。目标机右下角的实机画面证据仍不足，整组切换未执行。[预检与实机画面记录](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/material-readback.json)

Corner 已能把“已测到窗口到达角落，但画面或输入验证失败”单独交给 Guardian。后者独立双读、持久化实际位置，Host 继续将切换标记为 UNKNOWN。只有原 Host 退出，而且窗口、焦点、输入、桌面及两份持久化记录仍一致时，Guardian 才可归位。该分支已通过定向源码回归，真实角落归位待验。[恢复责任与测试结果](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/guardian-preparation.json)

对实体机的进一步读回确认，系统壁纸别名解析到密封系统卷中的单帧图片。引擎现按 AppKit 的默认等比适应模式核算实际覆盖范围。该机屏幕中心的 8 点方块在图片内，右下角的 8 点方块在图片外。独立签名观察器仅采样 Apple 壁纸窗口，两次各有 56/64 个不透明像素。这次单窗取图保留为 **BLOCKED**。之后的显示器合成实测见本节首条。[源文件、裁切和两次实机采样](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/material-readback.json)

Corner 在移动窗口之前会用实际渲染器的规则检查壁纸缩放、图像尺寸、朝向和帧数。首次检查时，内置屏的系统壁纸 URL 位于原先两处只读资源目录以外，旧的来源检查返回不支持。本次没有打开该文件或采集用户画面。[目标机来源和隔离回归](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/corner-picture-source.json)

**屏内真实归位 PASS。** 在 26A428 / ARM64 / SIP 开启的实体机上，源码 `d621e0f` 的隔离 Host 15712 正常退出，Guardian 15739 在内核退出与原管道 EOF 后执行一次受保护的 AX 归位。签名夹具窗口 82959 从 x=649 回到 x=625，y=407、尺寸 220×143。AX、WindowServer 和窗口所属应用读回一致，原生桌面仍为 4。夹具、Guardian 和临时资料已清理，日常 Host、权限、配置和旧恢复日志前后一致。该窗平移期间一直在屏内；角落画面遮挡、实际输入隔离、异常中断恢复和整组切换仍为 **NOT_RUN**。[实机与原始读回](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/visible-return/session.json) · [退出和清理](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/visible-return/cleanup.json)

独立签名的验收观察器在 26A428 上读取到自身录屏授权。该次读取发生在枚举窗口前，采集帧数为零。隔离包新增一次限定在普通显示区域内的恢复入口，签名夹具自行将一扇后台测试窗平移 24 点，Guardian 仅可在确证父进程退出后将该窗归位。原只读协议和发行包均没有这项写入入口。[观察器本机授权](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/visual-observer.json)

`19505ea` 已加固真实窗口的写前交接。Guardian 在首次移窗前持久记录自己和 Host 的进程出生代、目标窗口、原始几何和桌面归属。Host 提交前复读该记录。恢复时按显示器 UUID 核对完整拓扑，跨屏残条和显示器布局变化会中止写入。隔离回归通过，实体多屏和停放后实际恢复仍待验收。正在运行的日常 `bec6cb2` 仅提供权限和预览统计，缺少可认证的一次性画面观察入口。[分项收据与上游来源核对](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/guardian-preparation.json) · [原始日志](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/guardian-preparation-logs.zip)

**Guardian Survival 已通过隔离签名 Host 的实机验收。** 在 26A428、ARM64、SIP 开启的普通桌面上，内核确认 Host 78729 退出。Guardian 78748 随后以自己的权限身份，通过原有 AX 对象连续两次读到窗口 81949，窗口身份、AX 与 WindowServer 几何、原生桌面 4 全部一致。签名夹具和两个测试进程均已退出，两处临时目录已清理。日常 5.22（90）的进程出生代、权限、配置及窗口恢复记录前后一致。[完整实机收据](../verification/window-engine/guardian-survival-26A428/internal-host/05-confirmed-original/session.json) · [清理回执](../verification/window-engine/guardian-survival-26A428/internal-host/05-confirmed-original/cleanup.json)

**正式 Corner 执行器的同窗读取通过，单窗口退场仍未执行。** 在另一次独立登记中，Rust 和签名窗口所属应用均连续两次确认窗口 81791 的位置、尺寸和原生归属。开发 Host 的停放前检查返回 `unsupported`，原因码 21 对应屏幕录制未授权。该测试包仅支持只读交接。真实停放、鼠标及键盘隔离、实际恢复、侧栏 A→B→C→A 和 10/50 次均为 **NOT_RUN**。生产切换保持关闭。[产品读回](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/session-host.json) · [分项资格](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/qualification.json)

产品修复涵盖鼠标按下与窗口清单更新并发、遮罩尚未出现在窗口合成器时过早报告隐藏，以及主程序在窗口所有权落盘后、收到恢复确认前退出。`1b03f10` 的内核退出与管道回归通过，完整 Swift 回归 799 项通过、3 项跳过。沙箱内首次完整回归失败，原始日志已保留。下一项实机门槛是验证对实际停放窗口的持久恢复责任。[内核交接](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/guardian-park-ack.json) · [离线回归与失败原文](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/local-regressions.zip) · [引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45181410863)

`c5c1123` 将写前日志、恢复进程的责任目录和最终回执同步到磁盘。主程序在日志持久化前不会继续窗口操作，恢复进程在最终回执持久化后才确认归还。隔离资料上的完整 Swift 回归为 800 项通过、3 项跳过；恢复实际停放过的窗口仍为 **NOT_RUN**。[窗口事务与归还验证](../verification/window-engine/stage-switch-admission-26A428/corner-product-window/qualification.json) · [窗口引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45184265264) · [原生协议 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45184265064)

上一轮仅观察到普通桌面从 6 切至 4，期间 HID 计数未变。夹具未启动。随后到达的同一 nonce 日常 Host 权限记录另存，整次运行仍按原收据保留 **UNKNOWN**。[原始运行](../verification/window-engine/guardian-survival-26A428/internal-host/04-space-change/result.json) · [延迟到达的系统日志](../verification/window-engine/guardian-survival-26A428/internal-host/04-space-change/delayed-permission-event.json)

## 2026-11-23 · 隔离签名 Host 与 Guardian 实机验收

26A428 / ARM64 / SIP 开启。系统通过 Launch Services 后台启动独立开发 Host，团队签名、完整资源签封、实际路径及进程出生代均已核实。开发 Host 的辅助功能和输入监听有效，屏幕录制未授权。Guardian 在 Host 存活时的权限责任主体为 Host。日常 `bec6cb2` 全程保持同一进程，四项权限、配置与恢复资料一致。[签封收据](../verification/window-engine/guardian-survival-26A428/internal-host/signed-package.json) · [全屏阻塞原始记录](../verification/window-engine/guardian-survival-26A428/internal-host/01-fullscreen/result.json)

普通桌面首次执行中，内核确认 Host 正常退出。Guardian 成为自己的责任主体，从保留的 AX 对象两次读到真实签名窗口 78627，AX、WindowServer 几何和原生归属一致。整轮为 **UNKNOWN**。Host 的第一次登记采样未确认夹具，第二次确认；退出后的双读子项为 **PASS**。夹具与两个测试进程均已退出。后续登记增加窗口所有者的 WindowServer 连续双读，并在 Host 的双向归属通过后装载退出观察。[登记与清理](../verification/window-engine/guardian-survival-26A428/internal-host/02-registration/session.json) · [两次原始读回与内核退出](../verification/window-engine/guardian-survival-26A428/internal-host/02-registration/session-host.json)

## 2026-11-23 · 历史基线 0ea2bd0 的工作集合切换与 Guardian

5.22（90）产品源码为 `0ea2bd0`。Corner 生产调度保持 **NO-GO**。本轮完成侧栏选择、窗口所有权及执行器的修复。该源码的 GitHub 窗口引擎与原生协议检查均已通过。正式 Host 退出后的原窗口 AX 双读仍为 **NOT_RUN**。[机器总表](../verification/window-engine/stage-switch-admission-26A428/result.json) · [GitHub CI 回执](../verification/window-engine/stage-switch-admission-26A428/github-ci.json)

| 范围 | 结果与证据 |
| --- | --- |
| 侧栏连续选择与活动组提交 | **PASS，隔离事务测试。** 用户改选时，旧事务停止发起动作。已确认的窗口变化、旁窗和焦点通过两次新读取后，同一执行器可以保留已有租约，交给最新选择继续。未知写入、单个成员失去租约、焦点显示器改变或几何漂移，都会阻止提交活动组。[66 项定向回归](../verification/window-engine/stage-switch-admission-26A428/scope-xunit.xml) |
| Guardian 写入前检查 | **PASS，进程与管道实测。** Host 把准备回执绑定到确切意图及子进程出生代。Rust 核对运行中的签名映像，并在 AX 设置位置前检查内核通知。26A428 上的一次性子进程在同 PID、同出生代执行新映像时被识别，正常退出也撤销资格。Host 静默 9 秒后，管道仍接受第一条指令。[内核原始收据](../verification/window-engine/stage-switch-admission-26A428/guardian-kernel.json) |
| 构建与回归 | 隔离开发包已构建，Swift 798 项通过、3 项条件跳过，Rust 109 项通过，C ABI 链接和调用通过。开发包保留工程调试标识 0.2.0（1）。独立 Host 映像和 Guardian 验签通过，完整开发包缺少资源签封。沙箱内 4 个归档日志用例失败，开放所需系统服务后同组 11 项通过。[完整 Swift 回归](../verification/window-engine/stage-switch-admission-26A428/full-xunit.xml) · [原始日志](../verification/window-engine/stage-switch-admission-26A428/local-source-checks.zip) |
| 正式 Host 与单窗 | **准入 BLOCKED。** 标准路径中运行的 5.22（90）为 `bec6cb2`，缺少 Survival 协议。已有带协议正式签名包的哈希与此前被系统拒绝的包相同。最近一次实机准入的两次读数都是全屏，本轮未重新采集桌面。仓库登记的自托管 runner 为 0。[本轮安装与环境核对](../verification/window-engine/stage-switch-admission-26A428/physical-admission.json) · [上次正式包及桌面收据](../verification/window-engine/guardian-survival-26A428/admission-1329/result.json) |

下一次物理验收从已获系统准入的签名 Host 和可安全交还焦点的普通桌面开始。先验证 Host 退出后 Guardian 独立双读同一签名夹具窗口，再验证持久恢复责任。真实单窗输入与还原、侧栏 A→B→C→A、10/50 次和 Apple 同机性能对照均为 **NOT_RUN**。历史最小化和遮罩穿透的 **FAIL** 继续保留。

## 2026-11-23 · 前次产品能力与交付范围

该次审计从 PR `e44d028`、应用源码 `d81329d` 和 5.22（90）候选开始，验收到产品源码 `0e66086`。A 表示可保留交付的已验证操作，适用的安装版本和环境随项注明。B 有独立产品价值，继续开发并补齐对应入口验收。C 缺少目标系统的安全证据，生产调度为 **NO-GO**。整包公开发行仍需单独验收。下列成本为相对工程量。

| 层级与操作 | 产品入口、用户价值与证据范围 | 后续投入与风险 |
| --- | --- | --- |
| A · R4 侧栏显隐、本屏真实预览 | 菜单显隐并自动恢复。正式 5.22 候选上，两窗 48/48 次画面更新，五应用 30/30 张卡对应正确，隐藏一分钟无活动抓屏流。[逐帧实测](../verification/native-spaces/5.22-90-active-display-previews/RESULTS.md) · [菜单与恢复](../verification/native-spaces/5.22-90-installed-contract/RESULTS.md) | 低成本保留。失去窗口身份或录屏权限须撤回画面。与 Apple 同负载的速度尚无结论。 |
| A · 精确选一窗、同屏双窗布局 | 正式候选 `d81c458` 的目标编辑器输入 10/10。`f7997a7` 的左右拖放及跨应用并排有 AX 和 WindowServer 读回。[输入落点](../verification/native-spaces/5.22-90-active-display-previews/same-space-focus/registered-document-runs/09/summary.json) · [分屏](../verification/native-spaces/5.22-90-sidebar-pair/RESULTS.md) | 中。保留逐窗许可和身份复核，组合入口的新交互需按版本验证。 |
| A · 本地资料、设置及档案 | 语音手记、截图历史、侧栏工具选择与排序均有产品入口。旧签名 Host 的隔离档案和主题页已渲染；5.22 的截图收录、原字节重开和停止期间排空有领域测试。安装版可重开已有词条。[档案与设置](../verification/P5.12-UNIFIED-ARCHIVES-AND-SETTINGS.md) · [内嵌模块](../verification/embedded-tools/5.22-90/2026-11-23/results.json) · [词本重开](../verification/native-spaces/5.22-p4/installed-9ba33eb/seeded-wordbook.json) | 低。交付本地资料读写，按当前包复核设置、首次使用和权限说明。 |
| B · 工作组目录、命名、成员与历史图 | 一张卡片可组合多扇窗口，同应用窗口各自有身份。两款签名应用在隔离 WindowServer 上重开后仍为 2+1。组合图可显示已核验的历史画面；当前安装版的多屏、重连、崩溃还原待证。[目录与生命周期](../verification/window-engine/same-desktop-provider-26A428/hosted-fixtures/stage-group-lifecycle.json) · [组合画面](../verification/window-engine/product-integration-20261123/history-preview/receipt.json) | 中，优先。单窗选择与目录编辑可独立交付。过期卡片及复用窗号会造成错选。 |
| B · Saytile 语音、Riftlet 截图附加 | 托盘捕获、档案和草稿附加有正式入口。较早安装候选三句物理语音取得两份准确最终稿，第三句 UNKNOWN。当前内嵌版六份首尾音频回读和两款浏览器的 18 个隔离草稿通过，已登录网站的真实草稿仍 BLOCKED。[安装工具实测](../verification/native-spaces/5.22-90-installed-contract/RESULTS.md) · [锁定的实现与成绩](../verification/embedded-tools/5.22-90/2026-11-23/results.json) | 中，继续。物理收音与真实识别、已授权草稿的真实附加分别验收，保留零发送。 |
| B · 原位翻译、单词本 | Services 回调和收件已验证，英中翻译包缺失，正式原位气泡与来源焦点仍待验；既有词条可独立使用。系统词典的固定词仅做过离屏取词。[服务验收](../verification/native-spaces/5.22-p4/installed-d81c458/README.md) · [词典实验](../verification/window-engine/product-integration-20261123/final-dictionary.json) | 低成本优先改善查阅；中成本补原位呈现。避免将旧译文或词典释义记成新的翻译结果。 |
| B · 桌面图标、常驻工具、首次使用与更新 | 点击空白墙纸显示图标有托管桌面实测。时钟、备忘、待办、主题、全屏工具及偏好可配置。更新通道有状态页和忙碌延后逻辑，干净安装和正式更新待 P6。[桌面图标](../verification/stage-groups/5.22-90/desktop-items/RESULTS.md) · [随包操作说明](../../docs/ALPHA-HELP.md) | 设置低，物理多屏及正式分发高。先完善能直接操作的入口，保留正式发行门槛。 |
| C · 整组退场、激活和恢复 | Swift 目录、事务及 Rust/C ABI 已接入，生产资格清单为空。旧 Corner 穿透，Guardian 退出后双读 NOT_RUN；持久租约、单窗隔离、A→B→C→A 及 10/50 次均未准入。原生 Spaces 迁移退出产品范围。[隔离失败](../verification/stage-groups/5.22-90/isolation/qualification/summary.json) · [最后一次实机收据](../verification/window-engine/guardian-survival-26A428/admission-1329/result.json) | 高。只接受下列单窗门槛的新证据，再决定后续投入。[有限验收合同](ACCEPTANCE.md#corner-的单窗口可行性边界) |

### 本轮产品交付

- **组合卡选窗**　点击组名可选取任意当前成员，包括被同应用另一扇窗口完全遮住的成员。提交操作时复核进程、窗号、窗口代际和所属组。当前候选的卡片空白区没有整组切换操作。源码 `4b27abd` 的 45 项定向测试通过，本轮新菜单在正式侧栏中的键盘落点待验。[选窗回归](../verification/product-value-5.22/group-tests.xml)
- **查找和复用词条**　设置里的单词本支持搜索原文和译文。系统翻译模型不可用时，只有当前资料中原文、语言方向和答案均可确定的已存记录才可用于反馈。26A428 上，隔离请求实际经历了收件、缺少模型和命中已存译文，重开后没有新增词条。该请求没有唤起原位气泡。工具与宿主回归 21 项通过，受限进程先前的 9 项截图读取错误单独保留。[回读时间线](../verification/product-value-5.22/saved-word.log) · [测试与失败收据](../verification/product-value-5.22/result.json)
- **开发包与内嵌模块**　干净源码 `0e66086` 的 arm64 开发包完成 Rust ABI 1 和 37 项资源校验。开发包采用工程调试身份，日常安装沿用原包。内嵌 Saytile 0.20（533）和 Riftlet 1.0.7（53）均有锁定来源。复核时，Saytile #49 后续五笔提交没有修改 `Sources/`，Riftlet #122 后续的适配器改动用于本地测试页面。三项原生 CI 通过。[构建与 CI](../verification/product-value-5.22/result.json) · [Saytile 差异](https://github.com/haohongfei2001-png/saytile/compare/7c0df4728b113c17297a0cded20472de4ffc3337...9ab5ae9bb0a02b122189cc46ba44ab824bbd42eb) · [Riftlet 差异](https://github.com/haohongfei2001-png/Riftlet/compare/b20cefbf94e78ed89643cc27fa95af91bd140960...a9a1c03c9bd0b0d834cc6f9a4f99492cbfa12db2)

下一项产品验收使用两扇同应用重叠测试窗口，从正式侧栏组名选择被遮挡的成员并核对唯一输入标记。单词本另用隔离资料，从设置搜索到已存译文，再核对原位气泡及来源焦点。两项均可独立于 Corner 排期。

### Guardian Survival 实机准入

**最新实机结论为 BLOCKED，Guardian Survival 为 NOT_RUN。** 11 月 23 日 13:29（北京时间），26A428 实体机两次读到全屏，当前原生 Space ID 为 5794，普通桌面 UUID 未取得。两次 AX 读回均为前台 PID 49381 的同一对象，CGWindowID 为 71941，14 项 HID 计数一致。标准路径中唯一的日常 Host 仍为 `bec6cb2`，PID 19081，四项权限均由该进程自读为允许。配置指纹一致，活动租约和测试进程均为零。Host 继续运行，内核退出记录和退出后窗口读回均为空。Guardian 的独立 AX 权限仍为 UNKNOWN，持久恢复租约和首次单窗隐藏均未获准入。[最新实机收据](../verification/window-engine/guardian-survival-26A428/admission-1329/result.json) · [桌面双读](../verification/window-engine/guardian-survival-26A428/admission-1329/desktop.json) · [日常 Host 与租约](../verification/window-engine/guardian-survival-26A428/admission-1329/daily-host.json)

复核的候选仍是 `d81329d` 的原始签名 ZIP。Apple 的 `stapler` 按 Host CDHash 查询已签发票据，返回 `Record not found`（65）。Gatekeeper 返回 `Unnotarized Developer ID`（3）。本机可见的开发配置和该仓库未提供可用的公证身份，Apple 的 `notarytool` 对选定名称 `Nearpane-Notary` 返回 `No Keychain password item found for profile`（69）。本轮公证提交和安装尝试均为零。此次标准路径换装在系统准入处停止，后续按下述内部诊断与发行边界处理。[Apple 票据和系统评估](../verification/window-engine/guardian-survival-26A428/admission-1329/gatekeeper.json) · [公证 Profile 检查范围](../verification/window-engine/guardian-survival-26A428/admission-1329/notary-profile.json)

此前 12:55 的监督器也在发出退出请求前因全屏停止。[12:55 收据与时间线](../verification/window-engine/guardian-survival-26A428/result.json) · [原始桌面双读](../verification/window-engine/guardian-survival-26A428/desktop-readback.json) · [日常 Host 权限](../verification/window-engine/guardian-survival-26A428/installed-host-permissions.json) · [清理核对](../verification/window-engine/guardian-survival-26A428/cleanup.json)

候选 Host 与 Guardian 均含所需协议，CDHash 分别为 `819a44400baf353f9484442505c2a684b768b95d`、`8e2aba5a640ec94d2bef9d731ad6c4735a296225`，与日常版的指定签名要求逐项互验通过。Gatekeeper 返回 **Unnotarized Developer ID**，系统分发检查报告 **Notary Ticket Missing**。当前钥匙串中指定 Apple 服务的无提示元数据查询、项目环境和仓库可见配置未找到可用的 Nearpane 公证身份。准备工具现已将 Guardian 纳入 14 项完整清单并核验签名内的 SHA-256。相同 ZIP 与日常包的私有副本已完成未启动的交换和回退。Apple 上传次数为零。[候选、Guardian 与系统策略](../verification/window-engine/guardian-survival-26A428/images-and-gatekeeper.json) · [凭据检查范围](../verification/window-engine/guardian-survival-26A428/notary-credential-scope.json) · [私有包回退](../verification/window-engine/guardian-survival-26A428/private-package-rollback.json)

监督器 `575c12c` 修复了已完整交付的 Guardian JSON 因缺少末尾换行而被报超时的问题。它在同一代 Host 的挑战应答前向内核登记退出状态，只有退出码为 0 才能通过正常退出检查。17 项读取及监督器测试、11 项私有包测试在本机通过。该调整保留了已验签候选的原始字节。[修复前的超时](../verification/window-engine/guardian-survival-26A428/reader-failure-before-fix.json) · [本机定向测试](../verification/window-engine/guardian-survival-26A428/local-regressions.json)

### 工作组与工具进度

| 对用户有影响的能力 | 本轮结果 |
| --- | --- |
| 本屏工作组和预览 | 正式侧栏可以依据当前显示器、普通桌面和新鲜的窗口见证建立组目录。缺少可写 Provider 时仍可读取已确认的成员。修复并发刷新在等待主线程期间耗尽 AX 读取预算、遗漏兄弟窗口的问题。 |
| 正式 Host 识别第三方窗口 | **PASS，只读。** 在 27.0（26A428）、SIP 开启的实体机上，普通桌面 4、显示器、原前台 AX 窗口和 14 项 HID 计数双读一致。正式安装 Host 对签名夹具窗 71381 两次核对原 AX 对象、进程出生代、AX/CG 几何和双向原生归属。夹具透明且忽略鼠标。 |
| 两款签名应用的真实交互 | 签名与审定镜像 **PASS**。准备登记目标、同应用兄弟和跨应用旁窗时，实体机连续两次读到原生全屏。监督器在退出日常 Host 之前返回 **BLOCKED**。该次夹具启动、窗口和 Space 写入均为零。 |
| Guardian 恢复责任 | 子进程两次报告 AX 可用，系统两次将权限责任归给当时的 Host 19042。Guardian 19051 尚未在 Host 退出后证明原窗口仍可恢复。新代码允许持有原 AX 引用直至内核确认 Host 正常退出，再双读身份、几何和归属。本机内核退出检测 **PASS**，正式 Host 退出后的 AX 读回 **NOT_RUN**，可持久履约的恢复租约 **BLOCKED**。 |
| 单窗与整组 | 受保护停放、画面隔离、完整鼠标按下/拖动/释放、键盘收件和原位恢复均为 **NOT_RUN**。A→B→C→A、10/50 次及同机 Apple Stage Manager 性能对照均为 **NOT_RUN**。AXMinimized 与旧角落遮罩的真实失败继续保留。 |

[逐项机器收据](../verification/window-engine/same-desktop-provider-26A428/qualification.json) · [正式 Host 与 Guardian 读回](../verification/window-engine/same-desktop-provider-26A428/corner-readback-host.json) · [交互窗实机准入](../verification/window-engine/same-desktop-provider-26A428/interactive-supervisor.json) · [内核退出检测](../verification/window-engine/same-desktop-provider-26A428/guardian-kernel-exit.json) · [历史隔离失败](../verification/stage-groups/5.22-90/isolation/qualification/summary.json)

私有 arm64 工程包的 14 个可执行文件及 46 项资源通过校验，Host CDHash 为 `819a44400baf353f9484442505c2a684b768b95d`，Rust ABI 为 1。Gatekeeper 返回 **FAIL / Unnotarized Developer ID**。日常运行的仍为原安装 `bec6cb2`，PID 19081。配置和资料指纹与验收前一致，活动租约为零。一次权限查询未得到答复，保留为 **UNKNOWN**。随后同一 Host 在带随机标识的签名日志中自读四项权限均为允许。[签名与 Gatekeeper](../verification/window-engine/same-desktop-provider-26A428/signed-engineering-build.json) · [清理及恢复](../verification/window-engine/same-desktop-provider-26A428/corner-readback-session.json) · [最终权限收据](../verification/window-engine/same-desktop-provider-26A428/terminal-permissions.json)

同一源码的两项 GitHub 原生 CI 通过。托管 macOS 26.7.2（25G332）的两款普通应用共有三扇可见窗。两个独立读取进程重开后均得到相同的两组，分别含 2 扇和 1 扇窗。鼠标按下、拖动、释放及键盘标记全部由目标 96 接收并写入隔离文档，另两窗 97、95 收件和写入均为零。重新启动一个应用后，原组和两扇旁窗保持，替代窗口加入新的单窗组。该环境的原生归属为 **UNKNOWN**，单窗停放及整组切换为 **NOT_RUN**。[窗口与输入收据](../verification/window-engine/same-desktop-provider-26A428/hosted-fixtures/stage-group-windowserver.json) · [截图](../verification/window-engine/same-desktop-provider-26A428/hosted-fixtures/three-windows.png) · [录屏](../verification/window-engine/same-desktop-provider-26A428/hosted-fixtures/real-input.mov) · [重开与窗口代际](../verification/window-engine/same-desktop-provider-26A428/hosted-fixtures/stage-group-lifecycle.json)

完整串行 Swift 回归共 787 项，784 项通过、3 项按环境条件跳过。全量并发时，语音冷启动和布局过期读回各失败一次。两项共同定向运行及完整串行运行均通过，高并发可靠性仍为 **UNKNOWN**。45 项监督器测试通过。托管构建 26A434 的 21 项引擎检查通过，含 108 项 Rust 测试、119 项 Swift 测试以及生产 C ABI。[回归及原始失败](../verification/window-engine/same-desktop-provider-26A428/regression.json) · [引擎收据](../verification/window-engine/same-desktop-provider-26A428/hosted-engine.json) · [引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45102514956) · [原生协议 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45102514974)

**Corner 暂停在单窗口门槛。** 生产调度保持关闭。只有出现系统正常接纳的新测试 Host 或可恢复的隔离 GUI 环境，才评估下一次只读诊断。公证排入正式发行阶段，产品主线继续。[分发、只读与写入的验收边界](ACCEPTANCE.md#corner-的单窗口可行性边界)

### 历史阶段记录

以下条目记录对应日期和源码的结论，当前实施以上述裁决为准。

## 2026-11-23 · 三扇真实交互窗口与正式 Host

5.22（90）私有候选源码为 `b771114`。隔离 Mac 上，WindowServer 将完整鼠标手势及键盘标记送到目标窗口 133，另两扇同应用及跨应用窗口均为零收件、零文档。候选已把三窗身份、旁窗保护、输入和恢复读回接入现有正式 Spaces 单次迁移入口。26A428 实体机仍为原生全屏，末轮缺少可交还的普通 AX 前台窗口，正式登记、Spaces 和 Corner 三项准入均为 **BLOCKED**。唯一日常 Host 四项权限有效、配置一致、活动租约为零。两种后端的生产资格为 **0/2**，整组和 10/50 次均为 **NOT_RUN**。[分项状态、实录与原始失败](../verification/window-engine/interactive-round-26A428/STATUS.md) · [机器总表](../verification/window-engine/interactive-round-26A428/qualification.json)

## 2026-11-23 · 窗口调度、布局及实机准入

5.22（90）的私有签名候选为 `4701693`。14 个可执行文件均有加固运行时和安全时间戳，Gatekeeper 判定未公证。当前安装的正式 Host `bec6cb2` 四项权限通过，活动租约为零。目标机处于原生全屏，缺少可交还的普通窗口焦点，第三方窗口测试在退出 Host 前停止。调度事务、组内布局、历史预览和托盘语音生命周期已修复并做了离屏回归。生产合格后端为 0/2。[本轮状态、复现与恢复入口](../verification/window-engine/product-integration-20261123/STATUS.md)

## 2026-11-22 至 23 日 · 无人值守实机复核

**P0 BLOCKED，P1 BLOCKED，生产资格 0/2。** 夜间三段实机准入均未执行展示，最后连续 404 次读到原生全屏。正式 Host 的签名、进程出生代、配置及四项权限前后相同，活动租约为零。系统日志证实上次收起时发生了 Edge 到 GitHub Desktop 的前台变更，发起方仍为 UNKNOWN。两项原生 CI 已通过。[分阶段状态、清理与实机证据](../verification/window-engine/overnight-20261122/STATUS.md)

## 2026-11-22 · PR #15 普通桌面 P0 / P1 实机准入

**桌面条 4/4 通过，P0 整体 UNKNOWN，P1 BLOCKED。** 在 26A428、SIP 开启的普通桌面 4 上，同一次展示中两轮各查 170 个坐标。Apple WindowManager 的可见子节点、父节点和 SystemWide 真实命中均证明有四个按钮，顺序与框一致。收起后前台由 Edge（窗口 68518）变为 GitHub Desktop，49 次读取均未取得其 AXFocusedWindow。十四类 HID 计数与原生 Space 清单前后一致。原焦点连续性尚未通过。[实机分项、截图和录屏](../verification/window-engine/p0-p1-admission-26A428/RESULTS.md)

正式 `spaces` 监督器已在日常 Host 退出前执行新门槛。实体机实际返回 BLOCKED，退出请求、第三方窗口登记与迁移均为零。常规 Host 仍为同一 PID、出生代及签名，配置摘要相同，阻塞恢复记录和活动共享租约均为零。两种后端的生产资格仍为 0/2。[P1 收据](../verification/window-engine/p0-p1-admission-26A428/10-p1-supervisor.json) · [清理核对](../verification/window-engine/p0-p1-admission-26A428/11-cleanup.json)


## 2026-11-22 · 单版本正式安装与首次面板往返

macOS 27.0（26A428）、SIP 开启的实体机已直接升级至 5.22（90），原生源码 `bec6cb2`。最终唯一登记与运行的 App 为 `/Applications/Nearpane.app`，PID 32364，四项权限由该进程自读均为允许。历史普通窗口按当前几何原样归档，活动租约为零，配置摘要相同。 [最终运行回执](../verification/window-engine/single-version-26A428/15-final-regular-host.json)

正式 Host `9509bd0` 在普通桌面 4 上创建临时 Space 5643、自有面板迁入迁回、关闭面板并销毁临时 Space，16 条日志及系统读回通过。较早的系统桌面准备试验未能恢复原先通知窗口的前台。现版 `bec6cb2` 以稳定的普通前台窗核对 Mission Control。在其验收时段，实体机保持原生全屏，桌面条为 **BLOCKED**。第三方窗、Corner 停放和 Guardian 恢复均为 **NOT_RUN**。生产资格 **0/2**；整组、10/50 次及性能对照待验。 [实机分项与失败记录](../verification/window-engine/single-version-26A428/RESULTS.md) · [机器总表](../verification/window-engine/single-version-26A428/14-target-qualification.json)

## 2026-11-22 · 早期隔离候选的单窗口调度

5.22（90）源码 `4a84113` 已接入 Spaces 的面板操作日志、独立桌面清单和 Mission Control 可见桌面核对，以及 Corner 的逐显示器裁片、真实事件接收者和 Guardian 解除租约核对。26A428 实体机的本机源码回归、Host 与 Guardian 严格验签通过。日常 Host PID 59938 占用标准安装的单实例，隔离签名候选停在只读预检。两后端实机单窗口资格 **BLOCKED**，生产资格 **0/2**，整组及 10/50 次均为 **NOT_RUN**。 [结果、失败记录和签名](../verification/window-engine/single-window-witnesses/RESULTS.md)

## 早期隔离候选的正式 Host 单窗口资格

5.22（90）的生产后端资格仍为 **0/2**。目标机 26A428、SIP 开启。修正后的引擎连续两次读到相同的桌面清单及全屏记录。正式候选与日常 Host 使用同一个单实例标识，当前控制台的标准路径已有日常实例运行。Spaces 自有面板、签名第三方窗口和 Corner 的真实鼠标及 Guardian 验收均为 **BLOCKED**。整组和 10/50 次测试为 **NOT_RUN**。 [本轮结果和机器收据](../verification/window-engine/single-window-isolation/RESULTS.md)

## 2026-11-21 · 桌面文件和图标

「设置 → 本屏窗口 → 桌面文件和图标」现可选择平时隐藏、点击空白墙纸时显示，也可恢复为始终显示。托管 macOS 26（25G332）与 27（26A434）均通过真实文件和普通应用窗口验收，点回应用的 Dock 图标后文件再次隐藏。26A428 实体机离屏回归 745 项通过、3 项条件跳过，正式安装版交互为 **NOT_RUN**。26A434 的录像完成回调为 **UNKNOWN**，四个状态均有独立截图。 [实测截图、录像和原始收据](../verification/stage-groups/5.22-90/desktop-items/RESULTS.md)

## 2026-11-21 · StageGroup 产品工程与验收

本轮从 `e6d4bac` 推进到源码 `5e708a4`。macOS 27.0（26A428）、SIP 开启的主机完成开发包构建、解包验签及完整离屏回归，739 项通过、3 项条件跳过。正式安装 Host 的生产后端资格为 **0/2**。 [机器总表](../verification/window-engine/stage-product/verification.json) · [完整 Swift 回归](../verification/window-engine/stage-product/full-swift.xml) · [开发包签名与哈希](../verification/window-engine/stage-product/development-build.json)

九笔工程提交的 18 项原生 CI 均通过。最终引擎 CI 在 26A434 上通过 93 项 Rust、85 项 Swift 专项测试与生产 C ABI。构建脚本输出的开发 App 起初缺少外层资源封签，本次只对隔离副本做 ad-hoc 封签，解包后严格深度验签、辅助程序哈希与内嵌资源自检均通过。开发包沿用 `com.holdsnow.nearpane.host` 的 0.2.0（1）元数据。 [引擎 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/44912221403) · [原生协议和签名窗口夹具](https://github.com/haohongfei2001-png/nearpane/actions/runs/44912221364)

| 模块 | 已验证的行为 | 正式产品尚需验证 |
| --- | --- | --- |
| 窗口所有权 | 旧布局按窗口身份保留成员，含冲突成员的整个组作为旁窗。普通窗口写入者与引擎争用同一把逐窗锁，组目录与 Guardian 租约各自持久化。 [22 项隔离测试](../verification/window-engine/stage-product/ownership.xml) | 正式 Host 单窗资格。历史布局日志只约束日常安装的原位验收。 |
| 切换和组内布局 | 新窗默认单独成组。组合卡背景和组名可选择整组，保留上次精确选中的成员。先显示并验证目标焦点，再移开原组。编辑和分屏在原执行器归还窗口后进入同一队列。 [组切换与编辑](../verification/window-engine/stage-product/groups.xml) · [组合卡入口](../verification/window-engine/stage-product/group-action.xml) | 从正式侧栏执行 A→B→C→A 并独立确认各个工作集合和键盘接收者。 |
| 焦点与多屏 | 用户在写入之间或最后确认时选择了其他窗，事务停止。另一屏的前台窗须经两次清单和 Host 的 AX、CG、原生归属读回。另一显示器发现新窗时能独立更新目录。 [焦点与双屏隔离](../verification/window-engine/stage-product/focus.xml) | 当前执行器限一个已认证的显示器和桌面，同时持有两屏工作集合的写入路径尚待实现。 |
| 健康与交还 | 运行中失效的资格记录退出本次 Host 会话。侧栏收起后仍观察持有的窗。交还发生在旧执行器内，全部原始窗口和旁窗两次读回无差异后才确认完成。存在未确认写入或 Guardian 责任时保留原所有者。 [健康与备用后端](../verification/window-engine/stage-product/health.xml) · [焦点改变后的交还](../verification/window-engine/stage-product/interrupted-release.xml) | 真实 Guardian 接手、完整鼠标事件隔离、睡眠唤醒及拔插。 |
| 窗口生命周期 | 应用退出后核对进程代际和两次 WindowServer 缺席。托管 GUI 中，两个签名应用的目录重开后保留了双窗组和单窗组。退出并重新启动其中一个应用后出现新单窗组，另一个应用的两扇窗和原组保留。原 AX 对象确认恢复的窗口可沿用组成员身份，旧输入和像素标记自然失效。 [真实夹具](../verification/window-engine/stage-product/hosted-44912221364/stage-group-lifecycle.json) · [生命周期](../verification/window-engine/stage-product/lifecycle.xml) · [窗口重现](../verification/window-engine/stage-product/reappearing-window.xml) | 托管桌面的原生 Space 归属为 UNKNOWN，正式产品窗口调度仍需指定实体环境。 |

旧最小化对照在托管 macOS 26（25G332）增加了 Dock 窗口图块，旧角落停放原型收到了真实鼠标按下，两者均为 **FAIL**。显示桌面及恢复为 **PASS**。两项失败的鼠标和 Dock 读回、录屏及夹具清理结果均已保留。[最终源码的对照与录屏](../verification/window-engine/stage-product/hosted-44912221364/comparison/)

非活动组合目前仅有已核对的成员记录，完整组合画面仍待接入。实体机正式 Host 单窗闭环、整组切换、原生交互兼容及与 Apple 台前调度的性能对照分别保留待验状态。

首次双屏夹具重复了窗口层级且缺少屏幕可用区域，修正夹具后通过。全量测试另发现异步回调计数无法区分交还前已发出的读取，现以同一执行线程发出的请求序号验收，并在实际启动读取前复查观察需求、会话及取消状态。受限沙箱的 IOSurface 分配失败和离屏实测复核也独立留档。[首次双屏夹具](../verification/window-engine/stage-product/focus-first-attempt.xml) · [全量测试首次失败](../verification/window-engine/stage-product/full-swift-first-f0c2f11.xml) · [沙箱失败](../verification/window-engine/stage-product/sandbox-pixel-allocation.log) · [IOSurface 复测](../verification/window-engine/stage-product/iosurface-recheck.xml)

## 2026-11-21 · 同机原位安装预检

5.22（90）候选 `b7424a2` 已在私有目录完成 Developer ID 签名和静态验签。实体机 macOS 27.0（26A428）、SIP 开启。原位监督程序在正常退出日常 Host 前返回 **BLOCKED**。活动资料中有一扇普通窗口尚待恢复，进程代际和窗口号两次吻合，当前宽度 1230，记录的原始宽度 1211。原应用、资料和恢复日志均已完整备份，收尾核对原 PID、出生代、签名和资料指纹一致。[本次实机结论](../verification/window-engine/in-place-26A428/RESULTS.md) · [原位安装入口收据](../verification/window-engine/in-place-26A428/05-installation.json)

新版正式 Host 的权限和普通桌面身份仍待首次运行。Spaces 自有面板、第三方单窗往返、Corner 实际停放与 Guardian 恢复交接均为 **NOT_RUN**。生产资格 **0/2**。本轮为启动器加入标准路径、内核镜像、登录会话和单实例清单校验，为试验加入写前账本与回滚检查。[独立资格表](../verification/window-engine/in-place-26A428/verification.json)

## 2026-11-21 · 单窗口与权限主体

正式 Host 的 Corner 与 Spaces 单窗验收均为 **BLOCKED**，两个隐藏与还原动作均为 **NOT_RUN**。日常 5.22（90）仍为 `d2d0bb6`，已有辅助功能、事件投递和录屏授权，输入监听在这个版本上为 UNKNOWN。新版 `666e26f` 在私有目录完成产品签名和 ABI 核验，但后台精确启动请求返回了旧日常进程 PID 59938。[正式 Host 启动收据](../verification/window-engine/first-window-26A428/08-signed-product-scope.json)

同源码开发 Host 在实体 macOS 27.0（26A428）、SIP 开启的会话两读普通桌面 type 0 / ID 6。签名窗口 61357 的双向归属、原始 AX 对象及 AX/CG 几何均已实测，夹具已关闭。真实输入隔离、Guardian 崩溃恢复、Spaces 自有 canary 和第三方迁回仍待正式 Host 验证。生产资格 **0/2**，原语音冷启动首次超时仍为 UNKNOWN。[分项结果与历史失败](../verification/window-engine/first-window-26A428/RESULTS.md) · [机器总表](../verification/window-engine/first-window-26A428/verification.json)

## 2026-11-21 · StageGroup Window Engine

PR #15 已将 Corner 和 Spaces 编入同一个 Rust 静态库。R4 侧栏继续使用 Swift 的 StageGroupStore 和 StageGroupCoordinator。Swift 写入事务日志、绑定窗口代际并独立读回。每批窗口只有一个底层写入者。当前取得生产资格的后端数为 **0**。 [逐项状态](../verification/window-engine/RESULTS.md) · [实施合同](../research/NEARPANE-STAGE-MANAGER-CODEX-INTEGRATION-PLAN.md)

目标实体机为 macOS 27.0（26A428）、SIP 开启、一块物理屏幕。最初的两次只读检查均确认普通桌面及其 UUID。之后独立 Corner 探针两读的记录类型为 4，原焦点和自身授权也未满足动作条件。独立 Spaces 探针通过签名和进程身份校验，自身辅助功能授权读回为否。两项均在窗口写入前停止。托管 26A434 则两次缺少普通桌面 UUID。正式整组往返、同机 Apple 性能对照及压力测试均为 **NOT_RUN**。 [实体机证据](../verification/window-engine/target-26A428/) · [托管原始记录](../verification/window-engine/runs/44885716283/)

源码 `ddac854` 的同一签名开发 Host 在直接调用和独立后台启动时均读到辅助功能与输入事件允许，并拒绝两个未获资格的后端写入。日常 5.22（90）的 CDHash 前后一致。全量 Swift 复测 695 项通过、3 项跳过，首次并行构建期间发生的一次语音夹具超时已留档。云端原生协议和内嵌工具检查通过。 [机器可读总表](../verification/window-engine/verification.json) · [开发 Host 对照](../verification/window-engine/target-26A428/signed-development-host.json) · [语音失败与复测](../verification/window-engine/swift-test-events.txt)

## 2026-11-21 · 内嵌截图与语音

5.22（90）开发分支已接入 Riftlet 1.0.7（53）开发版和 Saytile 0.20（533）内测版。设置页从开发包的来源收据读取实际版本。macOS 27 本地全量回归共 669 项，666 项通过，3 项条件跳过。macOS 26 的 GitHub 工具专项和离线开发包构建通过。 [版本与更新流程](../../Dependencies/README.md) · [CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/44872015547)

Chrome、Edge 各完成 9 个无界面草稿场景，两边均记录到原文件的实际写入，错误目标写入和消息提交均为零。登录网站的 Apple Events 附加尚未实测。语音的 6 个冷启动样本通过首段 PCM、整段字节和独立进程重开核对。测试进程缺少默认中文识别模型，最终转写准确率为 **BLOCKED**。 [分项收据及失败记录](../verification/embedded-tools/5.22-90/verification.json)

云端复测发现资料迁移测试会阻塞主线程上的音频投递。在同一资料子进程等待五秒的对照中，同步等待触发三秒断流保护，异步等待时语音冷启动测试用时 0.376 秒并通过。 [云端失败日志](https://github.com/haohongfei2001-png/nearpane/actions/runs/44872934420)

## 2026-11-21 · 第三方窗口可见性复核

整组隐藏与恢复仍为 **BLOCKED**。在使用“最小化至应用程序图标”的 macOS 26.7.2 和 27.0.1 隔离会话，AX 路线保持 Dock 图块为 0，但恢复 A0 后实际按键从 A1 移到 A0。五种外部 SkyLight 排序均未实现逐窗隐藏与恢复。虚拟显示器改变了原生 Space，停放窗收到真实点击，并出现在 Apple Mission Control 中。精确构建 26A428、SIP 开启的日常 Mac 已完成只读预检。正式窗口提供器保持关闭。 [可行性裁决与计划](../research/NEARPANE-WINDOW-VISIBILITY-FINAL-FEASIBILITY.md) · [原始证据与截图](../verification/stage-groups/visibility-feasibility/README.md)

## 2026-11-21 · 三组真实窗口隔离

5.22（90）整组切换 **BLOCKED**。在原生台前调度关闭的托管 macOS 26.7.2 上，两种机制均完成 A→B→C→A。逐窗 AX 最小化通过四次准确键盘输入、几何恢复及旁窗检查，但 Dock 窗口图块从 1 增至 3。角落遮罩保持 Dock 数量，已停放窗仍收到真实鼠标按下并取得焦点。原组窗口与用户原最小化状态最终恢复。原生墙纸移开和恢复及生产监视器让渡在此夹具中通过。正式 Host 单次、10 次、50 次和两块物理屏维持未验。

已提交只读原生桌面分区、v1 保留迁移、组切换写前日志和分屏后新几何读回。当前日常 Mac 的 Dock 设置与托管机不同，已单独保留只读预检。生产侧栏维持已验证的选窗与同屏拖放，未启用失败的整组写入。 [完整阶段记录、录屏和候选](../verification/stage-groups/5.22-90/isolation/RESULTS.md)

签名候选 `565d311` 在干净的托管 Mac 完成标准路径安装，安装路径验签通过。因缺少 Apple 公证票据，安装路径的 Gatekeeper 评估未准入。首次启动为 BLOCKED，安装 Host 交互为 NOT_RUN。665 项本地测试通过。日常安装与配置保留。 [签名候选](../verification/stage-groups/5.22-90/isolation/signed-candidate.json) · [干净安装、清理和策略结果](../verification/native-spaces/5.22-p6/integrated-565d311/hosted-macos-26.json)

## 当前产品路线 · Stage Manager 替代

PR #15 的重定向基线为 `a1a3fc3`，版本 5.22（90）。逻辑组按真实显示器维护；原生 Space、手势、全屏和 Split View 归 Apple。新发布门槛以 SG0–SG6 为准。 [产品定义](../research/NEARPANE-STAGE-MANAGER-PRODUCT-DEFINITION.md) · [差异审查与架构](../research/NEARPANE-STAGE-GROUP-ARCHITECTURE.md) · [实施顺序](../research/NEARPANE-STAGE-GROUP-IMPLEMENTATION-PLAN.md) · [验收合同](ACCEPTANCE.md)

| 旧任务 | 归档状态与成果去向 |
| --- | --- |
| 旧 P0 原生切换、原生选择菜单 | OUT_OF_SCOPE，历史根因、一次/10/50 门槛和失败收据 ARCHIVED。 |
| 旧 P1 Bridged 跨 Space 迁窗 | OUT_OF_SCOPE，ABI 研究和非派发试验 ARCHIVED。 |
| 旧 P2 精确选窗 | 旧任务 ARCHIVED，正式 10/10 和同屏拖放作为新 P2 回归基线。 |
| 旧 P3 截图附件 / 旧 P4 语音、翻译、词本 | 旧任务 ARCHIVED，可复用的工程与真实缺项并入新 P5。 |
| 旧 P5 生命周期与性能 | 旧任务 ARCHIVED，本屏工作区、新 P4 被动系统兼容与新 P6 性能继续验证。 |
| 旧 P6 分发 | 旧任务 ARCHIVED，同包验签和回退证据复用，公证与干净首启进入新 P6。 |

### 前一轮 5.22（90）· 本屏 StageGroup 实施与验收

Host 和签名 helper 已双端拒绝历史原生写命令。生产侧栏从活动资料代读取每屏组目录，支持单窗入组、移出、解散和已确认分屏布局保存。签名候选 `267bd9f` 与测试修订 `a948bef` 的产品源码相同。 [本轮收据与失败项](../verification/stage-groups/5.22-90/RESULTS.md) · [机器结果](../verification/stage-groups/5.22-90/results.json)

- **已通过**。两个独立注册 App、三扇真实窗、同屏两个组。新读取进程恢复组和布局，旧绑定失效。隔离单窗退场与还原各一次，每步三方双读回，旁窗几何和可见性保持原值。659 项本地 Swift 测试通过。签名 ZIP 已放入现有 GitHub 草稿并独立下载核对。 [目录与单窗收据](../verification/stage-groups/5.22-90/hosted-retained-window.json) · [候选摘要](../verification/stage-groups/5.22-90/signed-candidate.json)
- **失败与未知**。首次还原前重新枚举未能确认身份，未提交还原。改用保留的原 AX 对象并核对所属 App 后还原成功，目标窗的 key 状态发生变化。托管端原生 Space ID 仍未知。同步目录解包时出现 FinderInfo 并导致严格验签失败，同一 ZIP 在普通本地目录通过。 [首次还原](../verification/stage-groups/5.22-90/hosted-original-enumeration.json) · [验签对照](../verification/stage-groups/5.22-90/archive-readback.json)
- **阻塞与未执行**。实体机当前只有内屏。正式 Host 重启及整组 A→B→A、输入标记、多屏重连、原生分屏互操作、性能对照与公证均未验收。下一步为正式 Host 写前日志、成员级补偿及隔离登录会话往返。 [实体预检](../verification/stage-groups/5.22-90/physical-preflight.json)

### 历史安装记录（ARCHIVED）

以下版本记录中的“当前”“发布门槛”均指当时的工作包。

## 2026-11-21 · Nearpane 自有的同桌面切窗过渡

5.22（90）签名候选 `78f630f` 已接入同一普通桌面的直接选窗。重叠部分的旧画面以 160 毫秒淡出，键盘焦点可以同步转交。实体 Mac 的隔离 GPU 测试按 60 Hz 取样 13 次，观察到 11 种不同颜色，过渡方向连续。云端注册夹具实测过渡层显示时只有目标编辑器收到字符，退场后键窗仍正确。正式安装版的屏幕录制、辅助功能和输入事件三项授权均已读回允许。实机当时缺少可保留的普通桌面原焦点，正式点击、逐帧录屏和键盘落点均未运行。日常版 `d2d0bb6` 和配置已恢复。两台系统验签通过，均缺公证票据。PR #15 保持 Draft。[逐项结果与原始收据](../verification/native-spaces/5.22-window-switch-motion/RESULTS.md) · [草稿候选](../verification/native-spaces/5.22-p6/integrated-78f630f/draft-asset.json)

## 2026-11-21 · 系统调度交接

5.22（90）签名候选 `35eecd2` 已在 macOS 27.0（26A428）验证台前调度开启时的快捷键交还。两次正式 Host 读回为零注册、零预览流，独立进程能实际取得并释放自定义组合键。修复安装脚本抢占前台后，原桌面和原窗口两次读回一致。本屏空间目录已接入正式菜单，当前构建保持只读。真实切换、迁窗、原生全屏 Split View、多屏与苹果同条件速度仍未通过。最后一次 P0 准入读到新的鼠标按下、抬起以及焦点变化，零投递，保留用户的新状态。日常安装仅登记一份，三项已有系统权限均已读回允许。PR #15 保持 Draft。[实机逐项结果](../verification/native-spaces/5.22-dispatch-replacement/RESULTS.md) · [同包分发门槛](../verification/native-spaces/5.22-p6/integrated-35eecd2/hosted-macos-26.json) · [发布验收合同](ACCEPTANCE.md)

## 2026-11-21 · 同屏拖放与切窗

**此前完成同屏实测的签名候选 `f7997a7`，5.22（90）。** 在 macOS 27 正式安装路径，同一普通桌面里，两扇窗口向左或向右拖放分屏、拖回自身和不同应用间右拖均通过。最终槽位各为 615 × 923 点，两个系统来源连续两次读回一致。普通启动下十次鼠标选窗均命中目标编辑器，也均取得目标首帧。相较旧版 `d81c458`，松开至焦点的中位区间由 320–335 ms 降至 105–124 ms，至真实首帧由 358–378 ms 降至 139–159 ms。放手后首次确认双窗布局仍需 1.64–1.86 秒。日常安装 `d2d0bb6`、配置及原有台前调度状态已经恢复，`b55ed96` 回退存档原样保留。台前调度开启时由系统管理窗口。macOS 27 跨 Space 动作继续关闭，全屏 Split View、多屏、系统同条件性能及公证仍待通过。PR #15 保持 Draft。[正式验收、截图与视频](../verification/native-spaces/5.22-90-sidebar-pair/RESULTS.md) · [跨应用读回](../verification/native-spaces/5.22-90-sidebar-pair/final-cross/result.json) · [签名候选](../verification/native-spaces/5.22-p6/integrated-f7997a7/draft-asset.json)

该候选通过 628 项 Swift 测试、317 项 Python 验收测试及托管 macOS 26 原生 CI。云端重新下载的 ZIP 与实机候选哈希一致，13 个代码对象、18 个切片签名通过。两台系统均确认缺少公证票据。[本轮机器摘要](../verification/native-spaces/5.22-90-sidebar-pair/final-acceptance.json) · [云端同包验签与 Gatekeeper 结果](../verification/native-spaces/5.22-p6/integrated-f7997a7/hosted-macos-26.json)

### 早期迭代

签名候选 `d277a1c` 已在同一普通桌面完成双向卡片拖放及跨应用分屏。两款不同签名应用各开一扇窗口，一次右拖就将 A、B 分别放到右、左两个 615 × 923 点的槽位。在同一台 macOS 27 上各点十次，旧签名包 `d81c458` 从松开鼠标到实际屏幕呈现的区间中位数为 358–378 ms，`d277a1c` 为 300–320 ms，两批均为 10/10 次准确键盘输入。单屏普通桌面验收使用关闭台前调度的隔离时段，日常应用、用户配置与台前调度已恢复。后续实验 `d1e0361` 的第一次选窗和反向分屏失败，故保留 `d277a1c` 作为已验证候选。[候选比较与全部失败项](../verification/native-spaces/5.22-90-sidebar-pair/RESULTS.md) · [实机分屏短片](../verification/native-spaces/5.22-90-sidebar-pair/final-pair/right-drag-fixture-windows.mp4) · [跨应用原件](../verification/native-spaces/5.22-90-sidebar-pair/separate-applications/result.json)

签名候选 `203e34e` 在正式安装路径使用独立资料。对两扇已登记文档窗，自投保持原位，拖至另一卡右半及左半均通过，两次系统 AX 与 WindowServer 读回一致。桌面工作区为 1230 × 923 点，两个槽位分别为 615 × 923 点。右拖录像保留两窗从重叠到分屏的实际合成器画面，共 46 帧。正式鼠标交替选窗 10/10 次键盘输入落在目标编辑器。首次显示时延的读屏器在启流前因全屏库存检查拒绝了 10 次，此批的画面时延为 UNKNOWN。日常 App 与配置均已还原。[拖放收据与录像](../verification/native-spaces/5.22-90-sidebar-pair/binding-drag) · [鼠标与输入收据](../verification/native-spaces/5.22-90-sidebar-pair/binding-focus) · [内部签名候选](../verification/native-spaces/5.22-p6/integrated-203e34e/draft-asset.json)

## 2026-11-21 · 此前候选 d81c458 的正式安装复核

PR #15 从原生 PR #14 的 `629524b` 继续，采用研究分支 `3151827` 三份决策及原生分支 `c1604f3` 的复核。可运行内部候选 `d81c458` 完成双窗正式验收，日常安装 `d2d0bb6` 及日常资料已原位恢复。`b55ed96` 原回退档通过 SHA-256 与双向签名核验。PR 保持 Draft。[候选与还原](../verification/native-spaces/5.22-p6/integrated-d81c458/protected-installation.json) · [回退](../verification/native-spaces/5.22-p6/integrated-d81c458/b55ed96-rollback.json)

| 阶段 | 实测与未通过项 |
|---|---|
| P0 | 第 18 轮的系统事件确认，外部 Apple Event 激活 Codex，随后 Dock 为该应用的窗口 42445 切到桌面 6。脚本上游未知。跨动作观察器两轮分别获得 171、136 个有效被动样本。专用签名 Host 以 nonce 从实际动作助手取回 `canSwitch=false, canMove=false`。借用已登记的相邻 5095/5094 时，第一次清点合格，约 418 ms 后第二次清点无法核对一个普通窗口条目。端点和条目身份保留 UNKNOWN，受控窗口 53833 在前后两次独立读回均归属 5095。布置快捷键和产品切换均为零。原桌面、焦点、Stage 和日常应用均恢复，两张既有测试桌面仍在。正式往返、10、50 均未执行。[隔离实机事件](../verification/native-spaces/5.22-p0/post-reassessment/isolated-97109f4/booked-adjacent.json) · [拒绝现场](../verification/native-spaces/5.22-p0/post-reassessment/isolated-97109f4/rejected-census.json) · [原始事件链](../verification/native-spaces/5.22-p0/post-reassessment/run18-system.json) · [被动观察](../verification/native-spaces/5.22-p0/post-reassessment/observer-isolated.json) |
| P1 | 已验证 Objective-C selector/IMP、真实方法签名、对象生命周期、窗口代际与迁移读回判据。实际投递迁窗 0 次。[非派发收据](../verification/native-spaces/5.22-p1-bridge/bridge-abi.json) |
| P2 | **当时的正式安装候选 `d81c458` 为 10/10**。此前候选 `0242247` 独立一轮也是 10/10。两轮均在同一注册签名应用的两扇窗口间交替。每次由生产侧栏发起，外部 AX、实际窗口号、AppKit 键窗和编辑器匹配，12 对按键只改动目标文件。第三按被拒的旧轮次保留。[十次动作和单窗实拍](../verification/native-spaces/5.22-90-active-display-previews/same-space-focus/registered-document-runs/09) · [此前失败](../verification/native-spaces/5.22-90-active-display-previews/same-space-focus/registered-document-runs/05-07.md) |
| P3 | 正式 Host 对已运行 Chrome 的非提示资格查询为 `notRequested`，没有已授权的隔离登录资料。真实草稿上传阻塞；读取标签、上传与发送均为零。[授权收据](../verification/native-spaces/5.22-p3/installed-946afb9/qualification.json) |
| P4 | 已证实真实 Services 回调与签名 Host 的入队和接收。系统在回调前 4.499 ms 为 Host 申请前台，来源窗口焦点保持失败。5 个独立像素样本核实了实际显示的系统语言包下载提示，本机英中翻译模型缺失。预置词条在两个独立签名 Host 的磁盘与设置页读回通过。三句中文各有干净与噪声样本，6/6 原始首尾音频完整。真实识别最终稿 0，60 次物理麦克风启动未测。[Services 系统时序及选区实拍](../verification/native-spaces/5.22-p4/installed-d81c458/README.md) · [词本](../verification/native-spaces/5.22-p4/installed-9ba33eb/seeded-wordbook.json) · [语音](../verification/native-spaces/5.22-p4/local-corpus/summary.json) |
| P5 | 37 项布局和生命周期用例、6 项性能数据核算用例通过。有一次实际全屏进出和隐藏一分钟后恢复。修复了旧预演的到期任务清除新预演的竞态，两项调度用例各复测 20 次。真实多屏、双窗 Split View、睡眠恢复及对标系统的完整性能仍待验。[P5 收据](../verification/native-spaces/5.22-p5/offline-qualification.json) · [竞态复现和修复](../verification/native-spaces/5.22-p5/lifecycle-scheduling.json) |
| P6 | 13 个代码对象、18 个架构切片分发签名通过。已为 Host 签入 Apple Events 和麦克风资源授权。在升级验证中，实际 Host 的辅助功能、录屏、事件投递三项均获准。GitHub Draft 候选下载哈希通过。实体 macOS 27 与托管 macOS 26 均因缺少公证票据拒绝放行，干净设备首启和 Sparkle 在线升级未验。[权限实测](../verification/native-spaces/5.22-p6/integrated-d81c458/host-permissions.json) · [候选](../verification/native-spaces/5.22-p6/integrated-d81c458/draft-asset.json) · [系统策略](../verification/native-spaces/5.22-p6/integrated-d81c458/system-policy.json) · [云端 macOS 26](../verification/native-spaces/5.22-p6/integrated-d81c458/hosted-macos-26.json) |

完整源码离线回归通过 592 项 Swift 测试及加载历史原件后的 269 项 Python 验收测试。分发签名和公证准备另有 9、10 项通过。[分阶段机器结果](../verification/native-spaces/5.22-p6/integrated-d81c458/acceptance.json)

## 既往安装记录

**此前 5.22（90）签名安装候选 `d2d0bb6`，PR #15 保持 Draft。** 两扇真实测试窗在四批正式 Host 实测中完成 48/48 次画面更新。5,708 帧合格侧栏采样都显示了对应色标。首次确认的呈现差为 P50 32.50 ms、P95 48.94 ms、最大 61.20 ms。30 帧完整双卡录像已逐像素验证。从同一侧栏帧读取五个独立应用的五张卡，六个状态下 30/30 项对应正确。三次 AppKit 所有者查询中断均在原有流上通过独立复核。当前安装版隐藏一分钟，7 次读回均为零条活动流，自动恢复后两张卡均继续交付画面。三项已有授权保留，系统仅登记正式安装。单屏桌面归属与台前调度交接已有实证，物理三指动画、双屏、双窗 Split View 和原生同条件延迟仍待验。P0 当前系统适配资格关闭，P1 迁窗 0 次，同应用受控编辑器两轮输入各 1/2，B 最后一批未读到可归属的 AppKit 按键。TextEdit 确认输入 0 个，公证待办。此前两张临时桌面尚未回收。[真实录像、机器收据和签名候选](../verification/native-spaces/5.22-90-active-display-previews/RESULTS.md)

**前一签名安装候选 5.22（90）`32b9f92`，PR #15 为 Draft。** 正式安装版三轮双文档画面更新共确认 36/36，各轮 P95 分别为 46.48、44.10、212.35 ms。第三轮有约 150 ms 的灰色画面，逐帧连续性仍未通过。未取得同条件的 Apple 基准。已有三项系统授权在更新后仍有效，原位安装与 ZIP 的 248 项逐一一致。已验证一次受控窗口真实全屏并正常返回。双窗 Split View、触控板动画与双物理显示器仍待实机证据。原桌面回收状态单列在本轮记录。[机器数据、原图和回退](../verification/native-spaces/5.22-90-active-display-previews/RESULTS.md)

**上一轮 5.22（90）签名安装候选 `f50d6ac`，PR #15 仍为 Draft。** 开启台前调度时，正式 Host 只显示 240 × 150 pt 的工具面板，窗口卡、活动流与新增帧均为 0。关闭后，在一块显示器上的两个受控普通桌面验证了有窗 A → 空 B → 原 A，卡片分别为 2 → 0 → 2。两张实际缩略图分别显示红、蓝测试文档。隐藏一分钟采集停止，恢复后读回两条流。三项权限在原安装路径上继承。与 Apple 原生缩略图同条件的延迟对照、调度中心动画期间的逐帧测量、两块物理显示器均待验。[本轮实拍、逐项结果和回退](../verification/native-spaces/5.22-90-active-display-previews/RESULTS.md)


**此前的 P0 回退候选，2026-11-20，5.22（90）。** 已用签名候选 `b55ed96` 原位换装。在 macOS 27.0（26A428）上，正式 Host 读回辅助功能、录屏与事件投递权限均为允许，跨桌面切换和迁窗能力均关闭，系统只登记一份 Nearpane。上一候选 `96a3e3d` 正式侧栏相邻往返 2/2 通过，一轮 10/10 的落点得到确认。新取证的单次切换 194 个显示呈现持续可见，但按压后约 2.38 秒前台离开目标进程，下一次按压前又发现活动桌面变化。原因未知，因此停止重复测试并撤销该构建的适配资格。两张临时桌面和窗口均已回收，日常配置恢复。该实验的原焦点未确认恢复。当前候选通过 539 项 Swift 测试，仍未公证。[实机证据、签名候选与回退](../verification/native-spaces/5.22-p0/RESULTS.md)

同一签名回退候选的双文档测试取得过 1 个正式侧栏 AXPress 回执，实际输入标记 0 个。修正验收器的 Apple 签名切片选择后，最后一次在会话条件变化时停止，期间探测到物理点击，保留了新焦点。所有临时桌面均已回收，日常配置读回一致。窗口区完整 0→2→0 与一分钟隐藏后自动恢复的实机证据来自此前 `96a3e3d`；当前包的独立空态截图因有其他窗口或输入中断而未通过。[输入与收尾](../verification/native-spaces/5.22-p0/quarantined-build-candidate/final-input-admission/admission-readback.json) · [已确认的窗口区实拍](../verification/native-spaces/5.22-p0/12-physical-probe/roster-serialized/results.json)

**此前的窗口区修复候选 5.22（90），源码 `365fdc4`，2026-11-20。** 工具下方只列已确认的应用窗口和显式组合。正式 Host 的同一窗口区实际经历 0→2→0 张卡，系统始终有 4 个 Space。空态前后实拍相同，桌面编号、全屏占位、空说明均为 0。完整空间、选窗和迁移专项仍未通过，PR #15 保持 Draft。[实机截图、逐点读回与签名候选](../verification/native-spaces/5.22-90-window-roster/RESULTS.md)

**此前的 5.22（90）合同复测，原生源码 `0777130`，2026-11-20。** 正式 Host 原位换装后继续持有辅助功能、屏幕录制和事件投递授权，系统选词服务仅由 `/Applications/Nearpane.app` 提供。三桌面合同为 0/50，另有 9 次正式行选择均未确认到达。双窗输入两次中一次符合预期；正式 Host 报告不可迁移。侧栏进入受控原生全屏、两句语音最终稿及隐藏后自动显示已实测。PR #15 保持 Draft。[完整验收、失败样本与候选](../verification/native-spaces/5.22-90-installed-contract/RESULTS.md)

**此前的权限迁移候选 5.22（91），2026-11-20。** 从 GitHub 下载后原位升级，系统只登记一份 Nearpane。Host 和七个权限助手与 90 双向验签通过。两条仅匹配旧构建的系统授权已清理，正式 Host 的辅助功能、录屏和事件投递仍未放行。侧栏 4 个 Space 与系统匹配，精确键盘聚焦、真实切换及迁移待验。[91 升级、权限与实机截图](../verification/native-spaces/5.22-91-permissions/RESULTS.md)

**历史安装版 5.22（90），2026-11-20，专项部分通过。** 正式侧栏与系统的 4 个 Space 及当前高亮一致。日常安装身份的辅助功能、事件投递、录屏均未获准，精确键盘聚焦、真实切换及迁窗仍待验。浅、深色下四处前景笔画已在同壁纸的两档玻璃设置间保持稳定。各项正式与隔离证据分别列出。[90 实机记录](../verification/native-spaces/5.22-90-r4/RESULTS.md) · [89 的首次校准、签名与失败项](../verification/native-spaces/5.22-89-r4/RESULTS.md)

**历史安装版 5.21（86），2026-11-19，专项 PARTIAL。** 在可取图的隔离视图中，有连续身份见证的一次台前调度往返保留了已标记的历史画面，返回后取得新内容。最终读取器另一次复测中，原身份短暂消失，卡片退为轮廓。正式安装版两项旧签名授权仍被系统拒绝；验收时系统观察器确认 6 扇普通窗口，正式侧栏 0 张，精确选窗 0 次。[86 实机与失败收据](../verification/native-spaces/5.21-86-window-recovery/RESULTS.md)

**历史安装版 5.21（85）** 的独立观察器确认本屏有 4 扇普通窗口，正式侧栏显示 0 张卡。系统明确拒绝将两项旧签名授权用于安装包。[85 结果与实拍](../verification/native-spaces/5.21-85-current-windows/RESULTS.md)

**历史安装版 5.21（82），2026-11-18。** 正式侧栏测得同屏 10 张卡片，纵向无重叠、无滚动。这项测量只验证排版。后续独立比对发现该版会显示已撤下的窗口。源码 `0558a2652b2d121cd99e57122f2988be9265212a`。[82 实机验收](../verification/native-spaces/5.21-82-window-access/RESULTS.md) · [80 历史结果与回退](../verification/native-spaces/5.21-80-current-screen/RESULTS.md)

在 build 86 的阶段范围内，桌面行导航和跨桌面拖放曾从正式侧栏撤出。已有独立窗口管理设置和历史工作包分别保留；打开逐窗列表不会发起布局事务。

## Build 78 及以前的历史验收

2026-11-18，专项 **PARTIAL**。当时的安装为 Nearpane 5.21（78），源码 `30831cf1e7faf1f22fdce32d3542e027fa918ffb`。78 已采用稳定开发者签名，并从实际运行的 Host 重新采样权限。以下 WP 表格沿用 77 的空间验收记录。其环境为 macOS 27.0（26A428），Apple Silicon，一块 1470 × 956 pt 显示器，独立 Spaces 关闭，台前调度开启，普通桌面 3 个，实际全屏 Space 1 个。[78 权限与安装收据](../verification/native-spaces/5.21-78-permissions/RESULTS.md) · [实现 PR #14](https://github.com/haohongfei2001-png/nearpane/pull/14) · [验收合同](ACCEPTANCE.md) · [原安装版基线](../verification/native-spaces/baseline-5.20-73/RESULTS.md)

| 工作包 | 实现及用户路径 | 安装版验证 |
| --- | --- | --- |
| WP1 空间切换 | 正式侧栏按显示器及真实 Space 身份导航。独立签封的动作进程核对权限、原始拓扑及每步意图，完成需窗口系统稳定回读。 | 普通桌面上四行逐项匹配，高亮一致。Host 报告可切换为 false，实际切换 0 次。 |
| WP2 空间地图与选窗 | 同一库存驱动空间地图和工具区下方的逐窗卡片。点击具体窗口时核对进程代际、原 AX 窗口、空间以及仍然有效的用户意图。选窗与取图分别判定权限。 | 一窗和同应用双窗各点击一次，均未取得精确键盘焦点，未输入标记。单窗夹具也产生了第二个离屏 CG 表面。 |
| WP3 迁窗及布局 | 拖放确认要求重查原 AX 窗口、同进程兄弟集合与 membership。迁移确认与目标分屏分开处理，未知回执暂停已管理窗口的写入。保留已授权的平铺、最小尺寸和双窗历史。创建能力缺失时保留分割或尺寸拒绝。 | 安装版可迁移为 false，跨 Space 迁窗 0 次。普通产品自动建删桌面尚未接通。完整占用证明缺失时保留来源桌面。 |
| WP4 系统组合与体验 | 后台采集有上限，允许保留已验证身份的历史图。独立的正常动效与减少动态效果路径，过期意图可中止。 | 一分钟隐藏采样零新增捕获，限于产品无录屏权限的状态。未取得可评价的切换录像、延时与稳态内存数据，缺第二块物理显示器。 |
| WP5 交付 | 统一安装位置、正常 Launch Services 启动，源码版本、Host/helper 身份和回退档均有收据。 | 构建、验签、解包回读通过。核心安装验收仍有未通过项；PR 保持草稿。 |

## 5.21（77）现场结论与本轮接续

当时正式安装进程的辅助功能、屏幕录制均未授权。负责取证的独立进程有自己的权限。只对本次创建的测试窗口投递正式侧栏点击，未将现有三个桌面认作专用 A/B/C。两次选窗后均验证了原桌面、前台、焦点及测试窗口清理。[最终安装版取证](../verification/native-spaces/5.21-77-final/RESULTS.md) · [完整矩阵、安装包与回退](../verification/native-spaces/5.21-77-delivery/RESULTS.md)

此前记录中的系统授权现已在正式 Host 读回为允许。复测从正式侧栏发起。先运行 `scripts/acceptance/native-spaces/run.sh preflight build/verification/ns12-next-preflight`（使用新的输出目录）核对实际 Host 的能力，再建立并清理可确认归属的临时桌面并执行受控输入。单屏场景可独立继续。M01 另需第二块物理显示器及对应的登录会话设置。[验收入口](../../scripts/acceptance/native-spaces/README.md)

5.20 的同一桌面跨应用双窗平分与恢复保留其原验证范围，最大几何误差为 0 pt。该结果没有纳入 5.21 跨桌面成功计数。[5.20 实机记录](../verification/P5.20-DESKTOP-OVERVIEW-AND-AUTO-TILING.md)
