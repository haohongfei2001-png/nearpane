# 随手记 / Notes：实现与原生验收

2026-11-28 · [PR #19](https://github.com/haohongfei2001-png/nearpane/pull/19)

**已实现并合入 main。** macOS 完整源码测试、App 构建、原生主窗口回归、随手记原生操作及六次独立进程验收通过。本轮没有发布正式版本，也没有替换用户本机安装。

## 版本与证据

| 项目 | 结果 |
| --- | --- |
| 开发基线 | `c74ea94520f55bc784f110176c59f5a38f1f1935`，开始时的最新 main |
| 受验功能分支提交 | `58b0e2eae6b501b59563f71ebbb77f18011e76ee` |
| Actions 实际检出提交 | `b63380ef0ed82db3f1f0b9f4cc59f5022ca60529`；PR 合并预览提交，与受验功能分支的产品源码一致 |
| 受验完整树 | `f3dc5b3659c9263264738a4a7d498fcbd0276627` |
| 完整源码测试 | PASS：1,014 项测试 / 163 个测试组，42.818 秒；见 [源码结果摘要](source-summary.json)。 |
| 完整 App 构建与包校验 | PASS：完整 Nearpane App 构建；50 项资源通过包校验；候选归档 SHA-256 见 [candidate.sha256](candidate.sha256)。 |
| 既有原生主窗口／模块回归 | PASS：53 项检查；原始 [主窗口回执](workbench/native-workbench-receipt.json) 与 [执行回执](workbench/runner-receipt.json)。 |
| 随手记原生操作与进程恢复 | PASS：53 项 UI 检查，六次独立进程全部通过；原始 [UI 回执](native/native-quick-notes-receipt.json) 与 [执行回执](runner-receipt.json)。 |
| 云端环境 | Version 26.7.2 (Build 25G332)；macOS 云端原生 AppKit / SwiftUI App。 |
| CI | [完整日志与构建产物](https://github.com/haohongfei2001-png/nearpane/actions/runs/46137542522) |

原始回执、进程结果与截图校验值随本报告保存。截图使用实际运行的打包 Nearpane App；示例文字、语音、截图与歌词内容来自隔离测试资料。Spaces 使用明确标记的窗口几何夹具，由生产窗口卡片绘制轮廓，不代表真实外部窗口捕获或调度。

## 最终设计与交互

正式名称为「随手记 / Notes」，与语音、截图、歌词、时钟的中文命名保持一致。设计与关键状态图见 [随手记规范](../../../design/QUICK-NOTES.md) 和 [状态设计稿](../../../design/quick-notes-states.svg)。后者是设计稿，不是原生运行截图。

侧栏以一行「记下一点想法…」开始，不显示模块标题、统计或空列表。点击后直接使用原生纯文本编辑器，多行文字自动保存。新建会保留上一条记录并开始下一条；空白误触不会制造多条空记录。

普通记录和待办共用连续容器。待办使用完成圆圈和正文，可直接编辑；两类内容同时存在时才显示分隔线。完成状态立即保存，约 850 ms 的短暂反馈后从日常列表撤下，仍可在仓库中取消完成。新建、转换和仓库操作使用轻量控件，空闲时后置显示。

模块沿用宿主的宽度、圆角和共享中性玻璃材质。正常记录区按内容请求高度，最大请求为 280 pt；空间不足时沿用既有布局收纳，内部滚动访问更多内容。窗口直接观察记录区需要的高度，避免旧视口压缩后的尺寸掩盖内容增长。未显示窗口的 AppKit 控件回归测试验证了增加待办时编辑器实例与光标保持不变，并验证完成待办后原窗口自动收缩。打包 App 的原生验收另确认记录与两项短待办的正文完全可见。

仓库复用 Nearpane 唯一主窗口，提供全部记录、普通记录、未完成、已完成四个视图，以及正文搜索、阅读、编辑、复制、删除与类型转换。侧栏入口定位当前记录；只有待办时定位可见待办，单项上下文入口定位对应身份。

## 验收矩阵

| 用户要求 | 验证方式与结果 |
| --- | --- |
| 新用户立即记录 | 新配置默认启用；真实按钮点击进入原生编辑器，输入多行正文。 |
| 连续创建、自动保存 | 原生新建和输入；重新实例化资料存储逐字段比较 ID、正文、类型、时间与当前记录。 |
| 记录与待办互相转换 | 两个方向均经原生操作；同一 ID、正文和创建时间保留，不新增重复记录。 |
| 完成、取消完成、历史 | 原生完成控件、已完成筛选、取消完成与全部记录筛选；校验完成时间的设置与清除。 |
| 正常退出与重新启动 | PASS：实际调用 `NSApp.terminate`，生产退出 delegate 提交清理，观察到 `willTerminate`，Host 已停止且磁盘记录不变；独立新进程逐字段恢复。见 [退出回执](process/normal-termination.json) 与 [重启回执](process/normal-restart/native-quick-notes-receipt.json)。 |
| 异常中断恢复 | PASS：原生编辑后向精确的测试 PID 发送 SIGKILL（退出码 −9），未执行关闭或主动刷新；独立新进程恢复相同身份、正文、类型、时间与当前记录。见 [中断前回执](process/crash-write/native-quick-notes-receipt.json) 与 [恢复回执](process/crash-readback/native-quick-notes-receipt.json)。 |
| 旧资料无损迁移 | 单份便签、两项旧待办、原任务 ID 和完成状态完整迁入；保留原文件字节、计算草稿与单词本；第二次进程启动不重复迁移。 |
| 停用后历史可访问 | 停用模块后在同一主窗口读取历史；资料与记录状态不变。 |
| 侧栏与仓库共用数据 | 原生仓库编辑立即更改同一当前记录；无副本同步过程。 |
| 多模块布局 | 实际完整侧栏截图包含语音、截图、歌词、随手记和生产 Spaces 轮廓卡片；共存态另以原生文本几何确认正文和两项短待办完全可见。 |
| 浅色、深色、不同宽度 | 原生 220、280、340 pt 侧栏与浅／深色截图；共享材质和真实布局。 |
| 其他模块回归 | 完整产品源码测试和既有原生主窗口／模块回归，结果见上表。 |
| 临时工具工作台 | PASS（有限范围）：生产临时工具面板共享同一笔记实例；08 图由可见 NSWindow 的原生 NSView `cacheDisplay` 取得，是原生界面渲染，不是 WindowServer 截屏；没有据此宣称真实全屏切换通过。 |

## 数据与迁移

复用 `SidebarNotebook` 和当前资料目录中的 `sidebar-notebook.json`，没有第二套记录存储。schema v2 的记录具有稳定 UUID、正文、`note` / `task` 类型、创建和修改时间、完成状态及完成时间；当前记录 ID 同时持久保存。普通记录保留其记录生命周期，待办保留完成生命周期，转换修改原身份的类型。

旧格式没有逐条创建、修改或完成时间。迁移使用原文件的修改时间作为基准，不将其解释为可追溯的真实历史时间。首次迁移保留 `sidebar-notebook.v1-backup.json` 的原始字节。

每次正文变更同步执行原子写入和文件同步，并维护最近提交的恢复副本。保存失败时，最新文字留在内存，界面提供重试；退出和资料切换在最后保存检查成功后才同步撤下编辑入口，再进入终止清理。损坏主文件保持只读；主文件缺失且存在恢复副本时，不会当作新资料建立空库。显式恢复前保留损坏原件。遇到更高版本 schema 时保持只读，不用旧副本降级覆盖。

模块注册保留旧 memo ID 作为统一入口。旧 memo / tasks 配置合并到原先最靠前的位置，启用与固定意图取并集，其他模块相对次序不变。两者均关闭时继续关闭。停用模块不删除资料，历史仍可经主窗口读取与编辑。

## 原生运行截图

以下 PNG 保留原始字节。用户要求的七种核心状态（01–07）全部由 WindowServer 截取；UI 回执共 13 张，其中 12 张为 WindowServer 截图，08 临时工作台为可见原生 NSView 的 `cacheDisplay` 回退渲染。每张图片的方法、窗口状态、尺寸与 SHA-256 均有原始记录，且已逐张重算哈希。08 不作为 WindowServer 或真实全屏切换证据。

| 状态 | 截图 |
| --- | --- |
| 空闲入口 | [01-idle.png](native/01-idle.png) |
| 正在书写 | [02-editing.png](native/02-editing.png) |
| 记录与待办共存 | [03-note-and-tasks.png](native/03-note-and-tasks.png) |
| 多待办，220 pt | [04-many-tasks-narrow.png](native/04-many-tasks-narrow.png) |
| 唯一主窗口记录仓库 | [05-library.png](native/05-library.png) |
| 五个模块共存 | [06-full-sidebar.png](native/06-full-sidebar.png) |
| 深色，340 pt | [07-dark.png](native/07-dark.png) |
| 临时工具工作台（可见 NSView 原生渲染，非 WindowServer） | [08-temporary-tools-workspace.png](native/08-temporary-tools-workspace.png) |
| 多待办，340 pt | [many-tasks-wide.png](native/many-tasks-wide.png) |
| 深色仓库 | [library-dark.png](native/library-dark.png) |
| 深色完整侧栏 | [full-sidebar-dark.png](native/full-sidebar-dark.png) |
| 模块停用后的仓库 | [library-module-disabled.png](native/library-module-disabled.png) |
| 完成反馈撤下后的列表 | [task-completed-feedback-settled.png](native/task-completed-feedback-settled.png) |

## 证据清单与校验

- [来源与版本记录](provenance.json)：受验提交、检出提交、main 合并提交、候选包与隔离测试执行文件摘要。
- [文件清单](manifest.json)：本目录证据文件的字节数、SHA-256 和原始 artifact 路径；叙述性 README 与清单本身不纳入自引用哈希。
- [截图校验](capture-validation.json)：对下载 artifact 中全部 50 张相关 PNG 逐张核对原回执哈希；其中 20 张随手记 UI／进程截图原字节保存于本目录，30 张既有主窗口截图保留在 CI artifact。
- [原始包校验](package-verification.log) 与 [候选归档摘要](candidate.sha256)：完整 App 候选为验收产物，未发布正式版本。
- [正常退出期望状态](process/expected.json) 和 [强制中断期望状态](process/crash-expected.json)：用于不同进程逐字段比较。
- [旧资料迁移回执](process/legacy-migration/native-quick-notes-receipt.json)：两次独立启动的进程结果同时保存在执行回执中；第二次启动后的 v2 文件字节一致。

53 项随手记 UI 检查包括 17 项原生无障碍按钮操作、5 项 AppKit 文本输入、1 项组合文字输入协议、1 项原生文本可见几何、20 项生产状态读回和 9 项明确标记的夹具设置。夹具设置不计作真实播放器或窗口调度验收。`crash-write` 原始子回执的状态为 `READY_FOR_SIGKILL`，最终通过结论来自执行器观察到 SIGKILL 退出及后续独立恢复进程通过，并未改写原始回执。

## 范围与未验证事项

- 当前主线实现左右边栏；本轮没有实现或声称验收上下边栏。
- 临时工作台使用生产面板及共享资料实例。本轮不把桌面上的面板展示等同于真实原生全屏切换、分屏或多显示器系统调度验收。
- 原生文字输入通过实际鼠标事件命中 `NSTextView` 后输入；组合文字通过 AppKit 文本输入协议测试，不等同于真实中文输入法候选窗和所有输入法的兼容性认证。
- Spaces 轮廓、歌词与其他示例内容是测试夹具。真实外部播放器、窗口捕获与 Spaces 调度仍属于各自专项验收，本次没有修改其底层引擎。
- 异常退出项覆盖进程 SIGKILL，不代表硬件断电、文件系统故障、所有 macOS 版本或所有硬件组合均已实测。
- 第一版本地资料，无 Apple Notes / Reminders 接入、云端同步、富文本、文件夹、标签、附件、复杂提醒、协作或 AI 整理。
- 本轮没有发布正式版本、修改官网或替换用户本机安装。

## 合并与源码等价

[PR #19](https://github.com/haohongfei2001-png/nearpane/pull/19) 已合入 main，合并提交为 `5870f5f18e243fdf9de0ee4725df12a763ff4808`。受验功能提交 `58b0e2eae6b501b59563f71ebbb77f18011e76ee`、Actions 检出提交 `b63380ef0ed82db3f1f0b9f4cc59f5022ca60529` 和 main 合并提交的完整 Git tree 均为 `f3dc5b3659c9263264738a4a7d498fcbd0276627`，已在本地 Git 对象中核对一致。当前证据目录为随后追加的文档与原始验收资料，不冒充受验构建源码的一部分。

随后 main 自动触发的 [运行 46138600813](https://github.com/haohongfei2001-png/nearpane/actions/runs/46138600813) 在本报告汇编时仍运行中；本报告通过结论基于已完成的运行 46137542522。

**外部部署状态单独记录：** Vercel 的失败 context 同时存在于开发基线、受验功能提交和 main 合并提交，均指向 [账户部署受限说明](https://vercel.com/knowledge/why-is-my-account-deployment-blocked)。本次没有网站改动，该既有外部部署状态不构成新增 macOS 回归；也不能因此把本报告解释为所有 GitHub 检查均已变绿。
