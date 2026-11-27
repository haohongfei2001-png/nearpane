# CI46 在线歌曲启动验收失败原件

本目录保留 build46（`2d93409308f3c37094af8aa44acea95e72d84f28`）的原始报告。所有原件逐字节复制，原失败结果不改写。

## 原始结果

在线脚本于 7.232 秒失败，阶段为 `real Music import and source readback`。Code Monkey 已正确导入：原 title/artist/album、189.309 秒时长、实际导入文件 SHA256 都符合公开原音频。其导入 persistent ID 为 `C3A19FF7EBA9843C`，但固定等待 1 秒后 Music 的 current persistent ID 仍为 `99ADDEEC86CD2C12`。

同一制品中的 `Music-source-03-production-adapter-real-local-track.json` 原件证明，后一 ID 对应前一项真实 Music 两曲验收使用的原创曲 `original-chimes`。因此此次硬门槛正确拒绝了错误的当前曲目；不能把导入成功等同于实际开始播放目标曲。

普通 LyricTile App 尚未启动，自动在线解析、缓存与原生 AX 观测均未开始；observations 为空，没有 automatic-cache-source.json。只读 AX helper 编译成功（exit0，stderr 空），运行步骤未进入。清理报告中临时音频/歌词删除、AppSupport 恢复、偏好恢复均为 true，errors 为空。

CI46 的旧报告只保存了不匹配的 current ID，没有保存当时 current title/state；不能推定它已处于播放状态。ID 对应关系来自独立保留的同轮前一 Music 原始源记录。

## 最小验收脚本修复

先读取并验证真实导入曲目的原标签、persistent ID、位置与文件 hash，再从本次实际 playlist 中按该 ID 明确取得并播放 testTrack；最多 12 秒持续读取真实 current title/artist/album/ID/state/position。只有目标 ID 和原标签匹配且 state 为 playing，才启动普通 App。

这替代了将 playlist 播放命令加固定 1 秒等待视为播放完成的假设。失败前仍保存安全实际读回，不更改 expected ID、不合成进度、不放宽在线来源或两句原生 hash 条件。不修改生产代码，成功复验仍待后续真实 macOS 运行。
