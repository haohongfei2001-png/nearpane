# P3 截图与 AI 草稿附件

本阶段从 PR #15 的原生基线 `90808bd` 开发。Riftlet 继续使用 `Dependencies/domains.lock.json` 中的 `189782dd943f5215da43539b30db27e482a78b3c`，源码树 SHA-256 为 `b45581cae27047a0e203222b2719ce9f37dc28c7476baa6205d6bd1a7e182f9a`。本次源码提交为 `bae75a7`，46 项 Swift 测试通过。阶段结果及逐意图记录见 [receipt.json](receipt.json)。开发中已定位并修复的失败见 [diagnostics.json](diagnostics.json)。

## 结果

| 项目 | 结果 | 本次观测 |
| --- | --- | --- |
| 托盘、捕获来源、回执和队列 | PASS，Swift 隔离测试 | Retina、旋转、负原点、同倍率跨屏、不同倍率、间隙、镜像、原图与入库文件哈希、超时、旧操作恢复均有专门断言。 |
| Chrome/Edge 的四站点能力探测 | PASS，合成页面 | 两个实际安装的浏览器分别运行 16 个页面。逐一检查登录控件、登录入口、空白编辑器、历史消息和矛盾信号。页面前后相同，独立监听器记录点击、输入、变更和提交均为零。 |
| Chrome 的 ChatGPT 附件交互 | PASS，限本地交互夹具 | 13 个场景实跑了 Swift 托盘、Riftlet 传输器及其固定页面程序。新草稿的延迟预览和已有草稿的即时预览都对应实际交给文件控件的同一张 2×2 PNG，取得上传开始回执。13 个场景均为零发送、零提交。 |
| 上传完成 | 未证实 | 本地页面只渲染预览，没有远端上传服务。两个预览均未取得完成回执。模拟队列的双回执策略单独测试。 |
| 正式 Host、真实服务、已登录新对话 | BLOCKED | 未提供已授权的隔离登录会话。实际浏览器与站点 12 格均未进行在线附件尝试。当前修订的 Apple Events 与 TCC 实机交互仍待验收。 |
| 实际窗口、屏幕旋转、多显示器截图 | NOT_RUN | 此阶段未读取真实桌面、打开实体窗或生成实机截图。几何断言使用明确标记的合成显示器。 |

产品夹具覆盖延迟预览、确认回复丢失后再次点击、选择器取消、无编辑器、双对话框、遮挡、焦点转移、换标签、换路由、页面重载、编辑器替换以及新进程重开。另一次完整关闭 Chrome、启动新进程后的测试，沿用原始队列与已花费的输入声明；生产进程出生校验须拒绝旧标签，独立页面须观测到零输入与零发送。晚到的确认只能更新同一操作。阶段 JSON 保存每案的收据与 DOM 监听器读数。夹具通过私有 DevTools 管道替代原生窗口寻址，使用新建资料和拒绝外网的本地代理。两个读取探测的启动命令和文件传输路径都不接收普通浏览器资料目录。

## 固定依赖与接口修订

- `InteractiveScreenshotController.start` 处理显式选择。公开的 `presentationSnapshot.requestID` 在倒计时及准备捕获时可读。`InteractiveScreenshotCapture` 回传 AppKit 选区、显示器编号、CGWindowID、PNG 和尺寸。`InteractiveScreenshotTarget.window.ownerPID` 属于 Riftlet 内部数据，控制器在采集前后重新验证目标。Nearpane 只能在返回时独立核对窗口、进程出生及范围。同尺寸窗口写为 `windowGeometryOnly`。要证明从按下到返回的完整窗口代际，应由 Riftlet 将已验证的冻结 PID 和出生标识一并暴露。窗口阴影的额外像素独立标记为 `windowMarginsUnknown`。
- 该 pin 的 `InteractiveScreenshotCommand` 通过系统 `screencapture` 取得原图，窗口模式按窗口 ID 捕获，区域模式用经过验证的整数选区。仓库已有的 `MacSystemCaptureProcess` 运行系统交互选择器。这条公开接口只返回退出状态和文件，来源与选区写为 `systemPickerUnknown`。未来需要 ScreenCaptureKit 后端时，最小变更位置是 Riftlet 的捕获后端和结果结构。
- `CaptureAttachmentProvider` 使用 Riftlet 的 `PrivateAssetImporter.importBuiltInScreenshot`、`QueueStore` 和既有 `TransferCoordinator`。Nearpane 将选区拆分到具体显示器，比对 AppKit/Quartz 坐标、方向、倍率、重叠、缺口和实际文件像素。完整单屏、明确裁剪、不同倍率和无法证明的窗口身份分别留痕。几何确定无效的文件在导入前停止；已成功导入的文件通过独立描述符读回、SHA-256 和 ImageIO 尺寸复核。
- 生产点击的本地账本位于 Riftlet 资料根目录的 `capture-attachment-evidence-v1/`。每次意图使用独立 UUID。文件以私有权限和独占硬链接发布，身份包括原图、资产、操作、原生浏览器进程、窗口、标签页和草稿。传输写入前持久化原始点击的绑定；重新打开只读取原操作。账本保留最初的未知、观察预算耗尽、上传开始、终态与清理状态。发送事件只能在实际拥有监听器的测试环境里计数。
- 新增站点探测只在显式选择的前台页执行，读取固定界面标志并返回布尔值。账户按钮与登录按钮冲突、加载中、编辑器模糊或缺证时保留未知。空白路由上的编辑器属于当前页面观察；“已新建对话”、文件交付、可见预览、上传完成和发送计数必须分别取证。页面探测本身不授予传输资格。

## 浏览器与服务

| 浏览器 | 只读目标寻址 | 四站点页面能力 | 当前固定 Riftlet 写入路径 |
| --- | --- | --- | --- |
| Chrome | 签名、PID/出生、选中窗口 ID、选中标签 ID，前后复核 | ChatGPT、Claude、Gemini、DeepSeek 均有只读探测，4×4 夹具通过 | ChatGPT 有写入路径，真实已登录服务待验收。其余三站在此 pin 未实现。 |
| Edge | 独立验证微软签名、PID/出生；其随包字典支持相同的固定窗口和标签寻址 | 同上，实际 Edge 无界面运行 16 个页面 | 四站在此 pin 均未实现。 |
| Safari | 苹果签名、PID/出生和当前窗口 ID；随包字典的标签对象仅声明索引 | 四站的 Safari 标签寻址及 WebKit 实机页均未验收 | 四站在此 pin 均未实现。应先证明跨换页、重排及重启仍可重验的原始标签身份，才可接通页面执行。 |

Chrome 与 Edge 的 `cwin/ID  `、`CrTb/ID  `、`acTa` 和 `CrSuExJa` 由各自安装包的 sdef 核对。Safari 提供 `bTab`、`pidx` 与 `sfridojs`。原生代码不会将可变化的索引当作稳定的标签 ID。所有原生 Apple Events 调用保留 PID 寻址并先检查既有授权。

追加写入器可以沿用同一个 `WebAttachmentAdapter`、`TransferCoordinator` 和文件传输程序。当前 upstream 的 `ChromeAppleEventsExecutor`、`ChromeProcessIdentity`、`TargetLease.sharesContinuationDraft`、`OrdinarySystemScreenshotScope` 的准入和 `chatgpt-web-20261027.js` 的 `route/captureTarget` 均限定 Chrome 或 ChatGPT。最小扩展是在 Riftlet 里对签名浏览器身份、稳定原生地址、草稿识别及站点观察配置做参数化，保留公用文件导入、唯一输入声明、队列、恢复与回执策略。每一组合都需要由同一个受支持的真实已登录会话证明文件接收、呈现和上传完成，再在相应策略中准入。额外浏览器和服务的来源清单或 DOM 读取成功均不足以准入写入。

## 复现

在该原生修订根目录运行以下命令。输出路径须是新文件；SwiftPM 依赖应已准备在该工作树内。

```sh
python3 scripts/acceptance/native-spaces/p3-capture.py --output build/verification/p3-capture-local.json
```

脚本不会创建第二份 App 安装包。每次从已安装的浏览器包读取能力字典，并在新建临时资料上运行拒绝联网的无界面夹具。成功关闭后复核私有资料已清除。新机器没有指定浏览器时，对应项保持未运行。源文件 SHA-256 和锁定依赖随收据输出，便于在集成修订中重新对照。

旧候选的 [Chrome 访客收据](../5.22-90-installed-contract/tools/official-headless-guest.json) 显示 HTTP 403，未检测到编辑器、没有附件尝试。该历史环境结果单独保留。
