# CI48 Music 两曲队列验收失败原件

本目录来自即时上传的 `LyricTile-music-48` 原始 JSON，逐字节保留。source 为 `89892d3605bcaa2a323422b2acd5aa64c626f65a`，生产 Sources 与前轮相同。

## 真实结果

此次顺序导入已成功，只有两次实际观察：首先 playlist count=1，随后 count=2；无条目读取错误。两份实际导入文件分别匹配原创输入 SHA256，位置与 persistent ID 不同；时长均为 240 秒。原曲A ID为 `53B88318126A508A`，原曲B ID为 `11A966C64B454CC7`。启动后真实 current ID、title、location、playing 状态符合A。

普通产品已启动并完成前17项：首次欢迎与真实 Get started、自动紧凑摘要、实际进度、LRC绑定、seek、CGEvent hover/暂停/移出、自动隐藏与恢复。随后第18项 `next-selects-second-track-with-new-generation` 失败。原生报告正确为 FAIL/appExitCode1，没有继续进行未满足前置条件的性能采样或后续切歌检查。

source18原件中 seek/pause/play 为 `readback_confirmed`；next目标确为 `com.apple.Music`，结果为 `dispatch_attempted_unconfirmed`，随后真实source仍为A。没有把命令发出等同于实际切歌。

## 有边界的定位与最小修复

这一轮 setup 使用了 `play (first track of testPlaylist whose persistent ID...)`。与CI46成功的 `play testPlaylist` 相比，单独播放track可能没有建立两曲播放队列，是与观测吻合的推断；CI48没有保存actual current playlist/queue字段，因此不能将该具体原因写成已被原件证明。

修复仅恢复 `play testPlaylist`，并完整保留顺序导入、两份文件SHA映射、12秒actual current ID/state/title/location确认及24项原生控制断言。另只读保存actual current playlist名称/ID作为诊断，属性不可用或3秒超时仅记录，不添加、替换或放宽验收门槛。未尝试其他播放路线，未修改产品代码。实际成功仍待后续macOS原件。
