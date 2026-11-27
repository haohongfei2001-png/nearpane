# LyricTile · 当前状态

2026-11-27，北京时间。独立 macOS 软件；分支 `codex/lyrictile-standalone-20261126`，PR #17。

## 当前状态：CI42已证明两播放器身份修复，验收助手修正后复验

- **最新实际验收是 CI42 / build42 / `791d0917a92120f6e518ed11dcd6573eedcd9bee`，整体FAIL，不可发行**：[运行](https://github.com/haohongfei2001-png/nearpane/actions/runs/45997411802)。98项原生测试（83 Swift Testing＋15 XCTest）、编译、App启动、helper加载、ZIP与实际挂载DMG完整性通过。
- 欢迎页从CI36的400×2157pt修复为400×360，设置页450×620；最新中英文×深浅色4组合及5个欢迎内容区域边界/重叠检查通过。CI41的12个原生布局PNG已逐图审核，无新的明确缺陷。它们是1×原创夹具，不代表真实鼠标或播放。
- **QQ11.11.1/build73285的跳转丢词已被真实数据证明修好**：同曲UUID改变但元数据/PID不变，规范化后fingerprint、generation、本地文档hash和192pt面板保持，seek读回确认、歌词cue正确改变。原生指针enter/leave和Hover现已通过；pause中心实际位置正确且命中同App窗口，但助手额外要求SwiftUI AX代理祖先相同而拒发点击。已把此不稳定代理关系改为诊断，保留新鲜唯一按钮几何、同PID/窗口命中、真实点击及播放器读回要求；暂停仍需复验。
- **网易云3.1.14/build3459已免登录播放原创WAV**；真实seek后同曲UUID变化导致generation1→2、歌词丢失。精确扩展到3459后，CI42实际UUID变化时fingerprint/generation/文档hash均保留，seek读回确认、cue3→8，修复已得到同源数据证明。保持canonical/alternate ID、实际元数据变化及未知build边界。
- **Music1.7的脚本改名失败可远程解决**：实际Start Listening和系统Automation Allow已成功；-50准确出在给刚导入WAV写name，不是登录或权限。CI42已去除写元数据并执行两曲队列，但最终读回远程location时嵌套POSIX path产生-1700。现显式get location后在tell之外转换，保留实际标题/持久ID/文件hash核对；真实next/previous及返回原曲本地歌词恢复仍需完成。
- 原始失败与修复因果证据在 `Documentation/Verification/2026-11-27-release-candidate/ci40-regression/` 、`ci41-regression/` 和 `ci42-harness/`；按字节保存源JSON/PNG与SHA，不把整体FAIL重标为通过。

## 资源、歌词与发行准备

- CI42空闲120.47秒：单核CPU均值0.14942%，RSS中位49.66MiB、峰54.92MiB。核心检查失败后没有进行逐行性能或壁纸采样。旧build4八小时基线不套用为新包结果。
- 真实LRCLIB/生产repository已取得中英文同步文档、纯音乐与候选/未找到结果；CI38明确抽样中文3/3、英文3/3、249–606ms，7/7缓存和同进程离线repository重建hash相同、零新增请求。最终轮另归档；不是独立音频错配率或整个曲库覆盖率。
- 官网六个中英页面已上线：[产品页](https://nearpane.com/lyrictile/)，main `7e0b2f8` / [Pages](https://github.com/haohongfei2001-png/nearpane/actions/runs/45985251945)。云浏览器逐页核对图片、导航和下载状态。当前宣传图为明确标注的CI38原生夹具，最终成功候选后更新同源截图和支持清单。
- 云端代码签名身份数量为0；包是ad-hoc候选，**尚未正式签名、公证或公开发行**。工程Release草稿自动化、精确build命名、校验、隐私/第三方说明、专用Sparkle公钥/feed已备妥；manifest仍disabled，成功后才固定同一run/source/build。

## 历史边界与最后交接

- 已公证build4来自`3e83b5c`；它的8小时、Apple Music/QQ本地播放和2→4升级仅是历史。不能代替最新候选。
- Spotify仍无已登录真实播放结果。首发只声明实际通过的路径；不要求四平台、完美逐字、全部显示器或重复八小时。
- 只发现离线个人Mac，未操作个人设备；本机专属项是现有Developer ID、公证和Sparkle私钥，以及同一最新签名包的升级确认。
- 后续覆盖本状态，固定最终候选，完成Release草稿与官网资料，填实 `Documentation/LOCAL_ONLY_HANDOFF.md`，不要把可远程修复的脚本/普通开发交给本机。
