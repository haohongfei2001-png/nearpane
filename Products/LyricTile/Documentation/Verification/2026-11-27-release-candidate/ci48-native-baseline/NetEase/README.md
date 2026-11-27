# CI48 网易云：真实本地核心与逐行短采样

此小型基线来自 [CI48 run 46019565695](https://github.com/haohongfei2001-png/nearpane/actions/runs/46019565695)，源码 `89892d3605bcaa2a323422b2acd5aa64c626f65a`、artifact `15207798927`。原报告与完整 ZIP 内成员逐字节一致，未重写 PASS/BLOCKED 或进度字段；`SOURCE.json` 给出逐文件来源和 hash，`SHA256SUMS` 覆盖本目录文件。

**本目录只确认网易云局部路径。CI48 的 Music/QQ 有其他未通过项，不据此认定整个候选或正式发行通过。** 本目录没有重新执行测试，也不包含播放器、音频、歌词文件、PNG 或完整原始日志。

## 实际播放范围

网易云音乐 **3.1.14 / build 3459 / arm64** 从官方 DMG 安装，180,434,687 bytes、SHA256 `fb4c990c7c92451600945441c9a8ecd8b456427b33f93000f5fb21e6fc7d4df5`；原报告记录 DMG 完整性、实际 bundle ID、签名和 Gatekeeper 通过。

首次观察没有匹配音轨；按已有脚本仅通过正常 `open -a` 重开同一原创 WAV 一次，未登录、未操作协议或 UI。第二段观察得到 23 个匹配的真实 playing 样本、4 个源锚点，位置从 880 到 20,310ms，且真实 Play/Pause/Seek 能力齐备。随后普通 LyricTile App 的 **18 项核心检查通过**：识别、104pt 紧凑摘要、本地歌词导入后 192pt 面板、seek 读回、身份和绑定保持、原生 hover/暂停/移出、自动收起与恢复、静默后继续切句。

`native-pointer.json` 保存实际 CGEvent 事件、目标 PID/窗口及原生命中记录；`native-player.json` 和原始源报告保存真实命令读回。它们不是实体鼠标硬件、商业曲库、网易播放队列切歌或独立逐字/声学时钟资格。

## 暂停旧锚点的真实回归

- seek 原始源为 `playing=true`、`playbackRate=1`、`elapsedTimeMicros=64000000`，时间戳 `1795791769921626`，item ID `0A71DDBD-B49D-4BDA-9E32-809842045737`。
- 暂停后的三个原始观察仍携带同一 64s、同一 timestamp/item ID 和 `playbackRate=1`，但真实 `playing=false`。生产适配器正确保留 `state=paused`、`quality=unavailable`，不输出 `positionMS`；普通 App 也记录位置为空，未回跳到旧 seek 值或制造暂停时钟。
- 恢复后源变为 `playing=true`，新时间戳 `1795791772585257`、新 item ID `DDC4794B-0263-430F-BFBE-200DF8080131`、`elapsedTimeMicros=65109614`；适配器观测 65,269ms，普通 App 随后观测 65,390ms，歌词自动显示。`seek`、`pause`、`play` 均有面向实际网易源的 `readback_confirmed` trace。
- 同一歌曲 selection generation 保持 1，导入后 document hash 始终为 `de4a703952419e1806ff31ffc16bdd87253cc6de22bf56cb213f25dd42e975fd`。原始系统 item ID 的恢复变化没有被误当成新歌曲而丢弃绑定。

## 静默切句与资源

`native-line-progress.json` 记录 cue **8→20**，生产源时钟值 **166,249ms** 落在当前句 **160,000–168,000ms** 区间。对应原始 adapter 快照仍为真实网易 playing 源，位置 164,416ms；这是更早的快照，生产时钟随后正常投影并发表当前句。该核对没有独立声学参考。

`performance-summary.json` 为 **60.449599s、53 次采样**：单核平均 CPU **1.918975%**、P95 **5.346441%**，RSS 中位 **95.703125MiB**、峰值 **101.75MiB**。这是进程树的短时逐行实测，平均 CPU 高于 1% 参考目标，没有改写为预算通过、逐字性能或新的八小时长稳。原报告保留 CPU 时间有限分辨率及短进程可能漏计的测量限制。

播放器清理没有残留 PID，DMG 已卸载；网易路径没有执行壁纸变更。
