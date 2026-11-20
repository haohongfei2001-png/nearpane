# P3 回退

此阶段只增加托盘的来源/选区、浏览器能力和不可覆盖的操作记录。已提交的本地源码可以按阶段提交整体回退。若集成后需要回退，在 PR #15 的原生分支上反向提交该阶段，不改版本号，不切换网站分支。

既有 Riftlet 队列表、截图媒体、恢复日志、用户设置及 TCC 身份沿用。新增记录只使用私有子目录 `capture-attachment-evidence-v1/` 和前缀为 `nearpane-capture-attachment-v1:`、`nearpane-capture-attachment-pin-v1:` 的现有 checkpoint 键。回退代码可忽略这些数据，保留原操作和已花费的输入声明，避免重复投递。无需迁移队列、重置权限、清除证据或删除用户截图。

本阶段的本地验收未安装、替换或运行正式 App。未更改桌面、账户、浏览器日常资料、语言或权限。无需恢复日常配置。隔离运行产生的私有浏览器资料由对应子进程退出后清理，忽略目录中的本地原始夹具和脱敏报告可用于复核。

额外的四站写入资格仅存在于本地独立编译。集成分支若需回退该层，反向提交 Nearpane 源码 `1e5b1d7` 即可保留首轮 P3 行为。七文件 Riftlet 补丁和锁位于 `Dependencies/riftlet-draft-qualification/`。公开基础提交、上游默认分支和 `Dependencies/domains.lock.json` 都独立于该补丁。回退无需安装任何版本或调整 App、浏览器和权限。验收 JSON 可保留供追溯。
