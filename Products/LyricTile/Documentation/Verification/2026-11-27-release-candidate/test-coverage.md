# CI38 · 云端验收覆盖与证据边界

本文件固定记录 CI38 的基线范围。后续新增的播放器回归、真实输入及切歌验收，以 [最终候选验收](final-acceptance.md)、[当前状态](../../../STATUS.md) 和对应原始记录为准，不将本页的96项或未运行状态当作当前候选结论。

核对对象：[CI38](https://github.com/haohongfei2001-png/nearpane/actions/runs/45983237023)，源码 `f966478b3ca31e6ecbc76690716226a362b15bb5`，候选 build 38，macOS 27.0.1 arm64。只核对已运行结果及相应测试实现；没有新增测试或修改生产代码。

## 计数与原始产物

下载产物的 `dist/evidence/test-results-swift-testing.xml` 有 **81 个 Swift Testing 测试记录**，`dist/evidence/test-results.xml` 有 **15 个 XCTest 记录**：合计 **96/96 通过，0 failure、0 error、0 skipped**。参数化测试在 XML 中按测试定义计数，例如 `productionViewFitsItsSurface(_:)` 的 12 个场景合为一个记录；96 不是 96 次真实播放器端到端验收。

| 模块 | XML 测试记录 |
|---|---:|
| LyricCore | 15 |
| LyricServices | 25 |
| LyricPlayback | 24 |
| LyricUI | 17 |
| TileKit | 15 |

原始佐证还包括 `dist/evidence/swift-test.log`、`native-smoke.json`、`layout/*.json` / `*.png`、`variants/*/native-smoke.json`、`real-music/cloud-music.json` 和 `idle/idle-check.json`。真实歌词服务结果另保存为本目录的 [live-lyrics-ci38.json](live-lyrics-ci38.json) 与[摘要](live-lyrics-summary.md)。这些路径均为 CI38 下载产物内的路径。

本次CI38审计时，测试 Swift 文件与其已测版本一致；之后新增的 `Tests/Fixtures/CloudAcceptance.json` 和后续回归测试不计入 CI38 覆盖。

## 用户目标对应表

证据层级：**单元/模型**是可控数据下的生产逻辑；**原生夹具**在 macOS 挂载生产 AppKit/SwiftUI 视图但输入为原创测试数据；**原生启动**运行实际候选；**真实服务**调用公网 LRCLIB。各层级不能互相替代。

| 用户目标 | 已通过测试 / 产物 | 已证明的范围 | 尚不能据此宣称 |
|---|---|---|---|
| 自动出现、暂停保留、无播放隐藏 | [PanelPresentationTests][visibility]：`pauseKeepsExistingControlsOnlyUntilInteractionEnds`、`startupPausedDoesNotAppearForAccessibilityControls`、`inactiveMetadataCannotKeepThePanelOpen`、`connectionOrAuthorizationStatusNeverCreatesAnEmptyPanel`；`native-smoke.json` 的 `idlePanelHidden=true` | **单元/模型**显隐状态；**原生启动**无播放隐藏；无歌曲原生夹具透明度低于 0.01 | 真实播放器开始/暂停/恢复后的完整窗口显隐链路通过 |
| 切歌与过期异步结果 | [PlaybackTests][playback]：`generationChangesOnlyForRecordingOrInstance`、`sparseMetadataRetainsIdentityUntilAConflictingRecordingArrives`；[RepositoryTests][repository]：`aLateNetworkResponseCannotReplaceANewerRecording`；[AppModelTests][model]：`failedTimingSaveCannotReportAnErrorOnTheNextRecording` | **单元/模型**切歌 generation、迟到结果和错误归属；不会用旧请求覆盖新歌曲 | 四个实际播放器连续切歌、跨播放器切换已经跑通 |
| 居中、长句换行、中英文、深浅色 | [PanelLayoutTests][layout]：`productionViewFitsItsSurface`（12 场景）、`coreTextUsesCenteredRowsAcrossScriptsAndWraps`；`layout/fixture-english-lyrics*`、`fixture-light-long-lyrics*`、`fixture-narrow-dark-long-lyrics*` | **原生夹具**宽度 176/208pt 的视图约束、CoreText 居中、长句视口与 hover 高度变化；中文、英文及额外脚本排版 | 所有显示比例、真实多屏或不同壁纸的实际观感。CI38 原生 smoke 报告为 1× backing scale |
| 歌词切换、逐字时序 | [TimelineTests][timeline]：`appliesSignedSourceAndPerDocumentUserAdvance`、`aHealthyUnmeasuredAnchorAllowsLinesButNeverInventsWordAccuracy`、`unknownEndsStayUnknownWhileDisplayCanHoldUntilNextCue`；[ParserTests][parser]：`ttmlKeepsWordTimesTranslationLanguageAndBackgroundOverlap`、`decodedQRCAndYRCPreserveAbsoluteWordDurations`；真实服务取得 3 个含 token 的文档 | **单元/模型**时间投影、token 选择和时序资格；**真实服务**能取得并解析真实 token 数据 | 实际音频逐字同步误差、高亮动画的全程视觉质量或逐字 CPU 达标 |
| 暂停、恢复、跳转 | [TimelineTests][timeline]：`pauseFreezesAndSeekRebasesWithoutNewGeneration`；[PlaybackTests][playback]：`readbackRequiresActualDesiredStateAndPreservesPausedSeek`、`readbackRejectsOldObservationsAndLostGlobalOwnership`、`seekReadbackUsesObservedRateAndTrackEnd` | **单元/模型**暂停不推进、seek 重建 anchor、命令读回必须符合期望状态与来源 | 真实播放器已接受并执行暂停/恢复/拖动进度。测试中的前后播放器 observation 是构造数据 |
| Hover 与鼠标交互 | [PanelLayoutTests][layout]：`productionViewFitsItsSurface` 中长句 hover 前后视口和中心断言；`pausedInteractionKeepsItsSurfaceWhenLyricsArrive`；`layout/*hover.json` | **原生夹具**显示控制层时的布局、主句中心稳定，以及暂停中歌词迟到不打断当前形态 | 指针真实进入/离开、按钮点击、滑块拖动、hover 动画时序通过。夹具明确固定 controls 状态且没有会话 lease |
| 欢迎、设置及首次权限说明 | [AuxiliaryLayoutTests][auxiliary]：`welcomeAndSettingsKeepTheirDesignedContentSize`、`oversizedMountedWelcomeFailsLayoutAcceptance`；四种中英文/深浅色 native smoke 产物 | **原生夹具＋原生启动**欢迎 400×360、设置 450×620；内容挂载、欢迎区域边界/互不重叠；2157pt 超高会被拒绝 | 普通用户完整首次安装流程、真实 TCC 授权弹窗操作已经通过。设置的低频折叠区域没有被这些断言逐项展开操作 |
| 多组件排列与位置资格 | [TileKitTests][tiles]：`testDefaultOrderAndOverflowDoNotIntersectOrLeaveScreen`、`testReorderWaitsForExplicitHideAndIndependentWindowAbsence`、`testPresentationRechecksGenerationInstanceAndPlacementUnderTheRegistryLock` | **单元/临时 registry**排列不相交、撤回确认、epoch/generation/实例/位置授权屏障 | Riftlet、Saytile、LyricTile 三款实际应用同时运行的可视排列已经通过；窗口可见 ID 在这些测试中是传入观察值 |
| 紧凑态收缩、歌词扩容、停止释放空间 | [TileKitTests][tiles]：`testCompactHeightReleasesGapAndExpansionWaitsForBothWindows`、`testPendingContractionWaitsForPausedInteractionAndStopsCleanly`、`testCustomOrderSurvivesCleanExitAndMultipleRelaunches` | **单元/临时 registry**192→104pt 回收 88pt、104→192pt 等待双方撤回、暂停交互延缓收缩、stop 删除成员并保留用户顺序 | 真实多应用窗口同时移动、显示器热插拔、完整应用退出/重启链路通过 |
| 网络异常、限流、串行请求 | [RepositoryTests][repository]：`rateLimitIsNotNegativeCachedAndRetryAfterIsEnforcedBeforeNextRequest`、`reentrantProviderCallsStaySequential`、`providerIdentifiesClientAndFallsBackFromInvalidDraftToActualLRC`；真实服务 13 个请求 | **单元/注入 HTTP**429 不写成未找到缓存、Retry-After 阻止再次请求、并发调用仍串行、无效 Lyricsfile 可退回真实 LRC；**真实服务**200/404 正常路径 | 实际服务 429/503、DNS/网络中断、网络恢复已现场验证。CI38 公网样本没有出现这些故障 |
| 重连与过期连接清理 | [RepositoryTests][repository]：`reEnablingOnlineLookupDoesNotReviveAnEarlierRequest`、`offlinePreferenceMakesNoRequests`；[PlaybackTests][playback]：`restartedMediaProcessCreatesANewSourceSession`、`wallClockJumpAndWakeRequireANewRemoteSourceAnchor` | **单元/模型**离线开关使旧请求失效、新请求可恢复；媒体进程重启形成新会话、唤醒需新 anchor | 真实网络拔插、整机睡眠唤醒、播放器崩溃后的自动重连通过 |
| 本地导入、缓存、清理和重新读取 | [RepositoryTests][repository]：`importsBindingsAndVersionSpecificOffsetsSurviveClearAndRestart`、`boundedAutomaticEvictionDoesNotEvictProtectedBinding`、`aLocalImportSupersedesAnInFlightLookupForTheSameRecording`；[AppModelTests][model]：`localImportSurvivesLateAutomaticResolution`、`localImportInvalidatesAnOutstandingVersionSearch`；[真实缓存摘要](live-lyrics-summary.md) | **单元/真实临时文件**导入与偏移保护、旧查询取消、清缓存不删用户绑定；**真实服务**7/7 文档二读及新建离线 repository hash 一致、零新请求 | 系统文件选择器的完整鼠标操作、应用/系统实际重启后的全部用户状态通过；测试名称中的 restart 是重建 repository |
| 持续运行与资源释放 | [PlaybackTests][playback]：`processDrainsBothPipesWithoutDeadlock`、`processTimeoutReapsBusyChild`；`idle/idle-check.json` | 真实子进程管道/超时回收；**实际候选无播放器空闲**约 120.70 秒、106 点，CPU 均值单核 0.191%，RSS 中位 55.16 MiB | 最新候选真实逐行/逐字播放 CPU 或八小时长稳。旧 build 4 的历史长稳不属于 CI38 |

## 真实播放器结果单列

`dist/evidence/real-music/cloud-music.json` 为 **BLOCKED**，原因是 Music 设置/权限阶段的 AppleScript 超时，且明确 `realPlayerTestStarted=false`。因此 CI38 没有真实播放器播放、控制或同步通过记录。上表的 96 项绿色测试、原生截图与公网歌词请求不能覆盖这一缺口；环境阻塞也不能直接标成歌词产品功能失败。

本次窄范围审计没有发现新的明确产品缺陷。以上未运行场景是验收边界，不能据此推断代码一定有问题，也不要求通过补写更多镜像测试来替代真实运行。

[visibility]: https://github.com/haohongfei2001-png/nearpane/blob/f966478b3ca31e6ecbc76690716226a362b15bb5/Products/LyricTile/Tests/LyricUITests/PanelPresentationTests.swift
[layout]: https://github.com/haohongfei2001-png/nearpane/blob/f966478b3ca31e6ecbc76690716226a362b15bb5/Products/LyricTile/Tests/LyricUITests/PanelLayoutTests.swift
[auxiliary]: https://github.com/haohongfei2001-png/nearpane/blob/f966478b3ca31e6ecbc76690716226a362b15bb5/Products/LyricTile/Tests/LyricUITests/AuxiliaryLayoutTests.swift
[model]: https://github.com/haohongfei2001-png/nearpane/blob/f966478b3ca31e6ecbc76690716226a362b15bb5/Products/LyricTile/Tests/LyricUITests/AppModelTests.swift
[repository]: https://github.com/haohongfei2001-png/nearpane/blob/f966478b3ca31e6ecbc76690716226a362b15bb5/Products/LyricTile/Tests/LyricServicesTests/LyricRepositoryTests.swift
[parser]: https://github.com/haohongfei2001-png/nearpane/blob/f966478b3ca31e6ecbc76690716226a362b15bb5/Products/LyricTile/Tests/LyricServicesTests/LyricParserTests.swift
[timeline]: https://github.com/haohongfei2001-png/nearpane/blob/f966478b3ca31e6ecbc76690716226a362b15bb5/Products/LyricTile/Tests/LyricCoreTests/LyricTimelineTests.swift
[playback]: https://github.com/haohongfei2001-png/nearpane/blob/f966478b3ca31e6ecbc76690716226a362b15bb5/Products/LyricTile/Tests/LyricPlaybackTests/PlaybackTests.swift
[tiles]: https://github.com/haohongfei2001-png/nearpane/blob/f966478b3ca31e6ecbc76690716226a362b15bb5/Products/LyricTile/Tests/TileKitTests/TileKitTests.swift
