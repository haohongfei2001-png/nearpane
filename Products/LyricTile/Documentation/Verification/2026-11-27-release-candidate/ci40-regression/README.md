# CI40：真实 QQ seek 后歌词丢失

此目录保留失败原件，不作为最终候选通过证据。来源见 SOURCE.json。

QQ Music 11.11.1 / build 73285 在无登录的 macOS 27.0.1 上播放原创180秒WAV；生产适配器24秒取得3个真实源锚点推进。普通LyricTile在约26秒导入本地原创LRC后，文档来源local、cueIndex=3、面板192pt。seek至64秒后，歌曲仍播放，但documentSource为空、cueIndex=null、面板104pt；后续播放仍无歌词。前后PNG为同一实际应用的原始原生捕获。

原始JSON中有两处必须谨慎解释的单项PASS：`seek-updates-current-lyric` 当时错误地把null!=3算作换句；`seek-command-readback` 只依据位置及无actionMessage，没有要求底层TransportTrace确认。整体测试仍因hover高度和continued-playback失败而FAIL。后续验收已要求非空歌词、相同文档hash/歌曲身份、真实readback_confirmed，并且核心失败时不再开始所谓逐行性能采样。

73285未进入已有73284临时content UUID规范化路径，是与现象及历史证据一致的强线索。CI40没有导出seek后的原始UUID，故不能据此声称完整因果已经证明。候选修复扩展到已知73285，下一轮保存逐阶段原始payload与规范化identity确认。

同轮Music已通过正常系统Automation Allow按钮；尚未进入普通App验收，测试脚本误把add单文件返回的file track当作list，产生AppleScript -1728。该问题属于测试准备代码，不能算Music播放通过或产品播放器失败。
