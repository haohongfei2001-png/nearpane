# TileKit v1：独立 Tile 协调与 Nearpane 承载协议

状态：设计定稿（待 macOS 27 实测），未在 macOS 27 实测。所有时长、尺寸均为设计值。
目标：同一用户内支持本协议的 HOLDSNOW App 有序共存；不增加 daemon，不控制普通应用窗口。

## 1. 范围与默认布局

- 三个小模块：TileGeometry（纯布局）、TileWindow（AppKit 壳）、TileCoordination（进程间登记）。
- 歌词、媒体、ASR、截图、更新、账户和网络不进入 TileKit。
- 独立列宽：`W = min(224, max(176, 4 * round(visibleWidth / 32)))`，单位为逻辑 pt。
- 右边距16，顶部16，间距10；完整词页面板高272，hover不改变外框与注册尺寸。无播放或手动62pt等待条期间仍保留272pt注册占位；等待条只占顶部可见区域，恢复播放不会挤动下方组件。
- 使用 NSScreen.visibleFrame；backingScale只影响像素对齐，不进入宽度公式。
- 窄屏放不下W或可用高度不足时不得越界；该 Tile 保持待放置，菜单栏提供选择显示器/独立位置。
- 已保存的用户orderKey优先；没有用户自定义时按Saytile→Riftlet→LyricTile的默认序插入，保持其他成员相对顺序；自定义列的新成员追加。播放/暂停/切歌/hover不改变顺序。
- 已固定的用户位置优先；拖动结束后才提交布局申请，不逐鼠标帧广播。
- Nearpane内嵌View服从宿主提供的宽高；不得为了本协议修改Nearpane现有默认宽度。
- 新Nearpane可把整块宿主侧栏注册为固定障碍；内部模块由宿主管理，不逐模块创建外部窗口。

## 2. 权威状态与锁

- 非沙盒独立分发路径：`~/Library/Application Support/HOLDSNOW/TileCoordination/v1/`。
- 文件：`registry.lock`（固定inode，永不rename）、`registry.json`（临时文件原子rename）。
- 同用户所有参与者对registry.lock使用排他flock；状态读取→校验→短计算→写入在一个事务内。
- 不能锁registry.json后rename它；旧文件锁与新文件不是同一把锁。
- registry必须是版本化小JSON，限制大小和成员数量；未知major只读，不猜测布局。
- 不新增常驻broker；每个参与者都可在持锁事务中推进状态，最后一个有效ack可提交计划。
- DistributedNotificationCenter只提示“可能有新generation”，可能丢失、重复、乱序；接收后必须读文件。
- NSWorkspace启动/终止、显示器变化、唤醒及低频租约检查补足丢通知。
- 锁使用LOCK_NB；MainActor取不到立即退出并择后重试，禁止在主线程阻塞等待。
- 持锁期间不得等待网络、子进程、异步任务、用户输入或另一把协议锁。
- 可以持锁执行短的无动画NSWindow定位/显隐调用；不得启动异步animator后提前释放锁并视为完成。
- 原子rename保证读者看到完整快照；持锁的generation检查保证不会把完整但过时的快照应用到UI。

## 3. 最小数据

```text
Registry {
  protocolMajor: 1, epoch: UUID, generation: UInt64, topologyRevision,
  phase: stable | withdrawing,
  committed: [InstanceID: Placement],
  proposal: Proposal?, members: [InstanceID: Member]
}
Member {
  bundleID, instanceID(UUID), pid, processStartIdentity,
  displayUUID, mode(docked | fixed | embedded),
  orderKey, minSize, idealSize, maxSize,
  ownedWindowIDs, lastHeartbeatContinuousTicks, status
}
Proposal {
  generation, topologyRevision, targetPlacements, withdrawingInstances,
  withdrawalReceipts, requestedAtContinuousTicks
}
Placement { displayUUID, frameLogicalPoints, visible, ownerInstanceID }
WithdrawalReceipt { epoch, generation, instanceID, windowIDs, observedHidden }
```

- epoch区分注册表重建；generation只在同epoch内比较；进程instanceID每次启动重建。
- PID必须同时核对进程启动身份，不能用PID单独判断旧参与者仍活着。
- placement只允许所有者移动自己的窗；登记不能携带脚本、任意命令、文件操作或AX动作。
- 不写歌词、转写、截图内容；未知字段忽略，关键身份字段缺失则拒绝该成员参与。

## 4. 为什么原子generation不足，以及真正的两阶段显隐

反例：A从上槽移动下槽，B从下槽移动上槽；若各自收到同一新generation便动画移动，两个窗会相撞。
规则：**先确认所有冲突旧占位已撤下，再允许任何新占位出现**；不同进程不必同帧移动。

1. 提案者持锁，按当前稳定占位计算完整的非重叠目标；写入phase=withdrawing和下一generation。
2. 目标与旧位置不同、将禁用/退出、或所有权要转移的参与者进入withdraw集合；不变成员继续显示。
3. 新启动成员初始必须隐藏，不能先按上次保存的frame亮出来再登记。
4. withdraw成员在MainActor尝试取锁，重新核对epoch/generation/instanceID，取消旧动画，orderOut全部已登记自有panel。
5. 放锁后经过AppKit事件循环，查询WindowServer的on-screen窗口列表；自有IDs不在列表才形成hide候选。
6. 再取锁，核对仍是同提案；写入receipt。只看NSWindow.isVisible=false不够，它可能仅反映进程内状态。
7. 只有全部所需receipt齐备，或对应进程确认死亡且旧windowIDs已从WindowServer屏上列表消失，才原子写stable新generation。
8. 每个新位置的拥有者在MainActor取锁，重读stable快照，校验其instanceID与frame；隐藏状态下setFrame，随后orderFront。
9. 所有新目标彼此不相交，且与不动成员/固定障碍不相交；因此第8步可任意顺序发生。
10. 呈现不得在放锁后的异步闭包中直接执行；异步回调必须重新取锁校验，否则旧plan可能穿插。
11. v1跨槽重排不做穿越动画；允许旧位置淡出、目标位置淡入，但淡出完成并确认隐藏后才能ack。
12. 待withdraw期间新变化排队；不得让第二个提案直接覆盖尚未完成的提案。
13. 超时不能当作已隐藏。活着但卡住的参与者保留占位，新的冲突位置不显示；不变成员仍可用。
14. 若要取消提案，撤下的成员也不能自行恢复旧位置；须经新的合法stable计划恢复。

此协议保证应用提交给WindowServer的可见集合先撤旧后加新；公共AppKit没有跨进程硬件合成帧栅栏。
macOS27实机须用屏幕录像验证视觉无交叠；不得把本机isVisible或JSON一致称为已经证明逐帧无重叠。
通常只有安装/退出/明确重排触发该事务；hover和切歌不会触发，也不会有频繁淡出。

## 5. 冷启动、租约与异常

- 启动先隐藏窗口，取得自身新instanceID，持锁登记；只有当前stable计划能授权显示。
- 已保存frame只是布局偏好，不是显示许可；进程不得持旧快照先显示再追赶。
- 心跳设计值5秒、失联提示15秒；使用同一boot的mach_continuous_time及timebase，禁止Date墙钟计算租期。
- **租约过期只标失联，绝不释放可见区域。** SIGSTOP/主线程卡死仍会留着窗口，TTL不能证明窗口消失。
- 进程被确认退出且旧启动身份不再存在，才能回收其窗口登记；PID复用不能延长旧实例的资格。
- 睡眠时不持续重排；唤醒先重新核对epoch/进程身份/屏幕拓扑/计划，再允许本App恢复显示。
- 墙钟/NTP变化不影响租期；系统重启后旧mach值不可比较，确认旧进程均不存活才新建epoch。
- 用户禁用Tile先withdraw，确认不可见，再删除成员；设置按钮不能先删登记再异步隐藏。
- 注册表损坏/major不兼容：保留最后已知稳定布局，停止新加入和重排；不得随便清空后放入重叠新窗。
- 若本实例没有可验证的旧布局，则保持隐藏并在菜单栏说明；独立位置模式仍可由用户选择。
- App退出前尝试withdraw；强制退出由操作系统进程死亡路径回收，不依赖退出通知必达。
- 日志只记录身份、世代、矩形与原因；异常不弹出持续打断的权限流程。

## 6. 显示器与Spaces

- 主键为稳定displayUUID；每次布局都从当前NSScreen重建逻辑坐标，不复用旧CGDisplayID。
- 若系统无法提供稳定UUID，使用本次会话临时ID，明确不承诺跨拔插恢复；不能制造伪稳定ID。
- 断屏先隐藏本App参与布局的panel，再优先申请主屏空闲槽；主屏不足时按稳定顺序选择其他有效屏，均不足则待放置；接回后不自动移动正在操作的面板。
- Dock/菜单栏/缩放/旋转变化都使拓扑版本变化；旧拓扑计划不能显示。
- 全屏策略属于成员显隐能力：暂时隐藏仍保留原槽，退出全屏回同一槽，不让下方组件上蹿。
- 全屏Spaces不另建第二份注册；一个instance的不同面板须完整登记，否则hide receipt不成立。
- NSPanel使用非激活模式；不为歌词显示启用屏幕录制、普通窗口AX搬移或全局快捷键。
- 公共系统切屏/拓扑动画不受本协议调度；实测覆盖“显示器具有单独空间”开/关及两屏不同缩放。

## 7. LyricSession所有权：单独一把生命周期锁

- 几何租约不能保证媒体服务唯一。增加`lyrictile-session.lock`固定inode，用排他flock由活跃owner终身持有。
- 所有者可为LyricTile独立App或Nearpane内嵌模块；先拿锁才启动播放器订阅和控制派发。
- 服务锁由明确对象持有FD；禁止fork/exec继承（close-on-exec），禁止未知子进程保留该锁。
- 同进程多模块也须经一个actor管理，不能各开FD重复自认owner。
- 控制入口校验ownerToken与session generation；UI排队命令不跨ownership epoch自动重放。
- TTL到期不能强夺仍被活进程持有的服务锁；卡住时提供恢复说明，不暗中开第二套控制。
- 独立→宿主：旧owner停止接受新控制→drain已派发命令与任务→withdraw独立面板并得到receipt→保存偏好→释放服务锁。
- 新owner拿到锁后读取真实播放器新快照、重建时间锚点；再登记/显示宿主内歌词View。
- 宿主→独立同理；Nearpane歌词View必须先隐藏、停止控制并释放，独立App才能接管。
- 固定取锁顺序为服务锁（长期）→registry锁（短事务）；绝不在registry临界区取得/等待服务锁，防止交叉等待。
- 未能确认旧命令完成的正常handoff保持pending，不自动重试toggle/next/seek。
- 崩溃时内核释放flock；新owner仍从真实快照开始。已送给外部播放器的旧AppleEvent可能晚到，锁不能撤销它。
- 因此承诺是“只有一个活跃owner派发新命令”，不虚构对播放器内部命令队列的跨进程事务保证。
- Nearpane只隐藏独立App、却未直接使用核心与View，不算完成原生承载。

## 8. 旧版兼容与发布门槛

- 自动协调保证仅覆盖v1参与者；现有旧Saytile/Riftlet/Nearpane不登记，不能声称能自动移动它们。
- LyricTile独立正式版不等待另三App迁移：可独立定位、拖动、保存显示器，并使用自己的播放/歌词能力。
- 检测到不支持协议的同品牌App时，尊重用户位置，保留独立模式；不得靠AX猜窗、强移动旧软件来冒充兼容。
- 对外首次宣传“三产品自动排列”时，再将各App最小接入更新与组合验收作为该项功能的发布条件。
- 必验：6种三App启动顺序、交换槽位、正在hover时新增成员、崩溃/SIGSTOP、旧plan回调、丢通知、同PID新实例。
- 必验：睡眠唤醒/墙钟跳变/破损registry/协议major不一致/断屏重连/不同缩放/全屏切换。
- 必验：handoff双方同时发起、旧owner失联、正在seek、Nearpane退出、独立App重启，确认没有双UI或双控制派发。
- 以真实窗口ID和屏幕录像检验两阶段显隐；纯几何测试只能证明目标矩形不相交，不能替代桌面验收。

