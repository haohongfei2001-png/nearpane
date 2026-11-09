# Nearpane 官方网站 · R2 视觉基准

网站路径：`website/`，独立于 Nearpane macOS 原生产品工程。

## 权威版本

用户在 2026-11-10 指定 R2 版（历史 Sites version 2）作为官网基准：
- 首屏：「整个桌面。一侧掌握。」
- 左侧墨黑标题与橙色标点、右侧蓝紫色玻璃工作区
- 章节：桌面与窗口、表达与取用、你的组合

**重要：** 旧版 Sites 工程的源代码没有从原项目导出到本 Git 仓库。本目录是以用户指定的 R2 全页截图重建的独立静态站，**不是**历史源码的字节级归档。已刻意避开后续被否决的 R3–R15 新版视觉方案。若未来取得原始 R2 源代码，应优先替换重建版，并保留这份视觉契约。

## 本地使用

```bash
cd website
python3 -m http.server 4173
```

访问 http://localhost:4173。无 API 密钥、无后端、无依赖安装。

## 发布

Vercel 项目根目录设置为 `website`。默认生产分支 `main`。
- 主域名：`nearpane.com`
- 推荐 `www.nearpane.com` 301 重定向至根域名
- DNS 由 DNSPod 托管；保持现有 NS，不必迁移注册商
- 精确的 A/CNAME/TXT 请以 Vercel 项目 Domains 中返回的值为准。

## 内容与边界

网站展示 Nearpane 的完整愿景，但不应把实验性原生 Spaces 控制表述为已发布产品。
演示仅改变网页内部状态，不会调用系统窗口 API、麦克风或自动发送截图。

## 独立性

请勿将本目录的构建产物、域名密钥或网站资源写入 `Sources/`、`Tests/` 或 macOS Alpha 发行包。
