# LyricTile · 当前状态

2026-11-27，北京时间。独立 macOS 软件；分支 `codex/lyrictile-standalone-20261126`，PR #17。

## 当前发行状态：真实播放回归待修复后复验

- **CI40 / build40 / `e3c64e364da6846dcc278cec7214cbd44583c73c` 真实QQ验证失败，不可发行**：[原始运行](https://github.com/haohongfei2001-png/nearpane/actions/runs/45988292487)。识别真实音频、紧凑态和本地歌词扩容通过，但seek后歌词丢失回到104pt。临时UUID处理漏了73285是强线索；本提交补入该已知build，保留真实元数据/canonical ID切歌分辨，并增加2项回归测试。下一轮用原始payload、fingerprint/generation、文档hash及TransportTrace共同复验，不能仅看actionMessage为空。
- CI36 欢迎页实际400×2157pt的问题已修复。生产窗口中英文×深浅色4组合均为欢迎页400×360、设置页450×620；欢迎页5个内容区域完整、不越界、不重叠。12个原生歌词布局通过且逐图复审。截图为1×，歌词面板使用明确标注的原创测试输入。
- 96项原生测试通过；生产App、helper、ZIP与实际挂载DMG内容/版本/build/源码/校验一致。云端签名身份数量为0，包为ad-hoc候选，尚未正式签名、公证或公开发行。
- CI40空闲121秒：单核CPU平均0.0992%，RSS中位54.34MiB。QQ60.8秒样本为1.481%/92.09MiB，但当时歌词已丢失，**不是逐行歌词性能通过**；修复后重新采样。旧8小时基线不重复套用。
- CI38的LRCLIB真实网络/生产repository探针：中文3/3、英文3/3返回同步文档，首读249–606ms；7/7文档缓存及同进程离线重建hash一致、零新增请求。纯音乐、缺时长/Live候选与不存在歌曲行为正确。仅元数据样本，未测独立音频错配率；最终轮结果单独归档。

## 正在完成的远程工作

- CI40已通过正常系统按钮授予一次性runner到Music的Automation，AX既有权限可用。Music脚本错误地假定单文件add总返回list，已修正为兼容track/list；欢迎页实际文本“Welcome to Apple Music”已精确匹配。仍未取得Music普通app通过结果，不直接编辑TCC数据库、不申请新辅助功能权限、不登录。
- 官方QQ11.11.1/73285已免登录播放原创WAV，24秒取到3个真实源锚点推进；普通app的上述丢词是真实失败。网易云3.1.14实际进入未登录首页但没有匹配音频，下一轮只做一次普通open-file重试；Spotify未登录测试。
- 官网6个中英页面已发布到 [nearpane.com/lyrictile/](https://nearpane.com/lyrictile/)，main提交 `7e0b2f8` / [Pages运行](https://github.com/haohongfei2001-png/nearpane/actions/runs/45985251945)。云浏览器实开6页，图片/导航/下载状态正常；截图为明确标注的CI38原生夹具。正式下载仍未启用。
- 最后英文提示已通过CI40编译；接下来增加真实原生指针进入/暂停按钮点击/移出，以及公开API设置并恢复临时桌面壁纸。仅在已有权限与实际环境允许时执行，不能用夹具或设置请求替代真实截图。独立候选Release草稿manifest仍disabled，最终通过后才固定同一源码、包和证据。
- 发行检查、build独立命名、真实更新签名验证、隐私和第三方/歌词来源说明已就绪。完成下一轮CI后覆盖本状态及最短本机交接。

## 不混用的历史与支持边界

- 已公证安装的1.0.0 build4来自 `3e83b5c`。它的8小时长稳、Apple Music/QQ本地播放和2→4升级仅是历史证据，不代表最新候选通过。
- 四个适配器存在不等于四个平台认证支持。首发按实际结果确定；不要求全平台、完美逐字同步或重复8小时测试。
- 只发现离线个人Mac与本机签名/公证/Sparkle配置，未操作个人设备。没有最新签名包时不以build4替代。

## 继续入口

证据摘要在 `Documentation/Verification/2026-11-27-release-candidate/`；执行入口 `.github/workflows/lyrictile.yml`；本机专属步骤 `Documentation/LOCAL_ONLY_HANDOFF.md`。按具体失败继续，不重复研究已确定架构。
