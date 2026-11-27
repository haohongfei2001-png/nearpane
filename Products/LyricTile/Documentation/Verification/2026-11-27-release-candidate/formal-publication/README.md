# LyricTile 1.0.0 / build49 · 正式公开发行原件

**正式Release已公开，安装包、更新源和官网实际下载已核实。** 本目录记录发布结果；原生播放器、签名公证与安装资格分别保留在[最终验收](../final-acceptance.md)及[本机原件](../owner-mac-signing/README.md)，网页通过不替代这些资格。

- 正式tag：`lyrictile-v1.0.0-build49`；精确source：`b95b6f5ed7680cbde1427a4ed1a904bd5875e17b`。
- Release ID：**460855402**；`draft=false`、`prerelease=false`，7个附件均为uploaded。
- Release URL：[LyricTile 1.0.0 / build49](https://github.com/haohongfei2001-png/nearpane/releases/tag/lyrictile-v1.0.0-build49)
- published_at：**2026-11-27T16:52:36Z**；北京时间 **2026-11-28 00:52:36**。

正式feed/consumer提交：`ec93f1d35e701ecad4c9b237ee62dd2fbdfba0e0`。官网main提交：`0b761876a8335735bbefa3271a1096d705e4e744`；[Pages46037564049](https://github.com/haohongfei2001-png/nearpane/actions/runs/46037564049)成功。公开tag经Git读回指向同一冻结source，产品未因发布文档/网站更新而重编译。

## 公开文件与下载

| 正式安装包 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `LyricTile-1.0.0-49-arm64.dmg` | 4,439,015 | `a6813cbebc59ae465e215d2ab5053d7591bb0fef8e89644a1723f58ed6e58329` |
| `LyricTile-1.0.0-49-arm64.zip` | 4,029,734 | `4e2161d2598fb6194401f00c951d641070161943bbc4697d4b7eac3f15e10515` |

7附件均为uploaded。ZIP、DMG、SHA256SUMS和appcast四项实际匿名下载均HTTP200，字节/hash与已验包相同；校验文件覆盖两种安装包。其余附件的API元数据与digest保留在原件，不把4项匿名下载扩大为7项全部重新下载。

实际线上feed从已安装49配置的URL读取：1318字节、SHA256 `45c303ef043751dd9944eacc7f45e2227a14f6c0d9d99fdfc6e76d6ecae734c9`，与原签名XML完全一致。对该live XML及由它指定的真实匿名ZIP使用原产品密钥验签，分别exit0。验签不导出私钥，不修改播放器或用户数据。

## 原件索引

| 文件 | 内容与范围 |
| --- | --- |
| [release-api.json](release-api.json) | 实际公开API、draft/prerelease=false、发布时间、7附件的ID/字节/hash/下载URL |
| [publication-receipt.json](publication-receipt.json) | 正式发布回执；原附件保持不变 |
| [tag-reference-check.json](tag-reference-check.json) | 公开tag经Git读回为CI49精确源码 |
| [deployment.json](deployment.json) | 实际main网站提交与成功Pages工作流回执 |
| [anonymous-download-receipt.json](anonymous-download-receipt.json) | 四项匿名下载及校验；该阶段尚未检查live branch feed，后续独立记录见下一项 |
| [live-feed-receipt.json](live-feed-receipt.json) | 真实分支feed HTTP200、原签名字节、live XML与实际ZIP双验签exit0 |
| [browser-observations.json](browser-observations.json) | 正式中英产品/帮助四页与真实点击；此阶段记录下载已完成、hash待独立核对 |
| [browser-download-verification.json](browser-download-verification.json) | 后续独立读取浏览器实际下载完整DMG，字节/hash与公证包一致 |
| [website-provenance.json](website-provenance.json) | 正式官网commit、Pages run、3张浏览器图片的字节/hash及证据范围 |
| [formal-draft-assets.json](formal-draft-assets.json)、[draft-review.json](draft-review.json) | 发布前草稿附件检查的阶段原件；不改写为发布后的状态 |

三张正式网页原图：[中文页面](lyrictile-release49-zh.jpg)、[英文页面](lyrictile-release49-en.jpg)、[首屏](lyrictile-release49-hero.jpg)。它们是实际云浏览器截图；页面中的产品图片来自已注明的CI49原创原生布局夹具，不是真实商业歌曲或Mac壁纸照片。

## 浏览器验收与阶段边界

正式中英产品和帮助四页实际通过。产品页1363×936桌面视口无横向溢出，图片加载完成，下载CTA、版本1.0.0(49)及hash正确，候选提示隐藏；两个帮助页无横向溢出且下载指向同一确切DMG。实际点击中文下载按钮后取得完整DMG，再独立核对上表字节/hash。

[ci49-website](../ci49-website/README.md)保留候选期main `3ed378b` / Pages46029097621的六页实测，不能作为正式页面的浏览器记录。本次未重测内容未变的中英隐私两页，不把四页复核写成再次完整六页通过。较早浏览器原件中的“hash待核对”由后续独立回执完成，原件不回写。

播放器实际范围、CPU超过逐行1%参考、历史build4八小时、Spotify未实测、逐字精度及用户基线绑定为零等限制均沿用最终验收，不因公开发行扩大。当前没有必须交给Codex的本机发行步骤。PR17保持open draft及原base；承载正式feed的开发分支继续保留。
