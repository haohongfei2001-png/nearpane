# LyricTile · 当前状态

2026-11-27，北京时间。独立 macOS 软件；分支 `codex/lyrictile-standalone-20261126`，PR #17。

## 当前状态：真实歌曲自动取词连续两轮通过，恢复Music列表播放上下文后固定候选

- 最新 **CI48 / build48 / `89892d3605bcaa2a323422b2acd5aa64c626f65a`**：[运行](https://github.com/haohongfei2001-png/nearpane/actions/runs/46019565695)。原生编译、102项测试、App/helper加载、ZIP/实际挂载DMG完整性通过。普通App在线链路与网易18项通过；Music在next项未切到B，QQ验收把未知→真实新暂停锚误判为继续走时，workflow失败原样保留。
- **真实歌曲在线链路在CI47与CI48均通过**：[CI47已归档原件](Documentation/Verification/2026-11-27-release-candidate/ci47-online/README.md)。两轮实际Music均播放官方Code Monkey原MP3，原tags/189.309秒/文件SHA/真实ID核对；普通App从空缓存自动取得LRCLIB332580、54cue的lyricsfile token文档。CI48启动至自动缓存观察1.474秒，两个不同原生当前句AX hash与实际Music2154→2388ms、10075→10290ms一致，中间为真实seek。临时音频/歌词已清理、原设置恢复。仅一首英文样本，不扩大为逐字精度或全曲库准确率。
- **Music1.7完整两曲24项最近通过为CI46**。CI48真实导入由count1→2，两份SHA/ID/路径正确；首次欢迎、识别、本地歌词、seek、CGEvent pause/leave、隐藏与恢复等前17项通过。第18项next实际dispatch_attempted_unconfirmed，仍为A；见[原件](Documentation/Verification/2026-11-27-release-candidate/ci48-harness/Music/README.md)。本提交只将测试启动从单曲play恢复为此前已通过的play testPlaylist，保留有界真实current读回、全部24项及新的文件核验；单曲queue仅是推断，不改写为已证实根因。
- **QQ11.11.1/73285最近完整18项为CI47通过**。CI48先正确拒绝paused/rate1旧63s锚（position=nil），约0.922秒后收到新timestamp、缺省rate、64s真实暂停锚，normalized/UI为64000且后续两次保持。旧验收捕获nil后要求一直nil，导致第13项误拒。本提交只修验收：严格核实同源新锚，并再观察1秒冻结，保留旧rate1保护和原300ms阈值；不改生产时钟。
- **网易云3.1.14/3459在CI48真实18项全部通过**：[原件](Documentation/Verification/2026-11-27-release-candidate/ci48-native-baseline/NetEase/README.md)。本轮实际重现paused/rate1仍携带旧64s/同timestamp，归一化正确为nil/unavailable；恢复后真实65.109614s新锚与原文档恢复，静默cue8→20/源166249ms匹配。CI46累计下载超时、CI47 TLS失败的记录仍保留；它们不再是网易当前最近实测。

## 原生界面、网络与资源

- 欢迎页原400×2157pt缺陷已修为**400×360**，设置**450×620**。中英×深浅四组合、五个欢迎区域的边界/不重叠通过；12个原生1×原创布局场景，长句/英文/hover/紧凑态无新缺陷。
- CI44同PID/同window在light/dark/busy三种真实壁纸的WindowServer截图已逐图、原像素与局部放大复核：文字清晰且内框像素一致，恢复原桌面/QQ窗口成功。仅light app×三壁纸×1×；不是全显示比例资格。
- CI48逐行采样：网易 **1.919%**单核CPU/RSS中位 **95.70MiB**，60.450秒；空闲121.121秒 **0.132%/54.84MiB**。本轮Music/QQ未到性能阶段；同正常运行实现此前Music CI46 **2.083%/83.28MiB**、QQ CI47 **1.931%/92.37MiB**独立标注。逐行仍高于1%参考，不为微小差异继续调优。
- CI48真实LRCLIB元数据探针：中文3/3、英文3/3同步文档，321–623ms；纯音乐正确，现场20/缺时长21候选，不存在曲目为not_found。7/7缓存及同进程离线repository重建hash一致、零新请求。与实际歌曲在线链路分开，不是全曲库覆盖或独立声学准确率。

## 发行准备与边界

- 官网中英产品/帮助/隐私六页已上线：[产品页](https://nearpane.com/lyrictile/)。main `6501f76`首页导航及页脚入口已在真实云浏览器点击验证。最终候选后更新同源截图和支持文案；正式下载仍关闭。
- 云端签名身份为0：**尚未Developer ID签名、公证或正式公开发行**。工程Release草稿自动化已对真实制品复核6附件，新增在线元数据也按原字节纳入；manifest仍disabled，最终成功且实质审核通过后才启用。
- 已公证build4来自`3e83b5c`；8小时、旧Music/QQ及2→4升级仅是该包历史基线。本机仅需原有签名/公证/Sparkle凭据、同一最终签名包启动与4→最终包升级核验，再按既有授权发布；不重跑云端矩阵或八小时，不生成新更新密钥。
- Spotify、商业曲库、独立声学逐字精度、物理鼠标、其他显示比例未扩大声明。第三方测试歌曲/歌词不打包或用于官网宣传；CC BY-NC不等于商业内容许可。
- 证据在 `Documentation/Verification/2026-11-27-release-candidate/`；最终覆盖本状态并填实 `Documentation/LOCAL_ONLY_HANDOFF.md`。本提交改动限于验收工具、真实输入回归和原件记录；正常运行的播放、歌词、UI与时钟逻辑保持不变。
