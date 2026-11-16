# Nearpane 下一代｜平台能力审查

核查日期：2026-11-17（Asia/Shanghai）。本文件是设计证据与工程准入条件，不是已完成集成的报告。

仓库基线由并行仓库审查确认：当前完整产品 `Package.swift` 的 macOS 门槛为 26.0，foundation-only 为 14.0。因此 EventKit 14+、Translation 15+ 不会提高现阶段完整产品的最低系统要求。P5.13(64) 的 `NearpaneManualInsertion.swift` 已包含用户手势锁定 PID/window/AX element/网页 document 和 `canSetSelectedText` 检查；新剪贴板/翻译插入应复用这条通路，不引入默认模拟快捷键粘贴。存在实现不代表全目标实机验收。

## 1. 证据等级

- **Designed**：已决定的交互、适配器和回退方案。
- **Implemented**：必须关联仓库文件和提交；本次文档研究不授予此状态。
- **Validated**：必须有目标 macOS、签名发行包、目标应用版本、操作录像/日志和实际结果；本轮没有 macOS 实机验证。
- “官方 API 存在”只说明文档层可行；不等于权限已获准、第三方适配成功或 App Store 可按相同能力分发。

## 2. 能力与产品承诺

| 能力 | 文档层结论 | 设计裁决与边界 |
|---|---|---|
| 提醒事项读写 | EventKit 提供正式接口，`requestFullAccessToReminders` 为 macOS 14+；提醒事项没有只写/只读授权档 | 本地待办开箱可用；用户连接提醒事项后，以系统记录为该来源的权威数据；按列表选择展示，拒绝权限不影响本地待办。[S1–S3] |
| Siri / App Intents | 可把 Nearpane 自己的动作提供给 Siri/快捷指令 | 提供“新增待办、打开笔记、保存文本”等 App Intent；不是替换 Siri、接管所有自然语言指令或读取 Siri 历史。[S4] |
| 自动剪贴板展示 | NSPasteboard 提供读取和 `changeCount`；macOS 15.4+ 已有访问行为 API，隐私提示是否启用须按发行系统验证 | 首次启用该模块才开始监测；识别 ask/deny/allow；拒绝后仅保留用户主动粘贴入口，不能后台反复触发提示。[S5–S6] |
| 原输入框插入 | AX 可查询焦点及文本，但目标可不支持、失效或超时 | 按目标应用建立验证名单；点击时重新核实目标。无法确认则复制，不盲猜另一个输入框；不自动发送消息。[S7–S10] |
| 选择文本后翻译 | 系统 Services 可接收所选文本；AX 读取依赖目标应用实现 | 默认侧栏“翻译所选”或右键服务；AX 不可读时提供复制后翻译。不要承诺任何应用划词都能自动捕获。[S7、S11] |
| 本地翻译 | Apple Translation 自定义 API macOS 15+；TranslationSession 文档明确本机处理 | 优先 Apple 本地翻译；先检查语言支持与模型安装；下载需系统许可；旧系统或不支持的语种给显式云端选项。[S12–S13] |
| Apple Music 当前播放 | `SystemMusicPlayer` 官方可用平台列表**没有原生 macOS**；`ApplicationMusicPlayer` 控制应用自己的播放 | Mac 适配器以 Music.app 实际 `.sdef` 字典为准，核验 Apple Events 元信息与控制命令；不能把 MusicKit 目录能力当成 Mac 当前播放器控制。[S14–S17] |
| 歌词 | MusicKit `hasLyrics` 是布尔标志，不是歌词内容接口 | 只在获准且实际可用的歌词来源存在时展示歌词；否则显示曲名/歌手。自有文本、用户提供的 LRC 等可作替代，需标来源；不依赖逆向私有接口。[S18] |
| QQ 音乐 | 本轮未取得可核验的官方 macOS 当前播放/控制/歌词 API 契约；官方开发者入口可访问但正文不可检索 | 标记“待验证”，不虚构已接入。检查安装版脚本能力/官方合作渠道；若无可靠接口只提供打开播放器，不呈现失效控制。[S19] |
| 播客 | Apple Podcasts 本身有进度、章节、字幕等 UI，不等于开放第三方读取 API | 展示节目名、章节、进度、继续播放；仅适配器声明支持时显示快退/快进/倍速。无时间轴来源时打开原应用；不把歌词式滚动套给播客。[S20–S21] |
| 下载集中 | Safari/Chrome 均允许用户指定下载目录 | 指引一次选择 Nearpane 收件目录，随后监听已授权目录；不静默篡改浏览器偏好。[S22–S23] |
| 持久文件 | 用户选择目录、security-scoped bookmark 是正式机制 | 保存实际文件才能称为持久保存；仅存路径/书签不是备份。一分钟到期只隐藏托盘引用，不删除文件；重启和磁盘卸载需明确恢复路径。[S24] |

## 3. 待办、Siri 与数据归属

本地待办与系统提醒事项用不同 repository/provider 和标识空间。界面可以一起查看，系统记录不得暗中复制成第二套本地待办。首次连接选择列表；关闭同步仅停止访问、保留本地非权威缓存，不能删除系统记录。系统侧更改通过 EventKit 变更通知触发重取；编辑前检查授权、记录存在性及变更，写入失败保留未保存草稿。删除、跨列表移动及重复规则先做本机可恢复验收。App Intents 与普通界面调用同一命令服务，避免 Siri 和侧栏生成两条记录。Siri 中文短语、锁屏/后台执行、首次权限未授予和不同系统语言都须验证；不要保证任意口语都能准确路由。[S1–S4]

## 4. 剪贴板与原目标插入：必须采用有限承诺

保存最近一个非 Nearpane 的可编辑焦点上下文，至少含应用/PID、窗口、AX 元素、选区、时间和目标类型；用户进入侧栏前冻结此次目标。**复制内容的来源应用不等于粘贴目的应用**，前台进程也只是线索，不能当成可信来源证明。点击内容时重新检查存活、焦点、可编辑性、受保护字段和权限；复用现有 `NearpaneManualInsertion` 的手势快照与 `canSetSelectedText` 门槛，允许名单内使用 AX 选区替换，不能覆盖整个文本字段来冒充插入。通路失败后显示“复制”，不自动转入 CGEvent/模拟快捷键盲粘贴。[S7–S10]

禁止写入安全文本框、无法辨认的目标或已经关闭/改变的网页表单；不得发送 Return。明确区分 `confirmed`（有接收证据）、`attempted`（已尝试但无法读取结果）、`copiedFallback` 和 `failed`。未确认时不自动重试，防止重复插入。若用系统剪贴板暂存，恢复旧内容必须考虑 `changeCount` 及异步读取；禁止固定计时无条件覆盖用户刚复制的新内容。

监测、短暂展示、持久历史是三种不同权限与生命周期。默认不开永久历史，不上传云端；启用后仍提供暂停、排除应用、清空和保留时长。忽略已知敏感来源及敏感格式，安全字段检测不能保证识别全部密码/令牌，因此不得宣传“所有敏感内容自动过滤”。历史使用受保护本地存储，日志不记正文。macOS 的粘贴板访问 API 从 15.4 可用，但 Apple 文档对隐私提示有预览历史；不能断言所有支持该 API 的系统都默认提示，需在实际支持的 OS 矩阵检测。[S5–S10]

## 5. 翻译与语言笔记

原文、译文、语言、模型/服务、时间、备注和来源链接存入独立语言笔记库；默认翻译不保存，用户点“保存”才形成笔记。失败不改原文。Apple 模型未安装、语言不支持、离线下载失败均保留原文并给单个下一步；**不静默切换云端**。云端服务使用用户选择的提供方、Keychain 保存凭据、发送前明确来源与内容；语音/普通备忘不得被自动送去翻译。质量需用同一套中英口语、界面、学术术语和长句样本比较，不能仅因“本地”宣布质量最佳。[S12–S13]

## 6. 媒体模块与分发路线

适配器必须声明 `metadata / transport / seek / rate / lyrics / chapters / transcript` 各自是否可用，界面只渲染真能力。歌词有来源时默认一至两行，悬停或键盘焦点出现控制；无歌词回到曲目信息。播客优先当前章节、已播时间和时点笔记。无可靠播放器时模块安静收起；演示原型必须注明歌词/曲目为示例。

`MPNowPlayingInfoCenter` 用于发布**自己**播放的内容，`MPRemoteCommandCenter` 用于接收控制**自己**播放器的命令，都不是读取/控制任意播放器的通用接口。[S20]

Apple 官方把辅助应用使用 AX、向任意应用发送 Apple Events 等列为 App Sandbox 受限活动。因此完整跨应用助手采用 Developer ID 签名与公证的目标发行路线；当前 Nearpane 仍为开发签名，正式签名、公证与干净设备验收待完成。不能承诺 App Store 沙盒版功能等价。Music.app Apple Events 需要核验 Hardened Runtime entitlement、用途说明、逐目标自动化权限和脚本字典；拒绝权限则只打开播放器，不借私有 MediaRemote 或绕过 TCC。[S15–S17、S25]

## 7. 文件与下载的工程准入

采用有所有权的文件存储与独立展示记录；导入完成并确认字节可读后才出现“已保存”。复制/移动语义必须显式，一分钟计时从成功入库开始；到期不删除、不清理原文件。目录迁移采用复制、校验、原子更新引用，失败保留旧目录；磁盘空间不足、断电、重名、软链接、文件包、iCloud 占位文件分别验收。书签失效重新授权；外盘离线显示原记录与“磁盘未连接”，不伪报文件丢失。[S24]

下载目录观察器过滤临时文件，结合重命名、文件稳定和可读状态判断完成；单凭两次相同大小不能证明浏览器下载完成。不抢移下载中的文件，不更改浏览器数据库。用户选定的下载目录与 Nearpane 管理库应有明确关系，避免重复导入和循环监听。[S22–S24]

## 8. Codex 技术验证门槛

1. 在仓库最低 macOS 与当前支持版本验证 EventKit 授权/拒绝/撤销，Siri 中文新增一次只生成一条；记录来源和实际系统同步行为。
2. 插入矩阵覆盖原生 NSTextView、Safari、Chrome、Edge、Electron、密码框、目标关闭、焦点改变、IME 组合文字。无证据不得标 Validated。
3. 开启粘贴板隐私测试环境，验证 deny/ask/allow、系统休眠恢复、敏感应用排除；观察期间不弹权限风暴。
4. Translation 验证语言未安装、下载拒绝、支持/不支持语言、离线与云端显式选择；记录质量样本。
5. Music.app/QQ音乐/Podcasts 分别检查实际 bundle 版本、脚本字典和权限，再决定能力开关；歌词不能通过存在 `hasLyrics` 验收。
6. 验证 60 秒隐藏、重启找回、目录迁移中断、磁盘离线与下载未完成。原有 Spaces、Saytile、Riftlet 回归单独保留，不能用新模块演示替代。

## 一手来源

- **S1** Apple, EKEventStore：https://developer.apple.com/documentation/eventkit/ekeventstore
- **S2** Apple, requestFullAccessToReminders（含 macOS 14 平台元数据）：https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoreminders(completion:).md
- **S3** Apple, Accessing the event store：https://developer.apple.com/documentation/eventkit/accessing-the-event-store
- **S4** Apple, App Intents 入门：https://developer.apple.com/documentation/appintents/getting-started-with-the-app-intents-framework
- **S5** Apple, NSPasteboard / AccessBehavior（macOS 15.4+）：https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum.md
- **S6** Apple, AppKit updates（2025 年 4 月隐私预览说明）：https://developer.apple.com/documentation/updates/appkit
- **S7** Apple, AXUIElementCopyAttributeValue：https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue
- **S8** Apple, AXUIElementSetAttributeValue：https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue
- **S9** Apple, AXUIElement.h：https://developer.apple.com/documentation/applicationservices/axuielement_h
- **S10** Apple, SecureTextField Subrole：https://developer.apple.com/documentation/applicationservices/kaxsecuretextfieldsubrole
- **S11** Apple, NSServices：https://developer.apple.com/documentation/bundleresources/information-property-list/nsservices
- **S12** Apple, Translating text within your app：https://developer.apple.com/documentation/translation/translating-text-within-your-app.md
- **S13** Apple, TranslationSession（本机处理声明）：https://developer.apple.com/documentation/translation/translationsession
- **S14** Apple, SystemMusicPlayer 平台元数据：https://developer.apple.com/documentation/musickit/systemmusicplayer.md
- **S15** Apple, ApplicationMusicPlayer：https://developer.apple.com/documentation/musickit/applicationmusicplayer
- **S16** Apple, Apple Events entitlement：https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events.md
- **S17** Apple, 应用脚本字典说明：https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/AboutScriptingTerminology.html
- **S18** Apple, hasLyrics：https://developer.apple.com/documentation/musickit/song/haslyrics
- **S19** 腾讯官方开发者入口（本次无可读 API 正文，不能据此宣称已支持）：https://developer.y.qq.com/docs/openapi
- **S20** Apple, Now Playing / Remote Command：https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter ；https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter
- **S21** Apple, Podcasts Mac 字幕：https://support.apple.com/guide/podcasts/pode3855ee98/mac
- **S22** Apple, Safari 下载目录设置：https://support.apple.com/guide/safari/ibrw1072/mac
- **S23** Google, Chrome 下载目录：https://support.google.com/a/users/answer/9310144
- **S24** Apple, App Sandbox 文件与持久书签：https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox.md
- **S25** Apple, App Sandbox 受限能力：https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox
- **S26** Apple, calendarItemIdentifier（全量同步后本地标识可能失效）：https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemidentifier
- **S27** Apple, calendarItemExternalIdentifier：https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemexternalidentifier
- **S28** Apple, calendarItems(withExternalIdentifier:)（候选可能为多个）：https://developer.apple.com/documentation/eventkit/ekeventstore/calendarItems(withExternalIdentifier:)
- **S29** Apple, AppIntent / perform（本方案不假设文档未建立的稳定调用ID）：https://developer.apple.com/documentation/appintents/appintent
