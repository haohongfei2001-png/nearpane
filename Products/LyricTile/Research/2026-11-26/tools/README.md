# 设计交付重建

本目录只用于重建设计图与PDF，不是产品实现。

`render_deliverables.py` 使用 Python 3、`playwright`、`markdown`，以及可用的 Chromium / Chrome Headless Shell。设置 `LYRICTILE_RENDER_BROWSER` 为浏览器可执行文件的绝对路径，再运行脚本。脚本默认路径仅适用于本轮研究环境；交接包不携带浏览器安装包。

脚本从 `design/LyricTile-Design.html` 与 `docs/LyricTile-Decision.md` 生成自包含HTML、11页视觉册、决策PDF、PNG和原型检查结果。原始封面以Blob URL嵌入自包含页，以避免超长CSS自定义变量在浏览器中的长度上限；原图未经压缩改绘。

用于静态状态样张的背景已经是柔和色块，打印版在这些块内关闭浏览器backdrop重采样，以保持文字清晰；产品的原生材质定义仍以 `DESIGN_SPEC.md` 为准。

JSON校验、原型尺寸检查、截图与PDF渲染只能验证交付文件，不能证明macOS、播放器、TCC、公证或性能达标。实际应用按 `docs/MACOS27_ACCEPTANCE.md` 验收。
