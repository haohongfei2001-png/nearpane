# CI47 Music 两曲导入验收脚本失败

本目录是 build47（`01d21fc5ba61161f5cbf54ee494ed13778921910`）原件的逐字节归档，不修改失败状态，也不把同轮在线歌曲成功移作两曲控制通过。

## 已确认的边界

- Music 1.7 实际运行。脚本已经发出两次原创 WAV 的 add 命令，但在后续 12 秒内，旧 `file tracks of testPlaylist` 检查没有满足“两份不同、可读的 file track”条件，明确抛出 AppleScript 10001。
- `cloud-music.json` 为 `FAIL / test_harness_setup`，`realPlayerTestStarted=false`。普通 LyricTile 验收进程没有启动，不存在本轮 Music 的 24 项控制、首次使用或播放性能通过记录。
- 旧诊断只保存最终错误，没有每次实际 count/track class/逐条 metadata。因此不能确定旧集合是 0、1、其他数量，不能据此声称发生了丢失导入、重复条目或具体产品故障。
- 原始全桌面截图确有 Music 的“​Hear About New Music First”通知推广卡片，包含 Not Now/Continue。AX 原件记录 Start Listening 与 Automation Allow 两次普通操作，没有 Not Now 操作。CI46 使用相同 helper 且也未点击 Not Now，却完成两曲控制，故不能把此卡片认定为此次失败的已证明原因。没有点击 Continue、没有账号登录或 TCC 数据库修改。

## 本次针对性修复

验收脚本改为读取本轮实际 playlist 的 `tracks`。每次保存实际 count、class、title、persistent ID、duration、location、文件 hash 和读取错误；先等第一份输入文件可读，再只发出一次第二份 add 命令。每阶段保持 12 秒界限，不盲目重复导入。

实际文件 SHA256 分别对应两份原创输入，且 ID/location 唯一，才能确定两曲映射；不依赖 file tracks 子类型集合或条目顺序。随后在本轮 playlist 上按已确认 ID 选择首曲，等待真实 current ID/state/title/location 一致，才启动普通产品验收。实际文件 hash/时长与原有 24 项 next/previous、文档绑定和控制断言不放宽。

这是验收脚本修复，未改变生产代码。Python AST/编译与静态审查不等于实际 AppleScript/播放器通过；新的成功结果仍待下一轮 macOS 原件。
