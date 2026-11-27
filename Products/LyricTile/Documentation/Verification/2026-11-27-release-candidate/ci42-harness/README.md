# CI42：身份修复已证实；两个验收助手仍需修正

本轮源码与原始文件哈希见SOURCE.json。整体CI失败，不是最终合格候选。

QQ和网易云实际原创音频的识别、LRC导入、seek64秒、真实命令读回和歌词绑定保持均已通过；网易云前后两个原始source JSON证明UUID改变而fingerprint/generation/hash保持，面板仍192pt。原生CGEvent进入和离开均成功，Hover已实际出现。

暂停尚未发生：qq-pointer.json显示已定位同窗口内唯一启用Pause按钮，bounds为(905,178,30,30)、中心(920,193)。qq-hover.png实际Pause图标位于同一点（面板原点832,47＋图中88,146）。系统AX命中同一LyricTile PID和窗口，但SwiftUI返回AXStaticText代理；助手又要求按钮代理的CF祖先身份相同，故没有发送click。这不是播放器拒绝暂停。修正保留新鲜按钮几何、同PID/窗口实际命中和真正pause读回，将不稳定的AX祖先身份仅作诊断。此前CG矩形误拦也已查明：覆盖整个桌面的Dock layer20窗口并不阻止实际LyricTile命中。

Music已执行两曲队列准备和play，最终读回表达式把远程location属性直接嵌套进POSIX path，产生-1700类型错误；尚未进入普通LyricTile。修正先get实际location到局部变量，再在Music tell之外转POSIX path，仍须校验两份实际导入文件hash和当前persistent ID。不能将本轮记作Music产品失败或Music完整通过。

核心检查未全部完成，所以本轮没有真实逐行性能、实际壁纸变化或暂停时钟资格。下一轮只复验上述明确修复及既定完整流程，不重新设计界面。
