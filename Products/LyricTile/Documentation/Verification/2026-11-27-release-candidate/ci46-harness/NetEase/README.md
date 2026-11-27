# CI46 网易云：官方下载累计时间边界

原始 `result.json` 来自 [CI46 run 46012637087](https://github.com/haohongfei2001-png/nearpane/actions/runs/46012637087)，源码 `2d93409308f3c37094af8aa44acea95e72d84f28`，完整 artifact `15206181489`。它按原字节保留；`SOURCE.json` 和 `SHA256SUMS` 给出来源及校验。

官方元数据返回的实际地址为：

`https://d1.music.126.net/dmusic/NeteaseCloudMusic_Music_official_3.1.14.3459_arm64.dmg`

本轮在 `download` 阶段返回 `TimeoutError: Official package download exceeded 90 seconds.`，状态 **BLOCKED**。没有进入挂载、客户端启动或原生播放器验证。部分下载字节数没有写入旧日志，临时文件随后已清理，无法补出一个准确数值。

同一官方地址在 CI45 实际下载 **180,434,687 bytes**，包 SHA256 为 `fb4c990c7c92451600945441c9a8ecd8b456427b33f93000f5fb21e6fc7d4df5`，并完成网易云 3.1.14 / build 3459 本地核心验证。派生的 `DOWNLOAD_REVIEW.json` 标明该参考报告的路径和 hash；这个历史成功没有改写本轮 BLOCKED。

代码路径可确认本轮触发的是下载循环的**累计 90 秒边界**，不是单次 socket 的 20 秒读超时。这支持为已知的大安装包放宽累计时间，但不能据此声称知道本轮具体收到多少字节或每秒速率。

下一轮只把网易云累计边界提高为 **150 秒**；QQ 仍为 90 秒。单次 socket 超时 20 秒、600 MiB 大小边界、官方 HTTPS 域名及重定向限制、DMG 完整性、应用签名和 Gatekeeper 检查均保持。没有新增重试或更换下载源。边界错误同时记录当时真实 `count`，便于以后区分部分传输与其他失败。
