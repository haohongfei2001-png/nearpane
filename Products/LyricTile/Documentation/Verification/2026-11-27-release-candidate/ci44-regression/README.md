# CI44：网易云暂停数据回归与实际壁纸复核

本目录保存原始证据及单独标明的审查摘要。CI44 workflow 和原生检查的原始 PASS 标签保持不变；原始字段揭示的网易云暂停进度问题仍需要后续修复与复验。

| 来源 | 实际值 |
| --- | --- |
| 源码 | `e252115471001f5137396230bdd99a54ed72c348` |
| 包 | LyricTile 1.0.0 build 44，ad-hoc 工程候选 |
| 原生环境 | macOS 27.0.1 / build `26A434`，arm64 |
| Workflow | [run 46005463505](https://github.com/haohongfei2001-png/nearpane/actions/runs/46005463505) |
| 完整制品 | `LyricTile-candidate-44`，artifact `15200709032`，28,381,395 bytes |
| 完整 ZIP SHA256 | `6608d80afab80c53034dbf6f512f9aa6273d5020203e24f2cbb65ea505a29a31` |

`SOURCE.json` 逐项记录原始路径、字节数与 SHA256；原始 JSON 和 PNG 均直接从同一 ZIP 复制并与已解包文件逐字节核对。`SUMMARY.json` 和 `wallpaper/pixel-review.json` 是派生审查资料，`SHA256SUMS` 覆盖本目录交付文件。

## 网易云：暂停后重复暴露旧 seek 锚点

实际客户端是 **网易云音乐 3.1.14 / build 3459**，PID `29702`。它在未登录状态播放 `CloudAcceptance.json` 定义的原创 240 秒 WAV；歌词来自同一原创夹具的本地 LRC。

| 阶段 | 原始 `playing` / `playbackRate` | 原始 `elapsedTimeMicros` | App 的 `positionMS` |
| --- | --- | ---: | ---: |
| seek 到 64 秒，读回确认 | `true` / `1` | 64,000,000 | 64,253 |
| hover，暂停之前 | `true` / `1` | 64,000,000 | 64,756 |
| pause，读回确认 | `false` / `1` | 64,000,000 | 64,000 |
| 暂停后一秒 | `false` / `1` | 64,000,000 | 64,000 |
| play，读回确认 | `true` / `1` | 65,109,614 | 65,378 |

`source-05-seek-command-readback.json` 与 `source-11-pause-confirmed-and-interacted-panel-retained.json` 中，`timestampEpochMicros` 同为 `1795785979053286`，原始 elapsed 及 content identifier 也未随暂停改变。暂停命令确实成功，生产模型确实进入 paused，暂停 seek 能力也已关闭；但来源仍提供 `playbackRate=1` 与旧的 seek 时间锚点，适配器把这个陈旧锚点当成当前暂停进度。

`native-player.json` 的两个相邻观测显示 App 从 **64,756 ms 回到 64,000 ms**，可观测回退为 **756 ms**。这是模型进度读回之间的比较，未建立独立声学时间参考。录音 fingerprint、generation 1、本地文档 hash 和 192 pt 面板保持；问题没有表现为再次丢词。

旧断言只验证暂停后位置不再推进，因此 `paused-position-does-not-advance-or-invent-a-clock` 仍然 PASS，未检出暂停来源的时钟有效性问题。后续回归需要拒绝把这类矛盾暂停来源的旧播放锚点作为当前位置，同时保留录音、本地歌词与正常恢复播放。**本目录不把后续修复声明为已通过，也不将 CI44 固定为最终发行候选。**

## 壁纸：PASS，限浅色 App × 三种真实壁纸 × 1× 显示

`wallpaper/desktop-wallpaper-report.json` 和三张原始 PNG 来自同一实际 QQ 播放会话、同一个 LyricTile window **93**，面板为 **176×192 pt**，显示为 **1024×768、1×**。原创浅色、深色和棋盘格壁纸分别通过公共桌面 API 设置后，由 WindowServer 抓图；桌面和 QQ 可见状态均读回 `RESTORED`。本轮实际采用 `hide-readback`：`hideReturned=false`，随后真实 `hiddenAfter=true` 且 QQ 窗口从 on-screen 列表消失。AX 最小化 fallback 没有运行。

首次整图预览让 dark/busy 面板看起来缺少文字。重新打开原图、比对原始像素并放大内框后，root 与 release_ready 独立排除了这一预览误判：三张图的歌词都完整可见。

原始坐标 `(848,63)–(992,223)` 的 **144×160** 内框包含 352 种 RGB 颜色，三图 RGB 像素序列完全相同，SHA256 均为：

`37bc69a81f55ab22fade5aface73cf741eee72583df40dc874e2b344df3ab0f2`

放大裁片仅用于 QA，没有修改原截图，也没有作为正式宣传截图交付。`wallpaper/pixel-review.json` 记录原图 hash、内框坐标和独立像素 hash。原始图分别为 [light](wallpaper/desktop-wallpaper-light.png)、[dark](wallpaper/desktop-wallpaper-dark.png)、[busy](wallpaper/desktop-wallpaper-busy.png)。

这里通过的是 **浅色 App 在三种实际壁纸上的可读性**；深色 App 的原生夹具、其他显示比例和商业歌曲属于各自独立的证据范围。
