# 其他播放器的本机条件

| 客户端 | 在 macOS 27.0 (26A428) 上的实际观察 | 支持结论 |
|---|---|---|
| Spotify 1.3.10.2586，Apple silicon | 从 Spotify 官方 CDN 下载 DMG，校验应用签名并启动。客户端显示登录 / 扫码页。Apple Events 可读到 stopped，播放一首公开曲目的请求后仍是 stopped，位置为空。 | 当前会话未取得播放、歌词或 transport 证据。 |
| 网易云音乐 | 本机没有安装该客户端。官方 Mac 下载接口重定向至 3.1.8.3330 DMG，CDN 返回 HTTP 403。另一个官方 CDN 上的 3.1.9.3364 DMG 也返回 403。 | 未运行网易播放器验证。 |

本次没有保存账号、登录二维码或 Spotify 用户曲库。Apple Music 和 QQ 音乐的真实播放结果分别记录。
