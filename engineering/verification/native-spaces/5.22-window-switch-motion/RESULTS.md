# 同桌面切窗动效 · 5.22（90）

签名候选 `78f630f` 将当前普通桌面的选窗接入 Nearpane 自己的过渡。选择两扇重叠窗口时，用原窗口最近一次取到的画面盖住交叠区域，系统把真实目标置前后，旧画面在 160 毫秒内淡出。并排窗口使用目标窗口切换前的外观。按下卡片时开始准备画面，焦点操作直接执行。减少动态效果、已有系统调度界面、窗口身份改变或来不及取像时会跳过过渡。常驻侧栏仍沿用 R4。[生产选窗](../../../../Sources/NearpaneUI/DesktopSurface.swift) · [过渡实现](../../../../Sources/NearpaneUI/WindowSwitchTransition.swift)

| 项目 | 本轮结论 |
| --- | --- |
| 隔离 GPU 逐帧 | **PASS**。在实体 Mac 上用 Metal 读取生产渐变。两块测试色面以 60 Hz 取样 13 次，中心颜色单调过渡，交叠区域之外保持原色，样本中没有黑帧或旧画面回跳。160 毫秒是动画设定时长。[原始颜色](isolated-compositor.json) |
| 云端 macOS 的窗口层叠和输入 | **PASS**。将同一生产过渡层链接进临时 ad hoc 签名的 AppKit 夹具，经 Launch Services 普通启动。在真实 WindowServer 中，过渡层置前后原窗口保有键盘焦点；目标置前后，过渡层仍可见，测试进程通过 AppKit 投递的唯一字符只出现在目标编辑器；移除过渡层后目标仍为键窗和前窗。夹具缺少录屏授权，云端显示像素 **BLOCKED**。原命令行夹具未取得前台的记录也已保留。[注册 App 收据](hosted-windowserver.json) · [早期受阻收据](hosted-cli-windowserver.json) · [原生 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/44852061796) |
| 已签名安装版的屏幕录制、辅助功能及输入事件授权 | **PASS**。从标准安装路径及隔离资料启动候选。三项都由该代 Host 携带一次性请求标识读回允许。恢复日常版后再次读回三项允许，Launch Services 只登记了一个正式安装路径。[双方的签名、进程和授权收据](installed-macos-27.json) |
| 实体 macOS 27 的正式侧栏动效和打字落点 | **BLOCKED**。安装事务前和正式点击前均未能保留可恢复的普通桌面焦点。后续两次只读观测均为类型 4；改进后的只读探针再次确认当时处于非普通 Space。产品点击 0 次，正式动效样本 0，新版实际输入延迟、落点和录屏为 **NOT_RUN**。日常安装、配置和隔离资料清理通过，原窗口的持续焦点为 **UNKNOWN**。[现场读回及恢复](installed-macos-27.json) |
| 实际显示延迟与苹果同机对照 | **NOT_RUN**。既有 `f7997a7` 的 10/10 准确输入与 139–159 毫秒首帧中位区间属于该旧包。新包尚无可比较的正式输入与呈现配对样本。[旧包逐次记录](../5.22-90-sidebar-pair/RESULTS.md) |
| 签名、公证和回退 | 签名 ZIP 已进入私有草稿并独立下载核对。干净 macOS 26 验证了同一 SHA-256、13 个代码对象和 18 个切片。实体与云端 Mac 的 Gatekeeper 均拒绝未公证的候选。旧 `b55ed96` 存档的双向签名和解包回退通过。日常 App 恢复至 `d2d0bb6`，已清理本轮两个窗口夹具、只读探针、临时签名 App 和独立验收工作树。[草稿资产](../5.22-p6/integrated-78f630f/draft-asset.json) · [实体系统策略](../5.22-p6/integrated-78f630f/system-policy.json) · [云端验签](../5.22-p6/integrated-78f630f/hosted-macos-26.json) · [回退](../5.22-p6/integrated-78f630f/archived-rollback.json) · [清理](cleanup.json) |

正式验收使用带 `--window-switch` 编译的签名测试夹具，普通启动的 Host 执行选窗。独立观察器限定两个登记进程，从两扇文档窗口和真实过渡面板相交的 8 点方块读取 16 × 16 像素，同时检查实际窗口层级、进程代际与输入时间；只写入受控测试调色板可解释的画面。首轮动效缺少可归属的中间画面或出现反向跳变时，先记录键盘标记的实际去向，再结束该组。准入探针已细分桌面类型、辅助功能、系统焦点与原窗口，今后在日常版退出前就能记下具体阻塞原因。[独立像素判据](../../../../scripts/acceptance/native-spaces/pair-switch-pixels.swift) · [逐项合同](../../../native-spaces/ACCEPTANCE.md)

本地 Swift 套件收集 651 项，648 项执行通过，3 项工具专测因各自的环境条件跳过。367 项 Python 验收回归通过。验收器曾改变旧选窗调用的参数，修复后原用例通过；旧 CI 的失败也保留在收据中。[本地回归及历史失败](regression.json) · [候选源码 CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/44849060828)

macOS 27 跨 Space 切换仍关闭。P0 相邻往返、10 次与 50 次尚待正式安装版通过。跨桌面迁窗、原生 Split View、物理多屏和系统动效同条件对照仍保留各自门槛。软件和本轮验收改动可以分别回退，生产切窗动效对应提交 `78f630f`。PR #15 保持 Draft。[跨 Space 证据](../5.22-dispatch-replacement/RESULTS.md)
