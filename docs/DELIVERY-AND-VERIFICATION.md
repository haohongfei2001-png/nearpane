# Nearpane — 设计交付与验证清单

**分支：** design/integrated-architecture-20261108  
**基线 main：** f3d8b3d3a9fd67b04e0c663e08472d81adb7bb44  
**最新设计提交（本清单生成前）：** 1880ab9dd597063456119abf63eed35e5bfcd373  
**状态：** 文档与原型已推送；哈希已对远程文件复算；历史 44 项检查不重跑。

## 1. 本轮交付文件

| 文件 | 内容 | 状态 |
|---|---|---|
| docs/architecture/MACOS-SPACES-FEASIBILITY.md | Spaces 技术可行性、公开/私有 API 分层、证据边界与降级策略 | 已提交 |
| docs/architecture/NEARPANE-ARCHITECTURE.md | Host、桌面编排、Saytile/Riftlet 集成与跨模块边界 | 已提交 |
| docs/architecture/USER-MODULE-SYSTEM.md | 内置模块注册表、manifest、生命周期、权限与布局策略 | 已提交 |
| docs/design/INTERACTION-SPEC.md | 主表面、语音、截图、Space、窗口与可选模块交互 | 已提交 |
| docs/prototype/nearpane-interaction-prototype.html | 单文件可交互 HTML 原型，含合成数据与模块展开 | 已提交 |
| docs/engineering/IMPLEMENTATION-ROADMAP.md | P0–P6 工程实施路线与准入门槛 | 已提交 |

## 2. 原型验证

- 从设计分支 GitHub raw URL 下载原型成功。
- 文件大小：12,681 bytes。
- HTML 中包含 4 个 Space 示例、5 个可选模块入口。
- 提取内嵌 JavaScript 并执行 Node.js --check：退出码 0。
- 原型中的窗口、Space、语音文本、截图和模块数据均为合成演示数据，不访问真实 macOS 状态，不执行真实截图、窗口切换、上传或发送。
- 历史 44 项检查：保留为上一轮历史执行记录；本轮没有重新运行，也不宣称当前原型重新通过 44 项。

## 3. SHA-256 校验

以下哈希由 macOS shasum -a 256 对从本设计分支 raw URL 下载的实际文件计算。它们不是 Git blob SHA。

| 文件 | SHA-256 |
|---|---|
| docs/architecture/MACOS-SPACES-FEASIBILITY.md | 9b4aa0784b55c5b780b68708bea6b6b1773dc2fac698abe576f92173fcfc0ea4 |
| docs/architecture/NEARPANE-ARCHITECTURE.md | 1c62637a00d0b1ef5d977ca481b372934b9b29a9874082d62ee3be5e63955047 |
| docs/architecture/USER-MODULE-SYSTEM.md | 295570d24628cd9e4a10a6981b06828dd567f3cc42f4db53953bc12afde63301 |
| docs/design/INTERACTION-SPEC.md | 04a79085a844fc8527d2f6ca57610261ff0a6a640162c0dd8532775159b5da0a |
| docs/engineering/IMPLEMENTATION-ROADMAP.md | 6794ba92f17b2823f6a5004dbcbdcfe7373ff8b2f4e9da1d04fa8fe4aabbec4c |
| docs/prototype/nearpane-interaction-prototype.html | 94d87618a6a15c6fc5638c67842e86f9de19c9652fdc4f16099198a062a40013 |

## 4. 历史证据与未完成验证

- 上一轮三个仓库审查和模块整合研究：作为本轮既定基线继承，不重新审计。
- 上一轮 44 项原型检查：历史执行记录，不代表本轮重跑。
- Spaces 公开独立显示器设置与 SkyLight 私有分组不一致：历史观察保留，原始 JSON 收据未恢复，标记 OBSERVED-HISTORICAL / RAW-RECEIPT-NOT-RECOVERED。
- 完整 Space inventory、跨显示器映射、窗口 membership、切换与激活：仍需按 MACOS-SPACES-FEASIBILITY.md 的系统矩阵进行真实设备验证。
- App Store 私有 API 审核风险：尚未获得 Apple 审核结论。
- Saytile/Riftlet 集成：本轮定义接口和领域边界，没有合并实现分支或改动其 main。
- 用户自定义模块：本轮完成系统设计，不包含运行时实现、数据库 schema 或 Settings runtime。

## 5. 明确未实施事项

本轮没有写入 Nearpane 生产运行时代码，没有修改生产 HTML/CSS/JS，没有实施数据库 schema/migration、截图采集、Thought Library runtime 或 Settings runtime，没有合并任何实现分支，没有修改 Nearpane main、Saytile main 或 Riftlet main。

## 6. 完成交付的判定

本轮设计交付达到：**DESIGN PACKAGE COMMITTED + REMOTE VERIFIED + PROTOTYPE STATIC CHECKED**。

不等于：**PRODUCT IMPLEMENTED**、**SPACES FULLY VALIDATED** 或 **RELEASE READY**。
