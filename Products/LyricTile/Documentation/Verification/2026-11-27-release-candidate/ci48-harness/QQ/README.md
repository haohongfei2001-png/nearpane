# CI48 QQ 暂停后恢复真实锚点的验收遗漏

本目录保留 build48 的原始 FAIL 报告与 source09/11/12/13/14/15，逐字节复制，不改写失败结论。QQ 版本为 11.11.1/build73285；媒体为原创本地 WAV/LRC。

## 原始序列

- source11/12：真实 raw `playing=false`、rate=1、elapsed=63秒、timestamp=`1795791681853306`；归一化和 UI 都为不可用进度，旧 playing anchor 没有被错误复用，文档与录音身份保留。
- source13：收到不同 content UUID、新 timestamp=`1795791682775547` 和 elapsed=64秒。`playbackRate` 字段缺省，**不是显式观测到 rate0**。raw 仍明确 paused，真实源 elapsed、normalized 与 UI 都为 64000ms，同 session/generation/document。
- 旧“暂停进度不推进”断言要求首次 nil 后仍为 nil，因此误拒了这个真实新源补锚。source14/15仍记录64000ms；这支持它没有自行向前推算，但旧脚本没有专门建立“补锚后完整1秒”的验收窗口。

现有原件没有显示旧rate1锚被复用，也没有证明新的独立声学精度。不能把初始未知位置永久保持nil当成正确行为。

## 新的严格门槛

仅修改显式CLI原生验收，不修改生产normalizer或普通播放逻辑。先在最多1秒内获取来源和UI一致的paused基线，避免跨越真实源更新的await读回竞态。首次1秒检查发生nil→数值时，必须证明新raw/normalized/UI位置吻合、timestamp与接收uptime确实推进、同播放器和进程、同已确认pause命令的session/generation，且歌词绑定身份保持。

这一来源恢复判定通过后，额外再观察完整1秒。必须继续paused、来自真实源且UI/归一化一致，保持原有300ms稳定阈值；不能只把nil→value放行。rate仍为正的旧锚、新来源不一致或身份改变均拒绝。

回归使用本轮source12/13原始JSON，另覆盖同timestamp、错PID、正rate、同receipt时间、错session/generation/process及不匹配UI值。回归输入只在Tests中，不注入生产播放。若下一轮现场未自然发生补锚，只能称真实输入回归验证，不能声称该分支现场通过。
