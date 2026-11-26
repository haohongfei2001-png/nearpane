# LyricTile · 当前状态

2026-11-26，北京时间。独立原生 macOS 软件，版本 **1.0.0（4）**。开发分支为 `codex/lyrictile-standalone-20261126`，[Draft PR #17](https://github.com/haohongfei2001-png/nearpane/pull/17)。

## 当前交付

- 已将最终 DMG 中的 LyricTile.app 安装至本机用户 Applications。Apple silicon，最低 macOS 27.0。App 与 DMG 均获 Apple 公证，已装订。原样公证构建 2 通过 Sparkle 升级为构建 4。运行时代码 `8bc782c`，包内提交 `3e83b5c` 只多了验证记录。[哈希与票据](Documentation/Verification/2026-11-26-local/notarized-build4.json)
- 公开仓库内已准备[仅维护者可见的 Release 草稿](https://github.com/haohongfei2001-png/nearpane/releases/tag/untagged-97927bb5d7506543a099)，含签名 DMG、ZIP、更新签名与校验清单。稳定频道尚未发布。
- 最终安装版经正常悬停面板控制 QQ 两次暂停及恢复，4 次均有系统媒体读回。[安装版记录](Documentation/Verification/2026-11-26-local-media/qq-music.json) macOS 27.0 真机覆盖 Apple Music 1.7 和 QQ 音乐 11.11.0 的本地曲目、播放控制、切歌、定位与源归属。实际导入、在线 LRC 查询、同步显示和面板交互已有记录。QQ 暂停时禁用定位。独立音频测量 10 个会话、130 点，Apple Music 数字参考 P95 为 139.2 ms，未发放逐字时钟资格。[播放器记录](Documentation/Verification/2026-11-26-local-media/README.md)
- 实机修复 QQ 变化的 UUID 与暂停时钟、授权初次连接提示、静态歌词重复绘制、跨屏拖动和重启位置恢复、深色外观。悬停、正常退出、登录项、全屏 Space、两块不同缩放的逻辑显示器及 Riftlet/Saytile 共存已验证。[界面与桌面证据](Documentation/Verification/2026-11-26-local/ui/README.md)

## 发行与下一步

M5、24 GiB，macOS 27.0（26A428）。单核逐行 CPU 从 3.59% 降至 2.79%，复测 RSS 中位/峰值 81.56/81.86 MiB。1% 逐行 CPU 目标仍未达到。最终包十分钟空闲实测为 0.61% 单核，RSS 中位/峰值 80.50/80.58 MiB，高于 0.3% CPU 目标。运行时代码 81 项测试全过。最终安装实例自北京时间 19:20 开始八小时采样。Spotify 没有可用登录会话，网易客户端官方下载返回 403，物理外屏尚未接入。公开歌词使用的权利与地域仍待确认。[本机总报告](Documentation/Verification/local-2026-11-26.md) · [CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45809025341)

## 继续开发

按需读取 [架构](Documentation/ARCHITECTURE.md)、[接口约定](IMPLEMENTATION_CONTRACT.md)或[本机专项步骤](Documentation/LOCAL_ONLY_HANDOFF.md)。保留真实播放器锚点、异步结果归属检查、单会话锁与 TileKit 退出/重排屏障。历史托管环境结果见[续接基线](Documentation/Verification/2026-11-26-continuation/README.md)。
