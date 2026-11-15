# Nearpane 视觉素材版本

当前图示权威为 **2026-11-15-v2**。原图、实现图、生成派生件分别记录，不能互相冒充。

| 版本 / 文件 | 来源与用途 | 状态 |
|---|---|---|
| [v2 界面原图](2026-11-15-v2/interface-reference-original.png) | 用户重新上传的 1672 × 941 PNG；文字流、玻璃容器、双列微图和空间预览的视觉参考 | 原样归档，当前权威 |
| [v2 品牌原图](2026-11-15-v2/brand-reference-original.png) | 用户重新上传的 1254 × 1254 PNG；黑色 n、橙色竖柱和 nearpane 字标 | 原样归档，品牌权威 |
| [v2 App 图标派生件](2026-11-15-v2/app-icon-derived.png) | 由品牌原图经 imagegen 编辑取得的仅符号版，移除字标以用于小尺寸 App 图标 | 包装派生件，不替代品牌原图 |
| [v1 历史图](nearpane-visual-authority.webp) | 旧 480 × 270 WebP；实际渲染存在明显色块和内容损坏，其原转换过程未知 | 保留历史，停用为验收基准 |

[机器可核验清单](2026-11-15-v2/manifest.json) 记录每份素材的原文件名、尺寸、完整 SHA-256、派生关系和打包图标的 10 个尺寸表示。两份用户原图均逐字节复制，未经裁切、调色或重编码。旧 WebP 原件及 SHA 保留；不能声称它是新 PNG 的无损缩略图，也不能以它判断新版外观。

## 实现与安装包的对应关系

- [正式视觉规范](../NEARPANE-VISUAL-AUTHORITY.md) 继续规定默认宽高、持久 WorkRect 和按显示器独立设置。图示改进材质与层次，不授权重排真实窗口、不把图示窗口当成系统事实。
- 主界面完整形态继续无标题、无 Logo、无 Header。App 图标用于 Finder、应用身份及现有图标级最小形态。
- [Resources/Nearpane.icns](../../Resources/Nearpane.icns) 由 v2 仅符号 PNG 以 macOS `sips` 缩放成 16/32/128/256/512 pt 的 1×、2× 资源，再将这些 PNG 无损封装为 ICNS。原生 `iconutil` 已成功解包全部 10 种表示；不依赖运行时 Python、网络或临时生成。
- 本机 `iconutil --convert icns` 初次组装返回 `Invalid Iconset`；保留失败日志后采用标准 ICNS PNG 成员封装。后者由系统原生解码器验证，未改变图形或放宽尺寸要求。
- [prepare-app-icon.py](../../scripts/prepare-app-icon.py) 在构建时核对原始/派生素材、ICNS 各尺寸和来源，复制到 App，并写入 `CFBundleIconFile`、图标 SHA、母图 SHA 与视觉版本。主 Debug/Release、foundation 与随包测试助手均走同一资源流程。
- P5.10 起的 Alpha 安装包检查同时核对主 App 与随包助手图标。旧 Alpha 回退包继续沿用其原签名和资源，不能为补图标重写旧安装包。

本次本地检查证实，P5.9 统一安装包没有 `CFBundleIconFile` 或图标资源，其最小形态通过系统取图时会使用通用 fallback；v2 补齐此安装包缺口。正确打包与 Finder 原生可见效果是两项证据，后者由最终候选的原生验收记录给出。

官网样图与另外两个独立产品的实机图可以用来比较质量，但不替换上面用户明确提供的权威原图。未经核实来源、版本与使用场景的图片不能写成已经采用的正式设计。
