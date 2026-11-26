# LyricTile 设计资产

- `app-icon-master.svg`：确定性 Light 几何母版。
- `app-icon-dark.svg` / `app-icon-tinted.svg`：Dark 与 tinted 色彩方案。
- `lyrictile-symbol.svg`：无底色主体符号，`currentColor` 可随宿主变化。
- `app-icon-concept.png`：AI 生成的材质探索参考；不作为最终小尺寸栅格图标。
- `sample-cover-original.png`：本轮生成的原创封面样张，无真实专辑归属。

SVG 为可编辑设计母版，不是已验证的 `.icns` / Icon Composer 产物。开发时分离背景与前景层，按当前 Xcode/Icon Composer 的导出要求生成系统资源，检查24/32/64px。不要把示意底板阴影重复烘焙进系统材料。所有示例歌词与曲名仅作排版，不能进入真实播放的数据层。
