# Nearpane — 产品定义

**Nearpane 是苹果原生台前调度的替代产品，使用自己的 R4 平放真实窗口缩略图与交互界面。**

窗口调度的唯一现行产品、技术及证据入口是
[独立台前调度裁决](engineering/research/NEARPANE-INDEPENDENT-STAGE-DECISION.md)。
[R4 视觉权威](design/NEARPANE-VISUAL-AUTHORITY.md)继续生效。
实现状态与真实通过的范围分别记录，源码存在、编译成功或自身窗口实验均不表示产品已通过第三方窗口验收。

## 窗口与工作组

- 当前普通桌面的工作区域展示当前活动组的真实窗口；其他组进入真实隐藏 Space，并在 Nearpane 中显示原窗口缩略图。
- 点击缩略图恢复整组的原窗口、位置、尺寸、层级和选中成员的焦点。
- 同一应用的不同窗口可以分别归组；不同应用的窗口可以组成一组。支持合并、拆分与组内精确选窗。
- 黄色最小化按钮在 Nearpane 管理时将相应窗口收入 Nearpane，并通过其缩略图直接恢复；启动前已在 Dock 最小化的窗口不擅自改变归属。
- 每组属于显示器和原生普通桌面，隐藏 Space 不成为用户桌面，也不替代系统桌面的身份。
- 保留原生桌面手势、Mission Control、App Exposé、全屏、Split View 与点击空白桌面显示桌面内容。
- Nearpane 是唯一台前调度缩略图界面。独立调度期间苹果 Stage Manager 关闭，不使用原生条带跟随、Corner、壁纸覆盖或鼠标拦截来代替真实退场，也没有这些自动回退路径。

## R4 与伴随式工作台

沿用现有 R4 表面、真实窗口比例、每屏设置及其语音、截图、文件、便签与任务模块。保留既有资料的生命周期和恢复能力。
语音沿用 Saytile 的音频与连续文本模型；截图和文件沿用 Riftlet 的原件、暂存队列与草稿附加语义。附加内容不自动发送，录音仍由用户主动开启。

不为窗口调度新增必须记忆的快捷键或强制设置向导。普通切组保持原有窗口布局；历史的自动平铺、八窗扩容与双引擎模式不作为独立调度默认行为。复杂模块配置仍位于设置中。

## 工程入口

- [当前实现与验收状态](engineering/native-spaces/STATUS.md)
- [实现、候选与逐项证据](engineering/verification/independent-stage/README.md)
- [统一自动验收入口](scripts/acceptance/independent-stage/README.md)

旧产品定义原文保存在[历史归档](engineering/research/archive/pre-independent-20261126/PRODUCT_DEFINITION.md)。
其中 Native/Virtual 双模式、原生桌面导航、Corner 及旧自动布局路线仅供理解既有实现；有冲突时不得继续指导当前产品开发。
