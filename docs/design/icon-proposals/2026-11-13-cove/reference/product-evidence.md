# Nearpane 图标设计：产品与现版证据核查

核查日期：2026-11-13（北京时间）。本次只读取；未修改远端、官网或生产图标。

## 已核对来源

- main: `e3f26bbaa1ba4da87da56b475f5fa6fa5daa8766`。
- implementation/host-foundation-20261109: `d262e60b27f7c2db70821371b0606c6edeb70486`。
- codex/reference-glass-rail: `d79055588539b96cfaad7943caa4a978c530f791`。
- https://nearpane.com/ 和 https://nearpane.com/assets/favicon.svg 已直接下载；HTML、favicon 与 main 对应文件 SHA-256 分别完全一致。
- favicon SHA-256：`d98e78c8f46c5a27f23d625d05d08b6808dd7ca2413d66a2791cc56c2de439ff`。

## 真实产品

Nearpane 是常驻桌面交互与编排层。main 产品定义是早期基线；最新实施分支已明确默认 Native Spaces、可选 Virtual Workspaces 两种引擎、持久 WorkRect、8 窗溢出策略、按需呈现与全屏恢复的目标。语音、截图和可选工具形成连续桌面工作体验。不能把它定义为传统窗口管理器，也不能把尚未取得证据的空间操作当成完成能力。

最新视觉分支保持可用屏宽 1/8 的完整外框，内嵌 Saytile 的持续文字流、Riftlet 真队列及真实窗口预览。语音模块与独立 Saytile 共用原生视图。主表面没有品牌头、标题或 Logo。审美核心是低打扰、准确、亲近、稳定的空间秩序；玻璃是界面材质，不是图标必须采用的品牌识别。

## 官网现版图标

真实原 SVG 已保存在 `current-website-icon.svg`。64×64，底色 #FAFAFD、圆角 15；黑色 n 为 #17181D，约 x16–40/y21–43；橙线 #F97955，x45–48/y17–47，宽 3。官网 CSS 强调色另为 #FD734F。首页导航是文字 nearpane + 橙色细线，并非把 favicon 放入导航。

比较时应标注“官网现版 favicon”。这是明确可验证的现版源文件，不应擅自称它为已经部署的 macOS 正式 app icon。其优点是简单、紧凑、与名称一致；弱点是形态依赖普通 n 字形、细线在16px仅0.75px、小尺寸记忆主要依赖字母。

## 已保存的实际视觉证据

- `actual-native-hosts-top.png`：两个原生宿主的语音卡对照。
- `reference-and-native-rail.png`：用户效果图与原生完整侧栏对照。
- `current-native-visual-evidence.md`：图像来源与验收边界。
- `current-product-definition.md`：最新实施分支产品定义。

主仓早期 visual-authority.webp 只有480×270、7.6KB，损坏感较强，不适合作为精细造型或颜色采样权威。原生证据是临时验收环境，不是当前用户生产安装截图。

## 设计判断

值得提取的气质是“可被信任的近在手边的连续秩序”，而非窗口/竖栏/工具的拼图。新符号必须先在单色下独立成立。品牌主色可重新审视，紫蓝玻璃背景不构成 Nearpane 品牌色的既定批准。

## 精确引用

- https://github.com/haohongfei2001-png/nearpane/blob/e3f26bbaa1ba4da87da56b475f5fa6fa5daa8766/docs/PRODUCT_DEFINITION.md
- https://github.com/haohongfei2001-png/nearpane/blob/d262e60b27f7c2db70821371b0606c6edeb70486/PRODUCT_DEFINITION.md
- https://github.com/haohongfei2001-png/nearpane/blob/d79055588539b96cfaad7943caa4a978c530f791/engineering/verification/reference-glass/README.md
- https://github.com/haohongfei2001-png/nearpane/blob/e3f26bbaa1ba4da87da56b475f5fa6fa5daa8766/website/assets/favicon.svg
