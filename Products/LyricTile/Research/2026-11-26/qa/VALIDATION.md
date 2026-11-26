# 交付验证范围

研究基线：2026-11-26，Asia/Shanghai。

## 本轮实际通过

- 自包含设计HTML实际加载与渲染；图片和封面可用，零JavaScript错误。
- 悬停前后窗口与当前歌词锚点不变；歌曲菜单打开/Escape关闭；暂停预览正确清理标记。
- 临时未知进度与永久不提供进度均禁用seek，并显示未知时间；不假装实机命令完成。
- 16个主要状态/排版/材质卡片、两组首次使用/设置窗口、两种生态布局已渲染审阅。
- 11页视觉PDF、9页决策PDF渲染审阅；无空白页或超出页面边界的文字；设置窗口不侵入页脚。
- 9秒独立动效设计样本的暂停、重播、结束、固定几何与Reduce Motion；零联网。
- 390px评审视口无横向溢出。
- contracts中全部JSON可解析；player-capabilities为有效Draft 2020-12 schema定义。能力资格负例由媒体审计执行。
- LRCLIB一次真实HTTP200字段探测，摘要在research/lyrics/lrclib-live-probe.json。该响应hasWordSync=false；它验证新增字段存在，不证明该歌曲有逐字歌词。

## 没有在本轮执行

- Swift编译/typecheck、四个播放器在macOS27上的运行、原生时钟精度、TCC、窗口焦点/Spaces/跨屏行为。
- Developer ID签名、公证、真实安装包、更新安装和8小时资源测试。
- 任何网络歌词曲库的完整商业内容授权。

这些项目必须按docs/MACOS27_ACCEPTANCE.md执行并记录PASS/FAIL/NOT_RUN。本文件不能替代那份验收。
