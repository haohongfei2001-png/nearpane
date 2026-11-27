# LyricTile · 当前状态

2026-11-27，北京时间。独立 macOS 软件；分支 `codex/lyrictile-standalone-20261126`，PR #17。

## 当前状态：核心真实闭环已跑通，最后修复与性能回归中

- 最新完成的 **CI43 / build43 / `1301b9b3731f6037307430ec61c0ee87104d85ad` workflow成功**：[运行](https://github.com/haohongfei2001-png/nearpane/actions/runs/45999817063)。98项原生测试、App/helper加载、ZIP及实际挂载DMG的源码/版本/校验一致。原始数据深入审核仍发现QQ暂停旧anchor，故本提交修正后再固定最终候选，不能仅凭绿色标记收尾。
- **Music1.7真实免登录两曲核心PASS**：实际导入的两份不同原创WAV与输入hash相同；普通LyricTile首次欢迎→Get started→识别→本地LRC→seek→原生CGEvent hover/点击暂停/移出→隐藏→恢复通过。生产next切B后清旧词/收缩，导入B后扩容，previous回A自动恢复原绑定且未重新导入；23项原始检查通过。
- **QQ11.11.1/73285、网易云3.1.14/3459的真实单曲核心PASS**：原创WAV/本地LRC、真实进度、seek/暂停/恢复命令读回、实际鼠标进入/点击/移出、显隐与文档保持。两者临时UUID变化不会再被误判为换曲；真实metadata/canonical ID及未知build边界保留。
- **QQ暂停时钟缺陷本次修正**：CI43真实pause后raw playing=false但rate1，elapsed/timestamp仍是旧seek anchor，UI从64649回到64000ms。既有73284防护精确扩展73285，暂记进度不可用直至真实新anchor，不制造时间。新增单元及原生raw→normalized→UI检查；网易云rate0暂停读数正常。
- 欢迎页400×2157pt缺陷已修为**400×360**；设置**450×620**。中英×深浅四组合、五个欢迎内容区域的边界/不重叠通过；12个1×原创原生布局夹具已逐图复核。真实Hover原图也已查看，无明确新视觉缺陷。

## 最后一轮必要回归

- CI43真实逐行60秒：Music单核CPU2.564%、RSS78.63MiB；QQ2.454%/95.38MiB；网易2.023%/95.19MiB，均确有歌词持续播放。空闲120.94秒0.207%/54.84MiB。逐行尚高于1%参考目标，不能称达标。
- 已定位并移除隐藏控制区时每秒发布进度/整frame及同值isVisible的重复刷新；按真实主唱/伴唱边界和原anchor剩余寿命唤醒，seek/新文档/偏移后重算。Hover、token渲染、播放器健康轮询和同步资格不降。增加3项时序行为测试，原生静默采样结束还须证明当前句继续随真实源进度推进。实际收益由下一CI测量，不凭代码预判。
- 三壁纸矩阵此前受QQ窗口hide返回false阻塞，仅已有一张真实桌面图；没有把它算成壁纸通过。现改为实际可见性读回及可恢复AX最小化，并用真实AX命中排除Dock透明全屏CG矩形误拦。仍保存原壁纸/窗口状态并恢复；下一轮看真实合成截图。
- 真实网络与本地缓存探针已运行；CI38基线中文3/3、英文3/3返回同步文档、249–606ms，7/7缓存及同进程离线repository重建hash一致且零新请求。最终轮单列准确样本；不是独立音频错配率或全曲库覆盖承诺。

## 发行准备与边界

- 官网六个中英页面已上线：[产品页](https://nearpane.com/lyrictile/)。首页导航/页脚已加入独立入口，main `6501f76` / [Pages](https://github.com/haohongfei2001-png/nearpane/actions/runs/46001978476)。最终候选后更新原生同源截图、支持清单并再验公开页面；正式下载未启用。
- 签名身份数量为0，当前是ad-hoc候选，**尚未Developer ID签名、公证或正式公开发行**。6附件工程Release草稿自动化已用CI43真实制品离线逐字节校验；manifest仍disabled，最终成功run/source/build才启用。现有Sparkle公钥/feed沿用，不生成密钥。
- 历史已公证build4来自`3e83b5c`；8小时、Apple Music/QQ与2→4升级仅属于该旧包。最新签名包仍需本机原有凭据、最终签名包启动及4→最终包升级确认，不重复云端完整矩阵或八小时。
- Spotify未登录真实验证；商业曲库、独立声学逐字精度、物理鼠标、更多实际显示比例均未扩大声明。首发不要求四播放器或完美逐字。
- 关键原件与归因在 `Documentation/Verification/2026-11-27-release-candidate/`，其中`ci43-native-baseline/`保留本次三播放器闭环、暂停缺陷和修正前性能。最终覆盖本状态并填实 `Documentation/LOCAL_ONLY_HANDOFF.md`。
