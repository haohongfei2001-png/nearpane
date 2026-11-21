# 正式安装版工具验收

仅在受控窗口时段运行交互命令。使用正式安装的 `/Applications/Nearpane.app`、全新生产资料及其 writer.lock。验收命令从环境读取 `NEARPANE_TEST_HOME` 和 `NEARPANE_TEST_GENERATION`。每个收据目录必须是新目录。安装路径、唯一进程、资料锁或独立观察器权限不符时，命令将原因写入 `result.json`。

```sh
kit="$(mktemp -d /private/tmp/nearpane-tool-trial.XXXXXXXX)"
src=scripts/acceptance/native-spaces
bash "$src/build-tool-trials.sh" "$kit/bin"
"$kit/bin/tool-selection" service-route "$kit/translation-provider"
node "$src/tool-draft.mjs" preflight "$kit/guest-headless"
"$kit/bin/tool-selection" translate "$kit/translation"
"$kit/bin/tool-capture" capture "$kit/capture"
# 通过生产隔离入口退出、按原测试资料重启正式安装版，重新取得当次环境。
"$kit/bin/tool-selection" wordbook "$kit/wordbook" "$kit/translation/result.json"
# 将这一步与需要可见浏览器的验证合并到最后一个时段。
node "$src/tool-draft.mjs" draft "$kit/official-draft" "$kit/capture/result.json" "$kit/bin/tool-capture"
```

服务预检只读取系统提供者登记。翻译命令先确认当前仅正式安装版提供这项服务，然后在自身新建的 AppKit 编辑器中选中固定短语，通过 macOS「在 Nearpane 翻译选词」服务调用 Host。独立核对新面板与选区的间距、气泡文字、词义及隔离单词本。单词本验收要求同份隔离资料、新的 Host PID、相同条目 UUID、相同译文以及重新打开设置后可见的源文和译文。即使气泡观察失败，只要此次服务确实写入了预期词条，仍可单独验收持久化。Apple Translation 使用本机已安装的语言，系统的「通用 → 语言与地区 → 翻译语言」可下载所需的英语和简体中文。

截图命令从正式侧栏「区域截图」框选自身不透明双色窗口内的固定矩形。它检查整个区域的窗口覆盖关系、收录来源、尺寸、每个像素和摘要，匹配后才导出图片。草稿阶段可在同一候选及同一份测试资料重启后运行。

无头预检只读取全新游客访问 ChatGPT 首页的 HTTP 状态与编辑器是否可见。草稿命令启动一次新建资料的正式 Google Chrome，通过其独占调试管道观察真实页面。遇到站点验证、登录门槛或不可用编辑器会记录阻塞。若受控截图未成功，仍可将 `-` 作为截图收据参数记录正式页面现场。可用时，脚本通过正式 Nearpane 设置申请草稿附加权限，并且只在原空白编辑器仍然有效时单击一次托盘缩略图。此流程使用 Chrome 的「允许来自 Apple 事件的 JavaScript」和系统自动化授权。站点验证不会用现有登录会话完成。

草稿 PASS 需要首尾仍是原文档、可见唯一附件与此操作的文件名匹配、产品派送与上载收据各一份且身份一致、五秒稳定期没有提交或新用户消息。脚本拦截并记录提交动作，随后只关闭自己启动的 Chrome，清除该次浏览器资料。操作后的证据不完整保留 UNKNOWN，产品失败或触发提交保护保留 FAIL。
