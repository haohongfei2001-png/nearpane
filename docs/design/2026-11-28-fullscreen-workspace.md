# 全屏工具浮层：复用统一模块工作台

依据 `PRODUCT_CONSTITUTION.md` §7。实现仅扩展宿主的桌面呈现，不更改全屏观测、Spaces 调度或工作区恢复路线。

## 呈现

已通过既有全屏准入且用户开启精简入口时，状态条只提供「打开工具」。用户点击后展开同一个临时工具浮层：`EdgeSurfaceView` 使用 `.toolsOnly`，共享当前 `EmbeddedModules` 与模块排列，不另建领域实例，不因展开自动启动收音或播放器服务。Spaces 不进入浮层；歌词无有效会话时不占槽。语音、截图、歌词、备忘录、待办、时钟按共享布局及其状态呈现。

`FullscreenWorkspaceLayout` 与普通侧栏使用同一个 `LayoutComposer`。宽度来自统一侧栏配置，浮层高度随可见内容变化，最大适应屏幕的安全区域；内容超过视口时沿用共享滚动。浮层顶部保留拖动和收起控件，保存的位置仍为显示器内的相对锚点，并继续避开既有障碍几何。

## 输入与生命周期

原 `FullscreenPresentation.safe()`、有效观测时间、selection generation、visibility lease、会话边界撤下全部保留。浮层窗口分发输入前重新核验 `permitInteraction`，失效时撤下。普通按钮不使面板成为主窗口；真实鼠标点击可编辑原生文字控件后才允许面板取得键盘焦点。关闭、失效或更换呈现时撤回编辑焦点。

普通侧栏和全屏浮层分别报告展示可见性，再由宿主合并后下发给歌词与截图领域。歌词卡片使用每个 SwiftUI 挂载的独立 token，避免旧表面的延迟消失回调把新表面误标为未挂载。收起浮层只改变展示，不默认停止已经由用户启动的业务操作。

旧 `voice` / `capture` 全屏偏好仍保留解码与存档，但不再构成第二组模块开关。设置只保留精简入口开关、角落和浮层位置；所有模块是否参与统一由主模块页决定。

## 验证边界

新增源码测试覆盖启用顺序、共享宽度、去重、Spaces 排除、无会话歌词、短屏滚动、障碍拒绝、相对锚点以及歌词表面挂载转交。它们不构成真实全屏准入、焦点或多显示器验收。

新入口标识是 `np.fullscreen.open.workspace`，展开内容是 `np.fullscreen.workspace`。原生 `verify-native-fullscreen-overlay.py` 已识别统一入口，兼容实际观察到的旧入口，并检查共享的 `voice-capture-toggle`、`tray-content`。它只读取模块控件，不启动收音或截图；前台进程、窗口身份、观测有效期、业务状态不变与退出恢复断言全部保留。

早期 `verify-fullscreen-tools.py` / `verify-multidisplay.py` 使用的合成背景只有 300×100 个逻辑点，无法包容当前的完整浮层。它们保留历史候选入口，遇到统一工作台明确报告 BLOCKED；不能通过改名或宽度猜测把旧夹具变成新产品验收。新浮层的展开状态须根据真实 AX 入口／关闭控件识别。

### 可执行的原生验证入口

以下是验证入口说明，本次维护没有执行真实桌面操作。首先为包含当前源码的候选准备空的隔离资料并编译观察工具：

```sh
python3 scripts/acceptance/verify-native-fullscreen-overlay.py prepare --app /absolute/path/Nearpane.app
```

仅在既有独立见证协议已经提供有效的 `permitsFullscreenToolObservation` 授权、冻结清单及单窗口原生全屏 checkpoint 后，使用其实际标识启动观察：

```sh
python3 scripts/acceptance/verify-native-fullscreen-overlay.py observe \
  --app /absolute/path/Nearpane.app \
  --session PREPARED_SESSION_UUID \
  --run ENROLLED_WITNESS_RUN_UUID \
  --kit /absolute/path/frozen-witness-kit \
  --manifest-sha256 VERIFIED_MANIFEST_SHA256
```

脚本按签名包、清单、进程代次、实际全屏窗口、显示器与时间范围重新核验；没有这些条件时必须停止。必须取得新的完整 receipt 才能说明本候选完成全屏验证，现有主窗口截图或旧版本收据不能替代。
