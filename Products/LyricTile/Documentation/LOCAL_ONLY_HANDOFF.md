# LyricTile · 本机专属事项已完成

**当前没有必须交给Codex继续的本机发行步骤。** 已通过现有授权远程Mac完成最终49的签名、公证、升级和安装；本文件保留结果入口，不再要求重复构建、重新生成密钥或重跑验收。

- 固定版本 **1.0.0 / build49**，源码 `b95b6f5ed7680cbde1427a4ed1a904bd5875e17b`；普通产品负载来自已测CI49副本，未重新编译。
- 原Developer ID及产品更新密钥沿用；App/DMG Apple公证、Sparkle签名和37项发行检查通过。
- 原样build4→同一最终49的真实Sparkle安装通过；中英×深浅四组合2×窗口smoke通过。
- 最终 `~/Applications/LyricTile.app` 普通LaunchServices启动通过，版本/源码和完整App树与公证DMG一致，codesign/stapler/Gatekeeper通过。
- 在实际Sparkle升级完成的检查点，原有2个持久文件与产品设置字节保留；基线没有导入绑定和时间校准，不据此声称这些已有数据的迁移。原build4备份留在本机。
- 随后正常播放产生的新用户缓存、非测试Music曲目及暂停状态均保留，没有将最终整个Support恢复为旧基线；仅按明确测试ID清理自有测试曲目和列表。私人轨迹与凭据不进入公开文档。

详见[本机签名与安装记录](Verification/2026-11-27-release-candidate/owner-mac-signing/README.md)、[最终验收](Verification/2026-11-27-release-candidate/final-acceptance.md)和[STATUS](../STATUS.md)。

## 正式发布已完成

- 正式tag：`lyrictile-v1.0.0-build49`；精确source：`b95b6f5ed7680cbde1427a4ed1a904bd5875e17b`。
- Release ID：**460855402**；`draft=false`、`prerelease=false`，7个附件均为uploaded。
- Release URL：[LyricTile 1.0.0 / build49](https://github.com/haohongfei2001-png/nearpane/releases/tag/lyrictile-v1.0.0-build49)
- published_at：**2026-11-27T16:52:36Z**；北京时间 **2026-11-28 00:52:36**。

公开ZIP、DMG、校验文件及appcast的匿名下载、实际live feed签名、正式中英产品与帮助四页及中文下载按钮所得完整DMG均已核实。详见[正式发布原件](Verification/2026-11-27-release-candidate/formal-publication/README.md)。本机和远程发行环节均无必须转交Codex的剩余步骤。

PR17保留open draft及原base，不合并或删除承载正式feed的开发分支。
