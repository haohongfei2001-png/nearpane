# LyricTile · 当前状态

2026-11-27，北京时间。独立原生 macOS 软件；开发分支 `codex/lyrictile-standalone-20261126`，[Draft PR #17](https://github.com/haohongfei2001-png/nearpane/pull/17)。本轮外观实现已完成，运行时代码 [`39dabc3`](https://github.com/haohongfei2001-png/nearpane/commit/39dabc3ae676471a334dcb07112ee9e825f9b574)。

## 最终设计

- **播放时出现，闲置时消失。** 有真实歌曲且正在播放时自动显示；无歌曲、停止、未知或缓冲时隐藏并释放独立侧栏占位。暂停只保留用户正在操作的同一歌曲面板，交互结束后隐藏。菜单栏保留状态、连接、歌词导入和设置；旧常驻空板开关已取消。
- **五行歌词，204pt 高。** 当前句 18–20pt（大字 22pt），近邻 14pt、远邻 12pt；短句垂直居中，长句按完整行显示并保留原生滚动。翻译不替代上下文；纯文本保留未同步提示。
- **无歌词摘要，112pt 高。** 显示已有封面、真实歌名/歌手及简短状态。hover 在原尺寸内显示歌曲信息、播放控制与真实进度，歌词态保留中央句。缺封面用中性符号，缺歌手省略，缺曲名明确提示，未知时间为 —:—。
- 沿用原有播放器、歌词服务、异步结果归属、会话锁和 TileKit 撤回/确认屏障；没有扩展 provider 或改造 Nearpane。隐藏时释放占位通过现有 coordinator 完成。

## 本轮验证

[CI30 全部通过](https://github.com/haohongfei2001-png/nearpane/actions/runs/45875877384)：macOS 27.0.1 arm64，Xcode 27.1 / Swift 6.4；生产 app 与 host facade 编译、75 个 Swift Testing 测试定义 + 13 个 XCTest 用例、ad-hoc 候选构建、无播放隐藏及辅助窗口原生启动、helper 加载均通过。121 秒无播放器空闲检查符合现有预算。

七组原生布局截图已检查，涵盖五行、hover、112pt 摘要、176pt 深色长句/翻译、缺失元数据和无歌曲透明态。[截图与证据边界](Documentation/Verification/2026-11-27-ui/README.md)。夹具未启动真实播放器，不代表真实歌曲封面、鼠标事件或控制链路已通过本轮实机验收。

## 必要剩余

在更新的签名安装包上复核实际桌面的播放→暂停→离开→恢复、歌词异步到达的收缩/展开，以及浅/深壁纸下的玻璃材质观感。本轮没有生成新的 Developer ID 签名/公证包或发布版本；已有本机安装基线仍为 **1.0.0（4）**，旧实机结论见[本机报告](Documentation/Verification/local-2026-11-26.md)。

## 继续开发

从上述必要剩余继续，按需读取[界面实现](Documentation/UI_IMPLEMENTATION.md)、[接口约定](IMPLEMENTATION_CONTRACT.md)或[本机专项步骤](Documentation/LOCAL_ONLY_HANDOFF.md)，无需检索旧对话或重做播放器研究。
