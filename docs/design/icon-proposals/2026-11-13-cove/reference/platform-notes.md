# Nearpane 应用图标平台核查与独立评审准则

日期：2026-11-13。仅研究资料，未修改产品或品牌。

## 当前平台事实

- 当前 Apple HIG 把 iOS、iPadOS、macOS 统一列为 1024×1024 方形画布，由系统裁切圆角；支持 default、dark、clear light/dark、tinted light/dark。HIG 本页格式说明最近更新于 2026-10-28。
- 仍可提供非分层 PNG。Icon Composer 分层文件能更精确地控制前景、背景、材质和不同 appearance；位图会由系统尝试分割。不能把普通 SVG/PNG/ICNS 交付等同为完整 `.icon` 文件或验证过的 Liquid Glass 图标。
- 为 Icon Composer 准备的前景优先 SVG、清晰实边、文字转轮廓、透明背景；不预烘焙外壳圆角、阴影、模糊和高光。背景在 Composer 中配置。形状应为主，材质由平台处理。
- 若交付传统静态图标，完整 `.iconset` 是 16、32、128、256、512 pt 各 1×/2×，因此包含物理像素 16、32、64、128、256、512、1024。32 px 的 16 pt@2× 与 32 pt@1× 可能需要不同光学稿。
- 传统 `.icns` 可由 `iconutil -c icns` 从 `.iconset` 生成；本环境若非 macOS，仅能做格式、各尺寸解码、RGBA/透明度和像素内容检查，不能声称通过 Finder/Dock 原生运行验收。
- 新旧路线分别保留：①纯品牌符号；②传统静态应用外壳；③给 Icon Composer 导入的无预裁角前景层。这不会牺牲品牌核心一致性。
- 深浅主题可以调整色值和背景，核心轮廓与元素关系应保持一致。

## 本轮交付的合适范围

可交付：真实可编辑 SVG 路径、透明 PNG、1024 px 高分辨率 PNG、各尺寸 PNG、完整 iconset、有效 ICNS、浅/深适配和纯色版、静态 Dock/Finder/切换器模拟、可导入 Composer 的 SVG 前景。

应明确未完成：在 macOS 27 真机上导入应用后的 Finder/Dock/切换器验收；Icon Composer 保存并用 Xcode 编译的原生 `.icon` 文件；系统动态材质、clear/tinted 实际 rendering 验收。

## 八项独立评审标准

| 维度 | 检验方式 | 否决或降级条件 |
|---|---|---|
| 品牌独特性 | 不加字、不加色，是否有可复述的具体形状关系 | 只是常见圆环、星芒、播放、n、门框，或与知名标志有强近似 |
| 图形美感与精致度 | 曲率接续、留白、重心、端部和尖点 | 依赖大尺寸材质掩盖轮廓笨重或不协调 |
| 产品气质 | 先进而平静、灵动而可靠，适合持续伴随桌面 | 像游戏币、保险、金融、AI聊天机器人或纯工具栏截图 |
| 记忆与识别 | 短暂观看后，能否描述一个特征；能否脱离颜色认出 | 全靠颜色或解释才有身份 |
| 小尺寸 | 16/32 px 原尺寸与像素放大图双检，64 px 看边界稳定 | 孔洞闭塞、轮廓粘连、薄线丢失、视觉噪点或占位不足 |
| macOS 适配 | 同尺度 Dock、Finder、应用切换器，深浅背景 | 主体重心飘、外壳过满/过空、主题变化误认另一图标 |
| 长期价值 | 去光效、去渐变、转单色后仍成立 | 主要依赖当前材质潮流；过度复杂难复现 |
| 相对现版提升 | 与真实原图同画布、同视觉体量、同环境比较 | 只是更复杂、更多效果、更大面积；实际识别或整体精致度没提高 |

硬否决：重用用户禁止的构图；把 PNG 嵌进 SVG 冒充矢量；把 Dock 模拟称真机；隐藏现版优势；把不确定的唯一性/商标安全当成事实。

## 官方来源

1. Apple HIG, App icons（当前版）：https://developer.apple.com/design/human-interface-guidelines/app-icons.md （web ref `turn3view1`，2026-11-13 读取）
2. Apple Xcode, Creating your app icon using Icon Composer：https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer.md （web ref `turn3view2`）
3. Apple Xcode, Configuring your app icon using an asset catalog：https://developer.apple.com/documentation/xcode/configuring-your-app-icon （搜索 ref `turn1search1`）
4. Apple High Resolution Guidelines, Optimizing for High Resolution（历史文档，用于传统 iconset/ICNS 尺寸与命名，不代表新平台设计政策）：https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/Optimizing/Optimizing.html （web ref `turn2view2`）
5. Icon Composer 当前产品页：https://developer.apple.com/icon-composer/ （web ref `turn1search2`）

注：2012 年文档所说的旧 Icon Composer 与当前新的同名分层设计工具不可混为一谈。
