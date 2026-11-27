# LyricTile · 当前状态

2026-11-27，北京时间。独立 macOS 软件；分支 `codex/lyrictile-standalone-20261126`，PR #17。

## 当前状态：真实歌曲自动取词已通过，完成Music两曲导入脚本复验后固定候选

- 最新 **CI47 / build47 / `01d21fc5ba61161f5cbf54ee494ed13778921910`**：[运行](https://github.com/haohongfei2001-png/nearpane/actions/runs/46016001883)。原生编译、102项测试、App/helper加载、ZIP/实际挂载DMG完整性通过；QQ核心与普通App真实歌曲在线链路通过。workflow仅因Music两曲导入验收脚本失败而红，网易本轮因TLS握手超时BLOCKED，两者独立记录。
- **真实歌曲在线链路已通过**：[CI47原件](Documentation/Verification/2026-11-27-release-candidate/ci47-online/README.md)。Music播放官方Code Monkey原MP3，原tags/189.309秒/文件SHA/真实ID核对；普通App从空缓存自动取得LRCLIB332580，观察耗时1.528秒，lyricsfile token文档54cue。两次不同原生当前句AX hash与实际Music4140→4390ms、7617→7850ms一致，中间使用真实seek；前两次未匹配观察原样保留。临时音频/歌词清理并恢复原设置。仅一首英文样本，不扩大为逐字精度或全曲库准确率。
- **Music1.7完整两曲24项最近通过为CI46**：首次欢迎/Get started、原始两份不同WAV、seek/原生鼠标暂停、显隐恢复、next清旧词/收缩/第二曲扩容、previous回A自动恢复原绑定及静默切句。CI47脚本未在12秒内取得两份可读file tracks，普通LyricTile未启动；本提交修正真实曲目集合读取和逐次诊断，仍以文件hash/实际ID/时长/播放读回作硬检查，不改产品或24项断言。
- **QQ11.11.1/73285在CI47真实核心18项通过**：本地LRC、seek读回、CGEvent hover/点击暂停/移出、显隐/恢复、静默采样继续切句。遇到暂停raw rate1旧seek锚点时，归一化进度为nil/unavailable，UI显示“Paused”和--:--，不回跳。
- **网易云3.1.14/3459最近实测为CI45核心18项通过**，Sources/Resources/Package/Packaging的56个跟踪文件与CI47完全相同；不等于同一构建二进制。CI46累计下载90秒边界已改为150秒；CI47在TLS握手阶段超时，未进入客户端下载/原生验收，不继续扩大总时限。CI44 paused/rate1旧锚点756ms回退已修复，CI45实际rate0新65341ms正确保留，证据不混用。

## 原生界面、网络与资源

- 欢迎页原400×2157pt缺陷已修为**400×360**，设置**450×620**。中英×深浅四组合、五个欢迎区域的边界/不重叠通过；12个原生1×原创布局场景，长句/英文/hover/紧凑态无新缺陷。
- CI44同PID/同window在light/dark/busy三种真实壁纸的WindowServer截图已逐图、原像素与局部放大复核：文字清晰且内框像素一致，恢复原桌面/QQ窗口成功。仅light app×三壁纸×1×；不是全显示比例资格。
- CI47真实逐行采样：QQ **1.931%**单核CPU/RSS中位 **92.37MiB**，静默后cue8→21、源168098ms落在168000–176000ms正确区间；空闲120.734秒 **0.248%/54.83MiB**。本轮Music两曲/网易没有性能样本；CI46 Music **2.083%/83.28MiB**、CI45网易 **1.819%/96.02MiB**为同生产代码此前实测。逐行仍高于1%参考，不继续为小差异调优。
- CI47真实LRCLIB元数据探针：中文3/3、英文3/3同步文档，296–630ms；纯音乐正确，现场20/缺时长21候选，不存在曲目为not_found。7/7缓存及同进程离线repository重建hash一致、零新请求。与上面的真实歌曲链路分开记录，不是全曲库覆盖或独立声学准确率。

## 发行准备与边界

- 官网中英产品/帮助/隐私六页已上线：[产品页](https://nearpane.com/lyrictile/)。main `6501f76`首页导航及页脚入口已在真实云浏览器点击验证。最终候选后更新同源截图和支持文案；正式下载仍关闭。
- 云端签名身份为0：**尚未Developer ID签名、公证或正式公开发行**。工程Release草稿自动化已对真实制品复核6附件，新增在线元数据也按原字节纳入；manifest仍disabled，最终成功且实质审核通过后才启用。
- 已公证build4来自`3e83b5c`；8小时、旧Music/QQ及2→4升级仅是该包历史基线。本机仅需原有签名/公证/Sparkle凭据、同一最终签名包启动与4→最终包升级核验，再按既有授权发布；不重跑云端矩阵或八小时，不生成新更新密钥。
- Spotify、商业曲库、独立声学逐字精度、物理鼠标、其他显示比例未扩大声明。第三方测试歌曲/歌词不打包或用于官网宣传；CC BY-NC不等于商业内容许可。
- 证据在 `Documentation/Verification/2026-11-27-release-candidate/`；最终覆盖本状态并填实 `Documentation/LOCAL_ONLY_HANDOFF.md`。本轮新的修改限于验收工具与原件记录，生产代码保持CI45版本。
