# 5.22（90）窗口调度区实机复测

**窗口显示通过。** 2026-11-20，在 Apple Silicon Mac、macOS 27.0（26A428）、单块物理屏上，把签名候选 `365fdc40c19853e4fa4343f9f20c240c85b7583b` 原位安装到 `/Applications/Nearpane.app`。系统保有四个 Space。打开和关闭两扇专用文档时，正式侧栏显示的窗口卡数量依次为 **0、2、0**。[三次系统和侧栏读回](results.json)

旧版直接遍历系统 Space 清单。复现时确认应用窗口卡为 0，却有 4 个空间行，其中 3 个用“窗口归属尚未读全”占位。修正后，每张卡都对应一个已确认的应用窗口或用户主动创建的组合；共享窗口只显示一次。后台继续使用 Space 身份定位窗口。当窗口成员未知时，侧栏留白。[修复前读回](before.json) · [原生源码](https://github.com/haohongfei2001-png/nearpane/commit/365fdc40c19853e4fa4343f9f20c240c85b7583b)

| 正式侧栏的状态 | 系统可证实的普通窗口 | 窗口卡 | 单独空间行 / 占位文字 | 真实侧栏 |
| --- | ---: | ---: | --- | --- |
| 临时文档关闭 | 0 | 0 | 0 / 0 | [空白侧栏](empty-before-sidebar.png) |
| 打开两扇普通文档 | 2 | 2，逐一匹配进程及窗口编号 | 0 / 0 | [双窗侧栏](two-documents-sidebar.png) |
| 关闭两扇文档 | 0 | 0 | 0 / 0 | [关闭后的侧栏](empty-after-sidebar.png) |

三张图均来自运行中的正式 Host、隔离配置和实际壁纸。取像前后都核对了同一已签名 Host、侧栏几何及完整卡片集合。两张空态侧栏 PNG 的 SHA-256 相同。文档刚关闭时 WindowServer 还保留过窗口编号；窗口卡已经消失，夹具退出后原编号也全部消失。另一次在有日常窗口的桌面上读到 **4→6→4**。这次仅保存数量和自建文档身份，未保存日常窗口像素。[混合桌面计数](occupied-desktop.json) · [截图校验值](CHECKSUMS.sha256)

功能回归使用仓库原生测试入口，Swift **520/520**、Python **32/32**。原先有一条面板像素测试要求空白区域必须有文字，现已改为检查该区域没有文字笔画。初次建场、收尾时序和未取得截图的运行均单列保留。[测试结果](tests.json) · [之前各次尝试](setup-attempts.json)

本次 6 次隔离运行均已恢复日常 Host 和配置，并清理临时数据。一次建场临时创建了一个普通桌面，已按 UUID 回收；该次未确认原焦点恢复。收尾时原有 Space 身份集合保留，系统只登记正式 Nearpane 路径。正式 Host 的辅助功能、事件投递和录屏权限仍为允许。[逐次恢复](profile-restoration.json) · [最终安装及系统状态](final-installation.json)

**当前 arm64 签名候选**为 `Nearpane-5.22-90-365fdc4-macOS-arm64.zip`，SHA-256 为 `6249539982bcec943a70a43164eefbe6328b48c600d2ac05aec72eba83903bb1`。已通过 Developer ID 深度验签和真实启动，未经 Apple 公证。本次只验收窗口区呈现。完整跨桌面切换、精确输入与迁窗沿用此前未通过状态，PR #15 保持 Draft。[下载签名候选](https://github.com/haohongfei2001-png/nearpane/releases/tag/untagged-0d613209d89c24e3816f) · [签名连续性](installation.json) · [此前交互结果](../5.22-90-installed-contract/RESULTS.md)
