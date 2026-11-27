# CI45 Music：第二曲导入引用未可靠取得

本目录保留同一 CI45 制品内的原始 Music 设置脚本、错误日志和环境证据。**这一路径没有启动普通 LyricTile 的播放器验证。** 原 `cloud-music.json` 的 `BLOCKED / player_setup` 标签按原字节保留；本次审查把具体失败归为应当修复的测试 harness 错误。

| 来源 | 实际值 |
| --- | --- |
| 源码 | `59a4530302e592fc80040c955fffbba339aa3f89` |
| 包 | LyricTile 1.0.0 build 45 |
| Workflow | [run 46009188167](https://github.com/haohongfei2001-png/nearpane/actions/runs/46009188167)，整体 failure |
| 完整制品 | `LyricTile-candidate-45`，artifact `15203013021`，28,949,076 bytes |
| 完整 ZIP SHA256 | `7ff6a4cfef949773815ddc592f8fc1d1c187f817f6aa0518367d9accc6042b46` |
| 实际播放器 | 系统 Music 1.7 / build 1.7.0，macOS 27.0.1 arm64 / build 26A434 |

`SOURCE.json` 逐项记录原始来源路径、字节数及 SHA256；所有 7 个原始文件均从完整 ZIP 读取并与已解包文件逐字节核对。`SHA256SUMS` 覆盖本目录文件。

## 观测与判定

原始 `music-setup.log` 返回：

```text
964:975: execution error: The variable secondTrack is not defined. (-2753)
```

对原始 `music-setup.applescript` 的字符范围 `[964:975]` 提取，结果精确为 `secondTrack`，位于 `set secondTitle to name of secondTrack as string`。脚本先连续 `add` 两个原创 WAV，立即取得 `(tracks of testPlaylist)` 的第 1、2 项，随后 `play testPlaylist`，最后才读两曲名称、ID、时长和位置。

这证明第二曲远程引用在读取时没有可靠成立。现有证据尚不能独立区分导入可读性时序与播放上下文变化对引用求值的影响，因此不将其中一种机制写成已经证实的产品根因。

`music-after-launch.json` 显示 Music 确实已运行；`setup-permission-ui.json` 记录实际 `Start Listening` 和系统 Automation 的 `Allow`，两个 AX action 的结果均为 0。`realPlayerTestStarted` 为 false。不能据此声称 LyricTile 的歌词或控制失败，也不能把 `-2753` 当作依赖用户本机登录的环境限制。

## 对应修复及后续证据要求

后续 harness 显式读取临时播放列表的 `file tracks` 列表，初始化两曲变量，有界等待两个不同对象的真实名称、persistent ID、正时长和非空且不同的 location 全部可读。在播放前取得这些原始字段并物化路径，再播放该列表。原有两个导入文件的 SHA256、时长、当前 persistent ID、生产 next/previous 与本地歌词返回恢复检查继续保留。

未定义变量、语法、无效字段或自定义导入就绪错误分类为 **harness FAIL**；只有精确观察到的 Apple Event 权限拒绝、应用未运行或事件超时维持环境阻塞分类。读取循环设置 12 秒就绪期限和每次 Apple Event 的 2 秒超时，整个脚本另有 50 秒硬超时。

修复仍须下一轮 macOS 原生执行验证。本目录不修改历史结果，不生成第二曲成功、自动歌词成功或最终发行资格。
