# 断点续接候选 · 实际验证

源码：[`123fd0bd1433ee2a20b7d4bd2f07b26920781b00`](https://github.com/haohongfei2001-png/nearpane/commit/123fd0bd1433ee2a20b7d4bd2f07b26920781b00)。[CI #15](https://github.com/haohongfei2001-png/nearpane/actions/runs/45798202041) · [候选 ZIP/DMG 与完整原始证据](https://github.com/haohongfei2001-png/nearpane/actions/runs/45798202041/artifacts/15105338706)。CI artifact 保存至 2026-12-26；本目录保存必要的小型原始结果，供后续会话直接核对。

## 本轮交付

| 开发单元 | 提交 |
|---|---|
| 简短 STATUS、低上下文统一入口 | [`65b35aaff40a`](https://github.com/haohongfei2001-png/nearpane/commit/65b35aaff40abde247831f09bb12a51f17438364) |
| 登录项待允许状态可取消、系统设置返回刷新、独立 app 边界 | [`2aec6c5d2e6c`](https://github.com/haohongfei2001-png/nearpane/commit/2aec6c5d2e6c79e1c4074a7bfb5f742e5c430c97) |
| 导入优先于旧请求、在线开关失效处理、迟到负缓存保护 | [`5e81901afd49`](https://github.com/haohongfei2001-png/nearpane/commit/5e81901afd499da16052305ce603e578cbbaad34) |
| 曲目身份延续、空 ID、子进程重启、控制读回/seek | [`532a41da6a7f`](https://github.com/haohongfei2001-png/nearpane/commit/532a41da6a7f164cdcc269ca5473d07db1ff6b4c) |
| 已退出组件占位回收及撤回屏障 | [`4a3c7a0cb83a`](https://github.com/haohongfei2001-png/nearpane/commit/4a3c7a0cb83a26e3baa4e5440f03860a87f7632d) |
| UI 请求归属、旧校准失败隔离、文件选择器/拖动及 hover | [`7149165fe358`](https://github.com/haohongfei2001-png/nearpane/commit/7149165fe35852b457ffd77f9d68ef6d5a8989a8) |
| 云端公共依赖临时认证，保留锁定版本及 contents:read | [`123fd0bd1433`](https://github.com/haohongfei2001-png/nearpane/commit/123fd0bd1433ee2a20b7d4bd2f07b26920781b00) |

## 实际结果

环境见 `host.txt`：macOS 27.0.1（26A434）、Xcode 27.1（27A9275）、Swift 6.4、arm64；不是用户 Mac 的实测。

| 项目 | 结果与证据 |
|---|---|
| App 与 NearpaneLyricsModule 原生编译 | PASS，CI 步骤记录 |
| XCTest | 12 通过、0 失败/错误/跳过，`test-results.xml` |
| Swift Testing | 67 通过、0 失败/错误/跳过，`test-results-swift-testing.xml` |
| Release app、ZIP、DMG、helper、Sparkle、ad-hoc 完整性 | PASS，`bundle-verification.json`；下载 artifact 后独立核对内含 ZIP/DMG 的 `SHA256SUMS` |
| 原生空态、欢迎页、设置页及退出 | PASS，`native-smoke.json`；设置截图人工检查无文字重叠，表单可滚动 |
| 真正媒体 helper 装载 | PASS，`media-helper-load.json`；真实只读 get 为空会话，未认证播放器支持 |
| 120.64 秒空闲 CPU | 0.3315679% 单核；**本次未达 0.3% 预算**，`idle-check.json` 和 `idle-summary.json` |
| 空闲 RSS 中位/峰值 | 54.28125 / 61.140625 MiB；达到 120 / 180 MiB 预算 |
| 四播放器/TCC、独立精度、长稳、用户双屏/Spaces | NOT_RUN |
| Developer ID、公证、真实更新升级 | NOT_RUN，当前包为 ad-hoc 工程候选 |

共 **79 个测试**，比原候选增加 14 个：歌词请求竞争 3、播放器身份与读回 6、布局回收 2、UI 操作竞争 3。所有原创样例只在 Tests 中；生产启动不注入歌曲、歌词或进度。

## 空闲采样判断

CPU 比目标高 0.03157 个百分点，约相当于 120.64 秒观察期间多出 0.038 秒 CPU 时间。本次结果原样保留，不因 CI 步骤成功改写为性能达标，也不重复运行以选择较低值。

超预算后的 10 秒独立 profile 中，主线程 5385 个样本有 5361 个位于正常事件等待。少量工作涉及 TileKit 旧组件发现、播放器发现和 registry；许多发现调用停在 LaunchServices IPC，不能将这些堆栈数量直接视为 CPU 归因。源码使用 2 秒桌面协调、无播放器时 5 秒发现，空闲时不启动歌词动画。未识别失控循环或本轮新引入的明确性能缺陷；旧 0.233% 数据来自另一主机运行，不构成受控回归对照。真实 Mac 的空闲和播放长稳仍需验证。原 profile 哈希保存在 `verification.json`，完整文件随上方 artifact 保留。

首轮 [`532a41da6a7f` CI](https://github.com/haohongfei2001-png/nearpane/actions/runs/45797597377) 在公共依赖下载阶段遭遇 Git 凭据错误，尚未进入编译。随后只为两条既有公共依赖 URL 提供临时只读 job token；认证值不写 Git 配置、远程地址或证据，Package.resolved 未改变。最终以上述同一源码完成全部云端检查。

下一步只按 [STATUS](../../../STATUS.md) 与 [本机交接](../../LOCAL_ONLY_HANDOFF.md) 的具体未完成项继续。
