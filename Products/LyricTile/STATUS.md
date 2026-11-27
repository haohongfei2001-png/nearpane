# LyricTile · 当前状态

2026-11-28，北京时间。HOLDSNOW独立macOS产品；开发分支 `codex/lyrictile-standalone-20261126`，PR #17。

## 当前：LyricTile 1.0.0 / build49 已正式公开发行

正式版本固定为 **1.0.0 / build49 / `b95b6f5ed7680cbde1427a4ed1a904bd5875e17b`**，[macOS CI49](https://github.com/haohongfei2001-png/nearpane/actions/runs/46024615269)整体成功。后续文档、官网和发行工具提交不改变这个已测二进制来源。[最终验收及关键原件](Documentation/Verification/2026-11-27-release-candidate/final-acceptance.md)集中记录精确范围、失败历史及复算。

- 原生编译、**105个XML测试case**（15+90；失败/错误/跳过均0）、App/helper加载、ZIP及真实挂载DMG完整性通过。
- **Music1.7：24/24**；两首不同原创音频的真实识别、本地歌词、首次欢迎、自动显隐、seek、暂停恢复、CGEvent鼠标、next/previous、收缩扩容及原歌词绑定恢复全部通过。
- **QQ11.11.1/73285与网易3.1.14/3459：各18/18**；真实官方客户端、无需账号的原创本地音轨、原生指针及同步通过，清理无残留。实际暂停旧时钟保护与真实新锚分开验证，原300ms门槛未放宽。CI48真实输入的nil→新暂停锚由3个测试函数/10执行场景回归，不冒充49现场重现。
- **普通App真实在线链路7/7**：Music播放Jonathan Coulton官方《Code Monkey》原MP3，原tags/文件hash/真实ID核实；空缓存约**1.382秒**自动取得LRCLIB332580/54cue文档。8次观察中2个不同原生当前句严格匹配，6次未满足门槛观测原样保留；不是即时seek、逐字精度或全曲库资格。音频/第三方歌词正文/歌词截图不分发。

## 界面、性能与覆盖边界

- 欢迎页 **400×2157→400×360pt** 缺陷已修。设置450×620；中英×深浅四组合及欢迎五内容区的真实边界/非重叠通过，原2157负例明确失败。12种原创原生布局及真实播放器截图已审，无新的可见裁切或控件重叠。
- CI49主机实际1×；最终同一签名包在用户Mac完成中英×深浅四组合 **2× native smoke**。这不是2×真实播放器全矩阵。CI49壁纸矩阵因桌面API未读回指定壁纸如实为BLOCKED；CI44同窗三壁纸历史截图独立保留。
- 最新空闲120.581秒：单核CPU **0.158%**、RSS中位 **55.13MiB**；各约60秒实际逐行播放：Music **2.007%/83.09MiB**、QQ **2.158%/92.77MiB**、网易 **1.679%/95.41MiB**。cue在静默采样后继续匹配真实源时间。逐行高于1%参考，不隐藏该差异或继续无必要调优。
- LRCLIB真实元数据探针中文3/3、英文3/3，339–597ms；7份缓存及同进程离线repository重开hash相符、零新增请求。网络429/重连等异常通过注入测试；不称整机真实断网或睡眠唤醒。
- 首发已测范围以[SUPPORT](Documentation/SUPPORT.md)为准：Music/QQ/网易的本地音轨核心路径，加Music单曲自动在线样本。Spotify、商业曲库整体、独立声学逐字精度，以及未实际覆盖的显示/多屏场景不作通过承诺。TileKit逻辑已测试，不称三款最终签名工具同屏实测。

## 正式包、本机安装与公开状态

- **正式49已完成 Developer ID 签名、App/DMG Apple公证及37/37发行检查**，Sparkle原产品密钥验签通过。[本机原件与范围](Documentation/Verification/2026-11-27-release-candidate/owner-mac-signing/README.md)。直接重签原CI49负载，未重编译；191路径、7个Mach-O/12个架构slice比较通过，差异仅限既定4项发行配置与签名/票据。
- 正式 ZIP：4,029,734字节，SHA256 `4e2161d2598fb6194401f00c951d641070161943bbc4697d4b7eac3f15e10515`。正式 DMG：4,439,015字节，SHA256 `a6813cbebc59ae465e215d2ab5053d7591bb0fef8e89644a1723f58ed6e58329`。它们区别于保留的ad-hoc工程候选。
- **真实Sparkle 4→49升级、最终签名包2×窗口smoke及普通启动通过**。最终 `~/Applications/LyricTile.app` 经LaunchServices正常启动，版本1.0.0/build49/source `b95b6f5ed7680cbde1427a4ed1a904bd5875e17b`，完整App树与公证DMG一致，codesign/stapler/Gatekeeper通过。
- 在实际Sparkle升级完成的检查点，原有2个持久文件与产品设置字节保留；基线 `bindings=0`、`adjustments=0`，因此没有把该结果写成“已有导入绑定/时间校准迁移”。原样build4备份留在本机；随后正常播放产生的新用户缓存、非测试Music曲目及暂停状态均保留，没有将最终整个Support恢复为旧基线，仅按明确测试ID清理自有测试曲目和列表。
- 工程草稿仍独立保留：Release ID460802999、draft/prerelease、6附件hash核对通过，verification ZIP持久保存213份原件及两XML；不用于消费者下载。旧build4草稿未改。
- 正式中英产品与帮助四页已在main `0b761876a8335735bbefa3271a1096d705e4e744` / Pages46037564049上线并实际浏览：1363px桌面产品页无横向溢出、图片加载、版本49及DMG hash正确；点击中文下载按钮所得完整DMG与公证包一致。候选期六页浏览器原件独立保留，本次未重复两页未变的隐私页。不使用仓库通用 `releases/latest`。
- **本机签名、安装、真实升级以及公开Release、下载/feed/官网同步和发布后核对均已完成，没有必须交给Codex继续的发行步骤。**
- 旧build4的八小时、2→4升级只属于历史包；本次4→49有独立实际结果，没有将短时回归写成最新包八小时或逐字长期资格。

### 正式公开记录

- 正式tag：`lyrictile-v1.0.0-build49`；精确source：`b95b6f5ed7680cbde1427a4ed1a904bd5875e17b`。
- Release ID：**460855402**；`draft=false`、`prerelease=false`，7个附件均为uploaded。
- Release URL：[LyricTile 1.0.0 / build49](https://github.com/haohongfei2001-png/nearpane/releases/tag/lyrictile-v1.0.0-build49)
- published_at：**2026-11-27T16:52:36Z**；北京时间 **2026-11-28 00:52:36**。

公开ZIP、DMG、SHA256SUMS与appcast四项匿名下载均HTTP200且与已验证原包hash一致。实际线上feed为1318字节原签名XML；XML及从该live feed读取的真实匿名ZIP均经原产品密钥验签exit0。[正式发布、公开下载与浏览器原件](Documentation/Verification/2026-11-27-release-candidate/formal-publication/README.md)保存各阶段独立结果。

正式feed/consumer提交 `ec93f1d35e701ecad4c9b237ee62dd2fbdfba0e0`。更新feed仍位于本开发分支 `Products/LyricTile/Updates/appcast.xml`；迁移更新源前保留此分支。PR17保留open draft和原Nearpane开发base，不合并、不删除feed分支；独立LyricTile发行已经完成。
