# 5.22（90）调度组首批实测

签名候选源码为 `267bd9f94c02987663da2381183a1523bf306a94`。验收修订 `a948bef13e306701a2258cce9c2d8a1b2469b95b` 只修改单窗还原夹具，与候选的产品源码、资源和依赖相同。三个托管作业均在独立 macOS 26 会话运行。 [候选源码](https://github.com/haohongfei2001-png/nearpane/tree/267bd9f94c02987663da2381183a1523bf306a94) · [最后一次原生 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/44856813290)

| 结论 | 场景与证据 |
| --- | --- |
| PASS · 原生写入口退役 | 生产菜单和侧栏不再提供原生 Space 选择或跨桌面拖入。正式签名 helper 的符号表保留系统清单读取，未链接旧 Dock 手势、原生迁窗、事件投递入口。Host 和 helper 均对历史写命令返回拒绝，提交步数为零。 [签名二进制收据](production-boundary.json) |
| PASS · 单屏目录 | 两个经 Launch Services 注册并签名的普通 App 打开三扇真实窗口。WindowServer 独立核对所有者、真实窗号、托管显示器的 Core Graphics UUID 及几何。组合成员数为 2 和 1，双窗组跨应用。第二个读取进程读回相同组 ID、顺序、成员与布局，重新关联前没有有效绑定。两次读取均无活动组推断。只保存夹具数据，结束后窗口进程与临时资料已经清理。 [首轮](hosted-directory.json) · [最终读回](hosted-retained-window.json) |
| UNKNOWN · 首次还原 | 外部观察进程对一扇登记窗提交一次公开 AX 最小化。AX、所属 App 和 WindowServer 均确认退场，旁窗保持原位。原验收器的重新枚举条件未通过，没有发出还原请求。夹具随后退出。 [原始收据](hosted-original-enumeration.json) |
| PASS · 单窗退场与还原的资格试验 | 保留操作前取得的 AX 对象，核对进程代际、夹具登记标识、所属 App 的独立窗号回执及当前最小化状态后才提交还原。退场和还原各一次，每一步均有两轮 AX、AppKit 和 CG 读回。同应用兄弟窗与另一应用旁窗的可见性和几何保持原值。最小化时 AX 列表仍能查到同一对象，旧的整套枚举条件却返回失败。还原后目标窗的 AppKit key 状态与操作前不同，前台进程没有变化。该试验未投递键盘输入。 [资格试验](hosted-retained-window.json) |
| PASS · 工程回归与签名 | 本地全量 Swift 659 项，独立协议套件 26 项通过。早期 12 个测试问题以及真实几何已确认、读窗短暂中断却未能保存调度组的回归，均保留失败记录。候选通过 Developer ID 严格验签，13 个代码对象、18 个架构切片，GitHub 草稿附件重新下载的摘要一致。与日常安装版的 designated requirement 双向校验均通过。 [回归](regressions.json) · [签名候选](signed-candidate.json) |
| FAIL · 工作区同步目录解包 | 同一 ZIP 在 Documents 工作区解包后，App 根目录出现 FinderInfo 和 File Provider 扩展属性，严格验签拒绝。同一 ZIP 在普通本地临时目录与 Downloads 解包均通过严格验签，临时目录中的 Host 资源及 helper 运行时自检也通过。 [两个位置的实测](archive-readback.json) |
| UNKNOWN / BLOCKED / NOT_RUN | 托管机上三扇夹具窗均由应用报告在当前 Space，独立原生 Space ID 读回不可用。实体 macOS 27 的两次只读读数均为普通桌面，系统台前调度关闭，只有内屏，前台为日常应用。物理外屏断开/重连受设备阻塞。正式 Host 的编辑、重启及整组往返、唯一键盘输入、跨组布局恢复、公证与干净首启均未在此候选上验收。日常安装保留 `d2d0bb6`。 [实体机预检](physical-preflight.json) · [按合同分项](results.json) |

下一项工程是接入正式 Host 的逐窗事务日志。一次 A→B→A 要核对原组退场、目标组完整可见、非参与窗、焦点和唯一输入标记、原生归属及回滚。来源 App 不提供可靠窗口标识时须独立验证原窗活体。上一轮正式安装版同屏 10/10 精确输入和同屏拖放继续作为新包回归参照。 [现行验收合同](../../../native-spaces/ACCEPTANCE.md) · [历史正式侧栏证据](../../native-spaces/5.22-90-sidebar-pair/RESULTS.md)
