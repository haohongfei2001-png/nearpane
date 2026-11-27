# LyricTile · 当前状态

2026-11-27，北京时间。独立 macOS 软件；分支 `codex/lyrictile-standalone-20261126`，PR #17。

## 当前状态：CI41发现的问题已定向修复，等待下一轮原生复验

- **最新实际验收是 CI41 / build41 / `1c87964c399f445ad4fe6a394cdf680907e43306`，整体FAIL，不可发行**：[运行](https://github.com/haohongfei2001-png/nearpane/actions/runs/45994575431)。98项原生测试（83 Swift Testing＋15 XCTest）、编译、App启动、helper加载、ZIP与实际挂载DMG完整性通过。
- 欢迎页从CI36的400×2157pt修复为400×360，设置页450×620；最新中英文×深浅色4组合及5个欢迎内容区域边界/重叠检查通过。CI41的12个原生布局PNG已逐图审核，无新的明确缺陷。它们是1×原创夹具，不代表真实鼠标或播放。
- **QQ11.11.1/build73285的跳转丢词已被真实数据证明修好**：同曲UUID改变但元数据/PID不变，规范化后fingerprint、generation、本地文档hash和192pt面板保持，seek读回确认、歌词cue正确改变。暂停尚未实际执行：指针助手在enter之前被CG窗口矩形遮挡判断拦住，不能据此声称完整播放通过。现改为系统级AX实际命中校验，并记录遮挡窗口身份，原生事件仍需复验。
- **网易云3.1.14/build3459已免登录播放原创WAV**；真实seek后同曲UUID变化导致generation1→2、歌词丢失。已将同一身份规范化精确扩展到3459，保持canonical/alternate ID、实际元数据变化及未知build边界，并扩充回归案例。下一轮核对同源数据。
- **Music1.7的脚本改名失败可远程解决**：实际Start Listening和系统Automation Allow已成功；-50准确出在给刚导入WAV写name，不是登录或权限。现不改元数据，使用实际标题/持久ID/文件哈希读回，增加两段原创音频临时队列，准备验证真实next/previous与返回原曲后的本地歌词自动恢复。
- 原始失败与修复因果证据在 `Documentation/Verification/2026-11-27-release-candidate/ci40-regression/` 和 `ci41-regression/`；按字节保存源JSON/PNG与SHA，不把整体FAIL重标为通过。

## 资源、歌词与发行准备

- CI41空闲120.77秒：单核CPU均值0.1408%，RSS中位55.14MiB、峰55.23MiB。核心检查失败后没有进行逐行性能或壁纸采样。旧build4八小时基线不套用为新包结果。
- 真实LRCLIB/生产repository已取得中英文同步文档、纯音乐与候选/未找到结果；CI38明确抽样中文3/3、英文3/3、249–606ms，7/7缓存和同进程离线repository重建hash相同、零新增请求。最终轮另归档；不是独立音频错配率或整个曲库覆盖率。
- 官网六个中英页面已上线：[产品页](https://nearpane.com/lyrictile/)，main `7e0b2f8` / [Pages](https://github.com/haohongfei2001-png/nearpane/actions/runs/45985251945)。云浏览器逐页核对图片、导航和下载状态。当前宣传图为明确标注的CI38原生夹具，最终成功候选后更新同源截图和支持清单。
- 云端代码签名身份数量为0；包是ad-hoc候选，**尚未正式签名、公证或公开发行**。工程Release草稿自动化、精确build命名、校验、隐私/第三方说明、专用Sparkle公钥/feed已备妥；manifest仍disabled，成功后才固定同一run/source/build。

## 历史边界与最后交接

- 已公证build4来自`3e83b5c`；它的8小时、Apple Music/QQ本地播放和2→4升级仅是历史。不能代替最新候选。
- Spotify仍无已登录真实播放结果。首发只声明实际通过的路径；不要求四平台、完美逐字、全部显示器或重复八小时。
- 只发现离线个人Mac，未操作个人设备；本机专属项是现有Developer ID、公证和Sparkle私钥，以及同一最新签名包的升级确认。
- 后续覆盖本状态，固定最终候选，完成Release草稿与官网资料，填实 `Documentation/LOCAL_ONLY_HANDOFF.md`，不要把可远程修复的脚本/普通开发交给本机。
