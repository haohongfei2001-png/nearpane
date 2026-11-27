# LyricTile · 当前状态

2026-11-27，北京时间。独立 macOS 软件；分支 `codex/lyrictile-standalone-20261126`，PR #17。

## 当前状态：生产修复已完成，修正两处验收工具后固定最终候选

- 最新 **CI45 / build45 / `59a4530302e592fc80040c955fffbba339aa3f89`**：[运行](https://github.com/haohongfei2001-png/nearpane/actions/runs/46009188167)。原生编译、102项测试、App/helper加载、ZIP/实际挂载DMG完整性通过；workflow失败来自新增在线歌曲脚本对有效token格式的误拒。**本轮Music两曲脚本还在导入阶段BLOCKED，不能只看步骤success记产品通过。**
- **QQ11.11.1/73285真实核心通过**：Music以外的真实播放器适配器、本地LRC、seek读回、CGEvent hover/点击暂停/移出、显隐/恢复、静默采样继续切句都通过。暂停raw rate1仍沿用旧seek锚点，归一化进度为nil/unavailable，UI显示“Paused”和--:--，不回跳。
- **网易云3.1.14/3459真实核心通过**：CI45暂停返回rate0的新65341ms读数，正确保留，不再回到64秒。CI44已保存paused/rate1旧锚点造成756ms回退的实际证据；已精确修复3459并加单元/原生断言。本轮没有重新遇到该rate1分支，不能声称它的现场负例已重现。
- **Music1.7最近完整两曲闭环是CI44**：原样两份不同WAV、首次欢迎/Get started、生产seek/原生鼠标暂停、显隐恢复、next切B清旧词/收缩与导入扩容、previous回A自动恢复原绑定全部通过。CI45因导入后保存的secondTrack引用在后续求值报-2753，未进入该测试；本提交只修有界取得真实file tracks及播放前读回，脚本错误改为FAIL，保持文件hash与产品断言。
- **真实歌曲在线链路已进入生产自动缓存，但尚未完成原生显示验收**：CI45实际播放 Jonathan Coulton 官方 Code Monkey MP3，原tag、189.309秒、原文件hash/当前Music ID均正确；普通App自动取得LRCLIB332580并通过raw/doc hash、真实ID与fresh-cache检查。服务同时提供优先级更高的lyricsfile token格式，脚本强制line造成误拒。本提交允许line/token并先保存安全格式元数据，仍必须验证两句不同当前歌词AX hash与真实播放器前后位置，不放宽来源或时间条件、不授予逐字精度。

## 原生界面、网络与资源

- 欢迎页原400×2157pt缺陷已修为**400×360**，设置**450×620**。中英×深浅四组合、五个欢迎区域的边界/不重叠通过；12个原生1×原创布局场景，长句/英文/hover/紧凑态无新缺陷。
- CI44同PID/同window在light/dark/busy三种真实壁纸的WindowServer截图已逐图、原像素与局部放大复核：文字清晰且内框像素一致，恢复原桌面/QQ窗口成功。仅light app×三壁纸×1×；不是全显示比例资格。
- CI45真实逐行采样：QQ **2.074%**单核CPU/RSS中位 **96.47MiB**，网易 **1.819%/96.02MiB**；静默后cue8→20，与165656/166773ms真实源区间匹配。空闲120.99秒 **0.157%/50.73MiB**。本轮没有Music性能样本；CI44 Music **2.312%/83.45MiB**仅作此前基线。逐行仍高于1%参考，不继续为小差异调优。
- CI45真实LRCLIB元数据探针：中文3/3、英文3/3同步文档，276–712ms；纯音乐正确，现场/缺时长保留候选，不存在曲目为not_found。7/7缓存及同进程离线repository重建hash一致、零新请求。与上面的真实歌曲链路分开记录，不是全曲库覆盖或独立声学准确率。

## 发行准备与边界

- 官网中英产品/帮助/隐私六页已上线：[产品页](https://nearpane.com/lyrictile/)。main `6501f76`首页导航及页脚入口已在真实云浏览器点击验证。最终候选后更新同源截图和支持文案；正式下载仍关闭。
- 云端签名身份为0：**尚未Developer ID签名、公证或正式公开发行**。工程Release草稿自动化已对真实制品复核6附件，新增在线元数据也按原字节纳入；manifest仍disabled，最终成功且实质审核通过后才启用。
- 已公证build4来自`3e83b5c`；8小时、旧Music/QQ及2→4升级仅是该包历史基线。本机仅需原有签名/公证/Sparkle凭据、同一最终签名包启动与4→最终包升级核验，再按既有授权发布；不重跑云端矩阵或八小时，不生成新更新密钥。
- Spotify、商业曲库、独立声学逐字精度、物理鼠标、其他显示比例未扩大声明。第三方测试歌曲/歌词不打包或用于官网宣传；CC BY-NC不等于商业内容许可。
- 证据在 `Documentation/Verification/2026-11-27-release-candidate/`；最终覆盖本状态并填实 `Documentation/LOCAL_ONLY_HANDOFF.md`。本轮新的修改限于验收工具与原件记录，生产代码保持CI45版本。
