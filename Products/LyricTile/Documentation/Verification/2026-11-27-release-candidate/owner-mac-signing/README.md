# 原CI49负载的正式签名、升级与本机安装

版本 **1.0.0 / build49**，源码 `b95b6f5ed7680cbde1427a4ed1a904bd5875e17b`。使用用户已有授权远程Mac、Developer ID团队 `ZB9D4T66QB`、公证配置及原LyricTile更新密钥。未重编译原CI49程序；工程候选与最终消费包的字节及签名状态分别保存。

## 已完成结果

| 对象 | 实际结果 |
| --- | --- |
| Developer ID / Sparkle | 使用原团队与原产品密钥；37/37发行检查通过，更新Ed25519签名验证通过 |
| App Apple公证 | Accepted；`a6abeb64-7d98-4814-a18f-ae75209e469b` |
| DMG Apple公证 | Accepted；`c2640d58-0dba-49c4-9a63-d09315249a1e` |
| 原候选→签名副本 | 191路径、7个Mach-O、12个架构slice比较通过 |
| 原样build4→最终49 | 真实Sparkle CLI安装、签名回环feed与最终ZIP；升级后完整App树与公证DMG相同 |
| 最终包原生窗口 | 中文/英文×深/浅四组合，实际2× native smoke通过 |
| 最终用户安装 | `~/Applications/LyricTile.app` 经LaunchServices普通启动，实际PID76065；1.0.0/build49/精确source读回正确，完整App树与公证DMG相同，codesign/stapler/Gatekeeper通过 |

[signing-acceptance-summary.json](signing-acceptance-summary.json)是签名完成、尚未启动阶段的原始摘要，因此保留 `PASS_SIGNING_NOT_INSTALL_CHECKED` / `appLaunched=false`；后续结果分别见[真实升级回执](upgrade-result.json)、[2×窗口smoke摘要](native-smoke-summary.json)和[最终安装回执](installed-release-result.json)，不改写较早原件。

[最终签名包2×欢迎页原图](native-welcome-2x.png)从正式Release本机证据ZIP原样提取：800×720px对应400×360pt，内容和按钮完整。来源与hash见[SOURCE.json](SOURCE.json)；其余7张窗口原图仍完整保留在正式Release的[本机证据ZIP](https://github.com/haohongfei2001-png/nearpane/releases/download/lyrictile-v1.0.0-build49/LyricTile-1.0.0-49-local-verification.zip)。

## 文件与数据保留边界

| 正式文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `LyricTile-1.0.0-49-arm64.zip` | 4,029,734 | `4e2161d2598fb6194401f00c951d641070161943bbc4697d4b7eac3f15e10515` |
| `LyricTile-1.0.0-49-arm64.dmg` | 4,439,015 | `a6813cbebc59ae465e215d2ab5053d7591bb0fef8e89644a1723f58ed6e58329` |

本机升级前基线为2个持久文件、`bindings=0`、`adjustments=0`。在实际Sparkle升级完成的检查点，原2文件与产品设置字节保留；**没有已有导入绑定或时间校准可供迁移验收，不声称这类数据迁移通过**。原样build4备份留本机。随后正常播放产生的新用户缓存、非测试Music曲目及暂停状态均保留，没有将最终整个Support恢复为旧基线；仅按明确测试ID清理自有测试曲目和列表。公开证据记录状态、数量和公开产品包hash；不公开私人数据的hash。私人播放详情和凭据留本机。精确测试曲目与列表已删除；原安装回执中的 `ownedCopiedAudioRemoved=false` 表示当次清理未执行文件删除，后续[限定复查](test-media-cleanup-scope.json)确认Music已移除该独立导入音频文件；不改写较早原件。

## 比较工具的范围

[compare-signed-payload.py](compare-signed-payload.py)只读比较两份App：仅允许既定发布feed、公钥、提取前校验开关、发行channel四个指定Info值，以及具体签名seal和公证票据。其他资源、权限、符号链接、每个Mach-O架构UUID/section及完整非签名前缀必须相符。原候选自比与资源篡改负例见[工具验证](tool-validation.json)。

工具不证明证书信任、entitlements、Gatekeeper或公证；系统工具的真实检查已独立完成。2×窗口smoke不扩大为所有播放器2×矩阵；CI49实际播放与CPU结果、Spotify未实测、逐字精度与历史八小时边界仍见[最终验收](../final-acceptance.md)。

## 正式公开记录

- 正式tag：`lyrictile-v1.0.0-build49`；精确source：`b95b6f5ed7680cbde1427a4ed1a904bd5875e17b`。
- Release ID：**460855402**；`draft=false`、`prerelease=false`，7个附件均为uploaded。
- Release URL：[LyricTile 1.0.0 / build49](https://github.com/haohongfei2001-png/nearpane/releases/tag/lyrictile-v1.0.0-build49)
- published_at：**2026-11-27T16:52:36Z**；北京时间 **2026-11-28 00:52:36**。

本机专属必需事项及后续公开发行均已完成，没有必须交给Codex的发行步骤。[正式发布索引](../formal-publication/README.md)保存公开Release、4项实际匿名下载、线上feed及正式网站验收；下载包与上述已签名公证文件相同。各本机报告的来源与hash见[SOURCE.json](SOURCE.json)，较早签名阶段和后续启动/升级阶段不互相改写。
