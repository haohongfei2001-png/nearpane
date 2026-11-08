# D · Nearpane 统一 Host 离线验收（2026-11-09）

**结论：同一原生 Host 的离线集成通过。** 使用正式应用的装配入口、真实领域代码、临时 SQLite 资料库和从未显示的 AppKit 面板。真实设备转写、线上草稿附加、可见桌面行为和 P4 不在通过范围。无须新增产品决定即可保留本阶段。

| 阶段 | 本地工程提交 | 结果 |
| --- | --- | --- |
| 起点 | `7d09cce95ec62e1fb2e20123e7123421bc7e389d` | 继承既有 P2、46 项测试；无重新建库或工作树。 |
| [A：Host](A-host-closeout.md) | `b63b0b7026dc15d24d4515528b363d6fd96118a8` | 49/49；Debug、Release。持久化隐藏意图、无效屏幕、事件与授权生命周期。 |
| [B：Saytile](B-saytile.md) | `fac8319e01c7ce592aa521f78c61460258b8f871` | 52/52；Debug。上游语音引擎、三态控件和单一文字流。 |
| [C：Riftlet](C-riftlet.md) | `4498ed25b7bd1edb291d1c8318f2f616fc2bc8e3` | 58/58；Debug。真实队列、捕获/目录收录、点击选草稿、回执与恢复；外部传输用合成目标。 |
| D：统一验收 | 包含本收据的 `test(host): verify the integrated panel and packaged domains`（父提交为 C） | 64/64；Debug、Release 开发包均从成品内执行离线资源检查。独立 Host 模式 49/49，Debug 打包通过。 |

[逐阶段实际变更文件](changes.txt)。完整 D SHA 可由 `git log -1 --format=%H -- engineering/verification/D-acceptance.md` 取得。环境：arm64，macOS 27.0 (26A428)，Apple Swift 6.4，Command Line Tools。整合包二进制及 plist 最低系统为 26.0；独立 Host 为 14.0。这是部署下限，不是对所有这些版本的实机验收。

| 验收项 | 操作及证据 |
| --- | --- |
| 双模块同时工作 | 在同一 Host 打开两段合成文字与三张长宽比不同的生成图像；使用原 SaytileStore 及已存在的测试 Riftlet 库。展开托盘、编辑文字、单独停用任一模块，另一模块内容/队列顺序保持。注册表与界面共享同一领域对象。 |
| 语音与恢复 | 合成的本地识别结果经过上游 LocalCandidateIngress、真实入库和发布通知，在没有设备或轮询的空闲面板显示。声音状态事件使用测试输入，覆盖讲话结束回待命和五根按振幅变化的竖条。原库区分修改草稿与用户选定文字；停用等待写入，重启可继续或丢弃草稿。强制语音资料库打开失败，两次退化都不打断已连接托盘；解除临时故障后原地恢复。 |
| 托盘与恢复 | 上游导入器/缩略图/监听器/SQLite 使用生成素材和临时目录。在上游导入器已持久化媒体、尚未写入 SQLite 时注入中断；显式重连用同一个导入日志恢复一条资产，再次重连 ID 不变，源文件字节不变。保存的资产 ID、比例和顺序在重连后相同。无回执不宣称成功，保留原操作；依照上游独立文件输入策略，重启不会把历史未确认操作变成新的附加授权。新增用例：目标解析中「隐藏→重新显示」不能重放旧点击，队列仍为 pending。转移协议测试替换的是外部目标；没有打开真实网页、上传或发送。 |
| Spaces 与隐私边界 | 普通装配使用不支持真实观测的 provider；即便选择三屏诊断，正式总线无桌面快照，切换和激活请求均被拒绝。配置不含转写、草稿或截图 ID；重启恢复摆放、隐藏和启用偏好，不恢复收音、自动化授权、监听或资料库连接。 |
| 隐藏窗口和视觉 | 实际无标题非激活面板，合成屏幕 1920×960 pt，面板 240×960 pt。两张 2× 离屏图可见真正的文字、复制/状态按钮、按原比例摆放的缩略图、展开的四键行及未知归属说明。窗口始终隐藏、非 key/main。渲染在浅色中性底上合成，未读取桌面像素，不验证真实玻璃材质。 |
| 成品验证 | Debug、Release 均以同一脚本打包：可执行文件签名、字节对比、plist、领域资源对比；成品以 `--verify-bundled-resources` 在 NSApplication 初始化前运行 Saytile 的原样本哈希校验和 Riftlet 的当前/历史脚本加载器。不启动 GUI、打开生产库或调用服务。独立 Host 单独使用缓存及输出目录。 |

**验收中修正的实际问题**

- SwiftUI 子区域靠 offset 定位，父 ZStack 原先只按最高子区域裁剪，导致下方提示及可选模块栏可能被裁掉。保存的失败回归在预期区域测得 0 个文字墨点；现以整个面板裁剪，离屏像素断言及目视检查均通过。
- SwiftPM 测试用包名可用，但上游 Riftlet 在真正的 .app 中要求自己的资源包名。已按原加载器契约打包，加入成品读取检查；早期阶段的字节对比本身不足以发现这点。
- 修复语音文本更新晚于短时轮询、停用时编辑草稿未落库、延迟开库失败未反馈到注册表，以及隐藏后旧点击可能重新有效。初次故障和修复前的原始检查保留在本地忽略目录。继承的 SwiftPM native 测试引擎弃用、CLT 链接搜索路径和上游 Swift 5 CALayer Sendable 警告未作静默处理。

**未做与下一步。** 未打开可见 Nearpane 或外部 Chrome，未申请系统权限、录制麦克风、读取生产队列/转写、迁移数据、替换已安装应用或调用收费 API。未验证长期常驻能耗、物理多屏应用焦点、真实文字输入准确性、系统截图选择、磁力动画或真实浏览器回执。云端默认关闭，本版未接管 Saytile 的账户或其云配置；如进入云端验收，先接入明确选择的合法配置与用量授权。Riftlet 当前是独占原队列；并行运行两个读写所有者需要上游共享接口。本轮未修改上游。后续现场验收应在单次约定的隔离会话中覆盖无抢焦点、收音→待命、生成截图→指定草稿（不发送）及恢复；真实 Spaces 仍须独立 P1 门禁。当前没有必须由用户当场解决的权限问题。

版本边界：执行起点工作区干净，GitHub 工程分支与起点一致。收尾再次只读查询 GitHub：工程分支已前移至本轮 A 提交，为当前工作的祖先；main 仍为 `f3d8b3d3a9fd67b04e0c663e08472d81adb7bb44`，未发现分叉。没有执行 Push、Merge 或更改 main。同步仍由 GitHub Desktop 完成。

复核命令（均不显示应用窗口）：

```sh
NEARPANE_RENDER_FIXTURES=1 scripts/test.sh
scripts/build-app.sh debug
scripts/build-app.sh release
NEARPANE_FOUNDATION_ONLY=1 scripts/test.sh
NEARPANE_FOUNDATION_ONLY=1 scripts/build-app.sh debug
```

原始日志、哈希对应的二进制和 PNG 在忽略目录 `build/`，不进 Git。各开发包仅验证本地可执行文件签名，未经分发签名、公证或生产安装。

成品内的 Mach-O 取出后严格验证签名通过；对整份 .app 执行 `codesign --verify --strict` 不通过（没有完整资源封印）。本次不据此声称可分发或通过 Gatekeeper。

最终 SHA-256（根目录相对路径，失败检查也保留）：

```text
81505bb2bb871d449ff807b146ac507a1752e7837c435b9057b918304b0847cb  build/verification/D-final-integrated.log
dfcf7cf5db89b8b8c5f6444a0f1f5984b127cef8c4afdc9b5c9196eacb70f05b  build/verification/D-final-debug.log
96dd0be7c68e9702a9c3fd16dd0d74d81632b66c8e4183d57ae6593a617009a8  build/verification/D-final-release.log
11130d9f0503c94f3de46056e11c079775cd01171c5d4a9c8c7deb07cddc2af5  build/verification/D-acceptance-foundation-tests.log
0c9df71d7b5ec18218ae075380af573ee9a60181f6a1511bb51362921ebe91f2  build/verification/D-acceptance-foundation-metadata.log
a2ab49e523bfeb099c24453b4e7428cfb0d9b6ae86cf0c4df892cdcbb6d9ad14  build/verification/D-hidden-clipping-regression.log
7102e3553f37fa78fbc5d41e245acf4c917da8ab7788f1d65ba9485398392c18  build/verification/D-bundle-seal.log
62496f8cdcebac04fbd953bb31a1949d4be970c68a4a7aae2d0152f2e7958c70  build/verification/hidden/host-collapsed.png
a516567905402d3f00d7e8ff46253677367ae3d90d17fe2d4e84ca0bc68b6e84  build/verification/hidden/host-expanded.png
f633446da96c87775bc37dce636951fd56123dd57822b87063ae553c5c70bdca  build/debug/Nearpane.app/Contents/MacOS/NearpaneHost
d86ca2b01ce0d55f559ca2e25ee25c0a1a4eb80d6b6c4ffc77c47a9872ecb6aa  build/release/Nearpane.app/Contents/MacOS/NearpaneHost
```
