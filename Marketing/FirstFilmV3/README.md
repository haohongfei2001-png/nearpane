# Nearpane 首支产品影片 · v3 中文横版

本次修订只制作中文16:9横版。39秒，4K及1080p，30fps；保留真实歌曲、原专辑封面、Music→Preview连续操作与QQ音乐片段，修正Riftlet的实际高度，并加入六句简洁中文旁白及大字号文案。

## 这次必须保留的产品事实

- Riftlet空托盘两个入口是一行。真实截图进入后，才变成两行。
- 高度直接来自生产`LayoutComposer`：76→144pt。摄影比例始终280/208，图标和单元格不单独拉伸。
- 两卡等宽，按各自真实内容决定高度。上下换位是管理页真实排序；没有桌面拖动卡片的虚构交互。
- 原片中的排序与高度变化均为即时布局变化。成片未添加不存在的中间几何。
- 歌词卡一直靠桌面右上边缘。悬停真实显示专辑封面及控制，未伪造暂停/切歌/拖动进度的操作结果。
- 仅验证Music和QQ音乐；这首歌使用已校对的本地LRC，未宣称本片演示了线上自动匹配。
- 统一Nearpane公开安装包及首装默认启用尚未作为发行完成项核验。片尾是`nearpane.com · 访问官网 · 产品预览`。

## 可编辑内容

`config/approved-edit.json`记录全部镜头、入点、时长、文案落点、音频及产品事实。`config/narration-zh.json`记录旁白全文、模型版本、音色、种子及时间窗口。`src/brand_frames.py`控制字形、字号、色彩、位置与片尾。

`assets/native/`保存实际录屏；`assets/music-source/`保存获许可歌曲、封面与歌词来源；`assets/audio/narration/`保存未经处理和处理后的每句旁白、独立人声/音乐轨、混音回执和SRT。`assets/processed/`可全部由脚本再生成。

模型权重和运行环境不进入Git或交付压缩包。独立素材包保留已生成的WAV，重渲染视频不需要重新生成声音。

## 重渲染

环境：Python3.12、FFmpeg7.1.5，安装`requirements.txt`。从本目录运行：

```bash
python src/extract_native_cards.py --mode order --start 2.55774946126843 --duration 8.29225053873157 --out assets/processed/native-order-alpha.mov
python src/extract_native_cards.py --mode capture --start 20.6 --duration 2.3 --out assets/processed/native-expansion-alpha.mov
python src/prepare_native_details.py
python src/prepare_narration_mix.py
python src/render_edit.py config/approved-edit.json --out out/Nearpane-ZH-v3-4K.mp4 --width 3840 --height 2160 --lang zh --crf 18
python src/render_edit.py config/approved-edit.json --out out/Nearpane-ZH-v3-1080p.mp4 --width 1920 --height 1080 --lang zh --crf 18
python src/export_keyframes.py out/Nearpane-ZH-v3-4K.mp4 --out out/keyframes
ffmpeg -ss 14.5 -i assets/native/core/core-fullscreen.mov -frames:v 1 out/cover-source.png
python src/make_cover.py out/cover-source.png --out out/Nearpane-ZH-v3-Cover-4K.png --lang zh
```

录屏来自ScreenCaptureKit，为可变帧率。先从原始时间原点统一到30fps，再选镜头入点；不得先丢弃入点前的帧、再重置首帧时间，这会吃掉桌面静止期间的真实停留。每镜头限定精确帧数；全片1170帧。

`src/extract_native_cards.py`只做真实像素的外部遮罩与纸色背景上的编辑阴影。遮罩状态读取原片中已验证的空隙行；4K外框76→144pt及实际1px取整位移均随原生画面发生。详情见`docs/NATIVE-HANDOFF.md`。

## 验收和权利

查看`docs/ACCEPTANCE.md`、`docs/NARRATION.md`及`licenses/`。音乐为Josh Woodward的《Good To Go》，真实封面为《The Simple Life》，按CC BY3.0 US使用并署名。旁白为通用预设音色的本地AI合成，非真人录音；没有使用第三方参考录音克隆声音。

此环境可检查画面、连续帧、字词识别、响度、峰值、同步及技术参数，无法代替人的主观听审。这一限制保留在验收记录中。

Git只保存制作源码、规范和轻量回执；大媒体通过独立制作包交付，不提交主源码分支。
