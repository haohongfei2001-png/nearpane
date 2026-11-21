# 窗口可见性 PoC 证据

三项提供器全部 **FAIL**。生产整组切换为 **BLOCKED**。两套托管 macOS 都在单窗门槛发现反例，正式 Host 扩测为 **NOT_RUN**。 [完整裁决、评分和实施计划](../../../research/NEARPANE-WINDOW-VISIBILITY-FINAL-FEASIBILITY.md) · [机器可读结论](results.json)

| 操作 | macOS 26.7.2（25G332） | macOS 27.0.1（26A434） |
| --- | --- | --- |
| 单窗操作、独立的外窗恢复、Dock 点击、真实键鼠与原生 Space | [完整收据](runs/44866013086/macos-26/summary.json) · [离线读回](runs/44866013086/macos-26/replay.json) | [完整收据](runs/44866013086/xcode-27/summary.json) · [离线读回](runs/44866013086/xcode-27/replay.json) |
| SIGKILL 后恢复、Mission Control | [收据及截屏目录](runs/44866419114/macos-26) | [收据及截屏目录](runs/44866419114/xcode-27) |

每个最终环境各有 311 条事件及 127 次独立窗口快照，分为一次核心实验和一次单独的崩溃实验。原始事件以 gzip 无损保存，文件内的顺序号、UTC 秒、单调时钟纳秒、进程代际和 CGWindowID 可供复查。process.log 是夹具进程自己的标准输出，零字节表示没有输出；console.log 是 Actions 运行该实验的完整步骤输出。Dock、进程退出、临时目录和拓扑有单独的清理读回。每个托管环境用了全新登录账号。 [文件哈希](SHA256SUMS) · [精确构建物理机只读预检](exact-26A428-preflight.json)

## 从原始数据核对

在此目录运行以下命令。第一条只读取原始窗口记录和摘要，第二条校验全部归档数据。

```sh
python3 -B replay.py runs/44866013086/xcode-27
shasum -a 256 -c SHA256SUMS
```

- A 的关键事件为 A.single.hidden-settled、A.single.restored-settled、A.single.restored.key-delta。A.userDock.yield 记录 Dock 操作后实际恢复的窗口及写入计数。
- B 的每个模式有单独的 connection、out、hidden-settled、click-delta 和 close。restore-only 由所有者先执行 orderOut，再由同一外部客户端请求恢复。可分别核对隐藏与恢复能力。启动时保留的 AX 引用在自有 AppKit 隐藏之后可能失效；同一收据同时保存本次重新枚举的 AX 窗口与所有者信息。
- C 的 parked、virtual-hit.click-delta 和 after-dispose 记录离场期间的 Space、事件接收者和恢复。C.crash.after-crash 在任何显式清理前取样。截图在已独立确认系统概览打开时拍摄。
- OBSERVED 表示有直接观察的诊断事件。各项产品能力的 PASS、FAIL、UNKNOWN、BLOCKED 或 NOT_RUN 在机器结论单独列出。Actions 成功表示实验按计划结束并保存结果。

## 研究代码和历史

原生探针和签名夹具可以在 macOS 用开发工具编译。实时输入与拓扑试验入口限定一次性托管登录会话。运行包只包含研究探针，不会装入应用程序目录。 [PoC 源码](poc) · [固定提交和 Git blob](pinned-sources.json) · [托管环境配置](../../../../.github/workflows/stagegroup-visibility-lab.yml)

| 修订 | 用途 |
| --- | --- |
| 83b09d6 | 首次夹具没有建立准确初始键盘焦点。两个系统的真实动作均为 BLOCKED。 [原始交付](runs/44865284705) |
| 225228c | 增加校准函数但当时尚未接入；发现后取消冗余运行，保留此前已生成的两个环境收据。 [保留记录](runs/44865452250) |
| 76d9ca8 | 接入真实基线点击，发现初轮 A0 测点被遮挡。外部排序、虚拟屏和独立 Dock 干预取得读回。旧事务返回数值未取得 ABI 资格；最终实验仅报告请求提交及独立读回。 [原始交付](runs/44865492229) |
| b246b6e | 固定初始堆叠，加入持续的 AX 引用、单独的外部恢复试验以及最小化当前键盘窗口试验。 [核心运行](https://github.com/haohongfei2001-png/nearpane/actions/runs/44866013086) |
| d67207c | 单独运行持有者被终止的试验，保留系统概览截图。 [崩溃试验](https://github.com/haohongfei2001-png/nearpane/actions/runs/44866419114) |
