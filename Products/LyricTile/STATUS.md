# LyricTile · 当前状态

2026-11-27，北京时间。独立 macOS 软件，分支 `codex/lyrictile-standalone-20261126`，PR #17。

## 本轮收尾（执行中，尚未声明通过）

- 已核对基线 `74b5d19153b1db5d962f705afb88ed585718ddc6` 与 CI36。欢迎页实际 **400×2157pt**，旧smoke只检查存在/可见，PASS不证明布局正确。
- 修复原生辅助窗口的hosting尺寸传播，加入400×360欢迎页和450×620设置页尺寸/内容边界/不重叠检查；中英文、深浅色4种生产窗口验收。12种原生歌词布局包括新增英文歌词。
- 主要界面、控制/连接状态和系统自动化权限说明补齐中英文。随macOS语言选择，不增加语言设置页面。
- CI增加可重复的真实Music本地音频验收：原创PCM实际由Music播放，普通LyricTile使用生产适配器/界面/TileKit；不伪造播放器时钟。另运行独立LRCLIB真实请求/缓存probe，结果与原生播放器分开记录。
- 安装包文件名包含build；新增ZIP/DMG/源码SHA/版本/校验/更新签名检查。官网与中英安装/隐私/支持资料在收尾。
- 上述修改尚待本轮macOS CI，不将静态检查或旧安装包结论当作通过。最终证据归档后覆盖本文件。

## 历史证据的边界

- CI36是ad-hoc云端候选，未作真实播放器验收，欢迎页有上述真实缺陷。
- 已安装并公证的1.0.0 build4来自 `3e83b5c`，不是最新候选。它的8小时长稳、Apple Music/QQ本地播放、2→4升级结果只作为历史基线。
- 四个适配器已实现不等于四个播放器已通过。首发范围由本轮实际结果决定；不把Spotify登录、四平台全过、逐字完整资格或重复8小时作为硬门槛。
- 已有签名/公证/Sparkle配置在本机；可用设备清单仅有离线个人Mac，未操作用户电脑。CI会记录实际签名能力；没有最新签名包时不发布旧build4替代。

## 继续入口

只读当前任务相关文件，不重复研究架构：UI `Sources/LyricUI`；服务 `Sources/LyricServices`；云端入口 `.github/workflows/lyrictile.yml`；本轮新增 `Scripts/check-cloud-music.py` / `Scripts/verify-release.py` / `Tools/LyricServiceProbe`。结果以本轮CI artifact与最终verification记录为准。
