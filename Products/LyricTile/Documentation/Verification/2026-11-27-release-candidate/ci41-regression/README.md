# CI41：真实播放器身份回归与未完成的验收

本目录保存 build 41 的原始证据子集，不把后续修复写成已经通过。

| 项目 | 实际值 |
| --- | --- |
| 源码 | `1c87964c399f445ad4fe6a394cdf680907e43306` |
| 候选 | LyricTile 1.0.0 build 41 |
| 原生环境 | GitHub Actions macOS 27.0.1，arm64，系统 build `26A434` |
| Workflow | [run 45994575431](https://github.com/haohongfei2001-png/nearpane/actions/runs/45994575431) |
| 完整产物 | `LyricTile-candidate-41`，artifact ID `15195339323` |
| 产物 ZIP SHA-256 | `ed6011a2d5ed279808b6a43ee430cd59a8981ec99c529894f88b2ea945d6c00b` |
| 音频与歌词 | `Tests/Fixtures/CloudAcceptance.json` 定义的原创 240 秒本地 WAV 与原创中英文 LRC；没有流媒体曲库或逐字精度认证 |

`SOURCE.json` 记录完整来源和本目录各证据文件的 SHA-256。JSON 与 PNG 均按原始字节复制。

## QQ：seek 后保留歌词的生产修复已被真实字段证实

官方 QQ 音乐 **11.11.1 / build 73285** 在未登录情况下播放原创本地音频。`qqMusic/source-04-local-import-expands-real-panel.json` 与 `source-05-seek-command-readback.json` 显示：

- 同一 PID `23133`，曲名始终是 `original-chimes`，歌手和专辑为空，时长始终为 `240000000` 微秒。
- seek 到 64 秒时，原始 `contentItemIdentifier` 从 `51836F1F-C4D1-42F6-BA10-E46E8A3A60A6` 变为 `3EBE543B-E960-4F64-A0E0-5907E7D2E477`；没有备用 `uniqueIdentifier`。
- build 41 的已知版本规范化没有把这个更新 UUID 当作录音 ID。规范化后的身份仍基于相同的真实元数据。
- `native-player.json` 记录 generation 始终为 1、session 和 recording fingerprint 保持不变，本地文档 hash 保持为 `de4a703952419e1806ff31ffc16bdd87253cc6de22bf56cb213f25dd42e975fd`，面板保持 192 pt，当前句索引从 3 变为 8。
- 生产控制器的 TransportTrace 为 `seek / 64000 / readback_confirmed`，不能仅凭界面进度接近目标判定控制成功。

因此，CI40 中 seek 导致本地歌词丢失的问题，在 QQ 当前已测 build 上获得了真实输入、真实生产代码和真实控制读回的闭环证据。它不等于本轮所有 QQ 验收均通过。

## 鼠标尝试：进入事件没有发出，暂停未实际执行

`qqMusic/native-pointer.json` 显示原生辅助工具已编译并运行，已有 Accessibility 和事件发送权限均为 true，未申请新的权限。工具要求目标点对应实际可见的 LyricTile 窗口，并且没有其他窗口遮挡。

本轮 `enter` 请求被窗口前后顺序检查拒绝，原始原因是 `Another visible window covers the intended input point.`，`eventsPosted` 为空。工具没有记录阻挡窗口的完整身份，因此这份证据不足以确定究竟是真实遮挡，还是测试工具对窗口命中关系的判断不完整。随后没有进入 Hover，暂停按钮不可用，`pause` 请求也没有发出任何事件。只有最后的 `leave` 发出了 `mouseMoved`。

QQ 的本轮状态为 **FAIL**。该鼠标尝试没有真正触发暂停，所以后续暂停、隐藏和恢复断言不能用来证明播放器控制故障，也不能用来验证或否定 build 73285 的暂停时钟行为。这是待继续定位的具体测试阻塞，不能据此宣布云端输入验收永久不可行。

## 网易云：真实播放可行，seek 后的身份缺陷已被原始字段证明

官方网易云音乐 **3.1.14 / build 3459** 本轮在未登录情况下实际播放了原创本地 WAV，生产适配器取得了真实曲名、240 秒时长、推进的位置，以及明确的播放、暂停和 seek 能力。

`netease/source-04-local-import-expands-real-panel.json` 与 `source-05-seek-command-readback.json` 显示：

- seek 前后 PID 均为 `26962`；曲名、空歌手、空专辑和 `240000000` 微秒时长完全一致。
- seek 64 秒后，原始 `contentItemIdentifier` 从 `F41D3D77-D7CC-45FC-AB78-DDE0A92C7858` 变为 `76D7DB78-96A0-49DC-A290-011701E47F27`；没有备用 `uniqueIdentifier`。
- build 41 尚未对这个网易云 build 规范化该 UUID。生产模型因此把 generation 从 1 改成 2，recording fingerprint 随 UUID 改变，本地歌词文档和当前句被清空，面板从 192 pt 收缩为 104 pt。
- 源进度已到约 65.43 秒，但生产 TransportTrace 为 `dispatch_attempted_unconfirmed`。这次 seek 不能标记为控制验收通过。

下面两张图来自同一实际生产应用的原生视图捕获。第一张在本地 LRC 导入后显示歌词；第二张在 seek 后显示 `No lyrics`。文件未裁剪或修改。它们证明本次歌词状态变化；这种视图捕获本身不证明完整 WindowServer 壁纸合成或真实鼠标命中。

![网易云实际本地歌词导入后](netease/real-netease-lyrics.png)

![网易云 seek 后实际丢失歌词](netease/real-netease-hover.png)

NetEase 的本轮状态为 **FAIL**。这是已定位的录音身份规范化缺陷，不能用缺少账号或播放器不支持本地播放来解释。

## Music：测试脚本的改名操作失败，普通应用尚未开始

`Music/cloud-music.json` 记录 Music 1.7 已实际运行，但导入后的 AppleScript 返回 `Parameter error. (-50)`，错误范围为 `373:433`。按本轮实际 runner 路径和源码恢复脚本文本，该范围完整对应：

```applescript
set name of testTrack to "LyricTile Cloud Original 20261127"
```

完整产物中的 `real-music/setup-ui/native-permission-ui.json` 另记录了 Music 的 `Start Listening` 和系统 Automation 提示的 `Allow` 都已通过实际 AX 按钮执行成功。本轮失败点是测试脚本对导入 WAV 曲目进行可选元数据改名；它不是登录障碍，也不应直接转交用户本机。应让测试使用真实导入曲目的可读名称继续播放验证。

当前 JSON 保留原始 **BLOCKED / player_setup** 标签以保证证据不被重写；上述错误位置审查把原因进一步收窄为可修复的测试脚本设置问题。`realPlayerTestStarted` 为 false，不能声称 LyricTile 对 Music 的首次使用或播放控制已通过。

## 性能与壁纸边界

本轮普通应用没有通过全部核心检查，因而没有发出性能/壁纸阶段所需的 ready 标记。QQ、网易云的逐行歌词性能采样及实际壁纸合成验收均未运行。准备好的原创壁纸文件不构成实际壁纸验收证据。

后续候选需要保留真实的录音身份、控制读回、非空歌词和界面尺寸断言，修复上述具体问题后重新运行；不能用前一轮紧凑态性能或辅助窗口 smoke 的 PASS 替代这些结果。
