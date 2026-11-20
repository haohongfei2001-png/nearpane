# P3 隔离草稿写入资格验证

Nearpane 源码 `1e5b1d7` 给 Chrome、Edge 的四个新草稿入口接入了 Riftlet 已有的文件传输器。普通 5.22（90）沿用 `189782dd943f5215da43539b30db27e482a78b3c`；本页的额外入口只编入隔离验证可执行文件。原生 Host、真实登录会话、服务器上传完成均待实机取证。逐案的意图、来源、目标、命令、产品回执、独立 DOM 观察和清理结果见 [qualification.json](qualification.json)。

## 单一依赖与编译范围

Riftlet 后续公开修订含微软签名进程、进程出生、前台窗口/标签、文档点击见证及 Edge 执行环境检查。本次从该提交建立独立 upstream 分支 `codex/nearpane-p3-scoped-draft-qualification-20261120`，最终提交为 `5c6ca7fabc37fb50805603f6dc7df1ed39671d1e`。修改涉及七个文件。交付包含完整补丁、每文件前后 SHA-256 和 Git 全树 `df7f8a0bd2e4fa13aa9224d6c918b291f9766578`。重放从固定基础对象开始，校验补丁和全树后，使用其中的 `RiftletCore`、`RiftletAdapters` 及 SQLite 代码编译独立进程。该过程只需要公开的基础提交和本仓库内的补丁。[公开 upstream 基础提交](https://github.com/haohongfei2001-png/Riftlet/commit/c764246410c2c0c225ac4bb8688c2ae5179f27e9) · [来源锁](../../../../Dependencies/riftlet-draft-qualification/lock.json) · [精确源差异](../../../../Dependencies/riftlet-draft-qualification/scoped-drafts.patch)

- `DraftQualificationRoute` 绑定浏览器标识和具体站点的 HTTPS 新草稿地址。原生 `ChromeAppleEventsExecutor` 在固定进程、原窗口和原标签上调用既有页面程序。普通 ChatGPT 路由保留原有准入。Swift 针对八个组合验证了正常地址及错误来源、路径、凭据、查询和片段，另验证普通模式、无写入能力的 Safari 以及每个页面程序的点击绑定。
- Riftlet 在原有 `WebAttachmentAdapter` 和页面程序中加入四个站点的编辑器、账户、登录及既有消息标志。候选写入要求唯一可见的账户控件、空编辑器、当前编辑器所属的唯一上传控件。带有现成草稿、消息、对话框或歧义的页面会在传输前拒绝。提交文件前重新核对原始对象、来源和原生地址。四站共用原有附件投递、轮询和防重复声明。
- Nearpane 的 `DraftAttachmentQualification` 只由夹具包定义的编译条件启用。八个组合使用 `.syntheticDevelopment`。实际测试还将同一张夹具 PNG 标记为系统截图以检查来源拒绝，并以 `.ordinaryProduct` 逐案检查候选写入器关闭。普通构建继续使用发布依赖。三个相关套件共 36 个测试通过。[普通构建测试收据](qualification-ordinary-tests.json)

## 浏览器与实机边界

| 独立浏览器进程 | ChatGPT | Claude | Gemini | DeepSeek | 已登录在线附件 |
| --- | --- | --- | --- | --- | --- |
| Google Chrome 157.0.8103.79 | 12/12 夹具 | 12/12 夹具 | 12/12 夹具 | 12/12 夹具 | 4 格 BLOCKED |
| Microsoft Edge 157.0.4341.60 | 12/12 夹具 | 12/12 夹具 | 12/12 夹具 | 12/12 夹具 | 4 格 BLOCKED |
| Safari | 未启用写入 | 未启用写入 | 未启用写入 | 未启用写入 | 4 格 BLOCKED |

Chrome 与 Edge 分别在新建的无界面资料上运行。Swift 核实子进程代码签名和内核出生时间；测试管道提供显式标为合成的窗口号和标签号。网页通过本地截获返回，代理和 DNS 禁止外网。当前 Nearpane 签名 Host 对两个浏览器的真实 Apple Events、系统自动化权限和 Edge 执行环境均为 NOT_RUN。Safari 字典提供的可重排标签索引不足以在换页、重排和重启后证明原始标签身份。

每格分别执行即时预览、延迟预览、登录页、草稿以外的文件选择器、投递前换路由、替换文件控件、多个对话框、缺编辑器、已填草稿、已有消息、换标签和夹具取消上传。每次显式意图都有新建 UUID。监听器单独记录文件 setter、input、change、目标以外的 setter、发送按钮、表单提交和 Enter。

| 共 96 次尝试 | 结果 |
| --- | --- |
| 16 次即时或延迟显示 | 准确的 2×2 PNG、SHA-256 和可访问文件名均从实际渲染的本地附件独立读回。每次上传开始回执均对应原始资产、操作和草稿。 |
| 8 次取消夹具上传 | 每次仅一次文件 setter、input、change。页面没有附件预览，产品回执为 `inputTriggered`。上传完成未知。 |
| 72 次缺少资格或中途失去原目标 | 文件 setter、input、change 均为零。已进入传输但在写入前失去目标的尝试保留了操作 UUID 和拒绝结果。 |
| 96 次发送观察 | 发送按钮、表单 submit、Enter 和错误目标 setter 全为零。24 次已产生文件事件的操作各自拒绝了第二次输入。 |
| 清理 | 每个浏览器的临时资料独立复核已移除。验证脚本退出后回收整套编译、队列、媒体和夹具目录。 |

真实站点的动态 DOM、实际账户状态、服务端附件及无发送仍需已授权的隔离登录资料。在线 12 格均无投递尝试，发送数和远端完成保持未知。Safari 还需独立证明稳定标签身份。当前结果不可用于宣布安装版已验收、开启普通用户写入或放行发布。

## 复现

从原生工作树运行，`--upstream` 可指向含固定对象的任一 Riftlet 克隆；脚本只读取 Git 对象，全部写入发生在自己的临时目录。没有本地副本时可省略该参数，以便从公开仓库获取固定提交。输出必须使用新文件路径。

```sh
python3 scripts/acceptance/draft-qualification/verify.py \
  --upstream ../Riftlet --output build/verification/qualified-drafts.json

bash scripts/test.sh --filter 'CaptureAttachmentProviderTests|ProductDraftExecutorTests|TrayDomainTests'
```

首次本地重放的 Git 全树相符，但 Command Line Tools 缺少 XCTest，未执行浏览器动作。Swift 测试已同时支持完整 Xcode 的 XCTest 和 Command Line Tools 的 Swift Testing。本机保留首次失败和修复后的结果。[首次失败收据](qualification-first-failure.json)

## 已签名浏览器的冷重启

`9f9f646` 增加了 Chrome 和 Edge 各一次真实进程重启。每次使用两个全新的无界面浏览器资料。前驱打开本地截获的 ChatGPT 空白草稿，固定目标，将合成 PNG 和一次 `dispatchIntent` 持久化，随后由夹具向该进程发出 SIGTERM。后继在前驱进程组退出并回收资料后才启动。它以全新的驱动实例重新打开原队列及媒体。窗口号和标签号均刻意复用 1，各进程的代码签名、Launch Services 身份、内核出生时间和网页文档见证分别读回。两个进程的当前目标都必须通过真正的 Riftlet 页面校验，后继的同一校验必须拒绝原目标。

后继将原操作交给 `WebAttachmentAdapter.append` 和全新的 `ChromeAppleEventsExecutor`。原生桥在构建 Apple Event 之前对 `begin` 和 `discard` 返回 `originalRouteUnavailable`。队列恢复将该操作保留为 `unknown`，原意图、操作、调用、资产和尝试号可逐项对照。重复声明遭拒，原图仍可见，重启前后文件的 SHA-256 一致。两套独立页面观察者各自记录前后两次计数，包括本文件及其他文件控件的赋值、input、change、发送按钮、表单 submit 和 Enter。收据同时记录程序退出、私有资料移除和临时队列清理。[冷重启和既有 96 格回归汇总](cold-restart.json)

此前的独立原型只留下 Chrome 后继的读数。新夹具第一次执行时，前驱退出后残留的所属锁令两组清理失败。第二次 Chrome 通过，Edge 原进程退出后查询进程组返回 `EPERM`，后继没有运行。这两次原始结果连同各自源码摘要单独保留。[早期 Chrome 原型](receipt.json) · [两次清理失败](cold-restart-diagnostics.json)

以上证据覆盖真实浏览器进程、受控网页和冷启动原生拒绝路径。正式 Nearpane 前台 Apple Events、生产站点登录与远端投递均待独立实机验证。只运行这两例可使用以下命令，结果保存在一个新文件中。

```sh
python3 scripts/acceptance/draft-qualification/verify.py --cold-restart-only \
  --upstream ../Riftlet --output build/verification/qualified-draft-restarts.json
```
