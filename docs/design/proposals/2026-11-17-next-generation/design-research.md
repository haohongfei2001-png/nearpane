# 07 · 设计研究与采用理由

研究日期2026-11-17。目标是回答具体设计问题，范围限制为平台规范与三种直接相邻产品，不做无穷竞品列表。以下是设计推论，不是声称Nearpane已有同等功能。

| 来源 | 已核实的设计事实 | Nearpane采用的思路 | 本方案的区别 |
|---|---|---|---|
| Apple macOS HIG / Sidebars | 建议尊重窗口调整、直接操作、自定义、可访问性；用收纳控制层级密度 | 保留系统编辑体验、用户调尺寸、少层级菜单与可访问动作 | Nearpane是桌面边缘Host，HIG普通App导航sidebar不直接决定它的1/8外形或Spaces底部布局 |
| Unclutter | 文件、便笺、剪贴板组合在一个入口；面板能调整尺寸和关闭 | 共享入口、选择自己需要的能力，配置不压到常驻界面 | Nearpane已有语音和真实桌面调度，不能直接横向搬来三面板；采用一个主要工作页与稳定空间区 |
| Soulver | 文字编辑与计算合一，答案列跟随文本变化自动计算 | 算式应是可保存编辑的草稿，不需要传统九宫格键盘 | 用户要求按等号才显示、可取消结果，故采用显式求值与独立结果装饰，不照搬自动计算 |
| Dropover | 文件暂存货架主要保留原文件引用，可监控目录；拖出执行移动/复制 | 轻量收纳、清楚取用、目录事件触发展示 | Nearpane需求是实际持久保存，所以默认入库真实字节；不能照搬引用货架后宣称永久保存 |

## 从研究得到的具体裁决

1. 统一入口能够降低取用成本，但不意味着同时展示全部内容。共享工作页比给每个功能一个完整卡片更适合160–240pt宽度。
2. 自动计算适合数值笔记，但会干扰需要保留原式的表达。Nearpane把源文本、求值、结果展示分开，让用户可撤销结果而不损失表达。
3. 暂存与持久保存必须在数据模型中分开。外观相似的货架可能只有路径引用；此产品的FileStore必须拥有可验证字节。
4. 直接拖动分界线有明确效率收益，值得替代旧“全部只能去设置调整”的局部决定；同时保留高级精调与恢复，避免自动布局夺走用户控制。
5. 原生风格来自字体、控件、材质、焦点和系统行为的一致性。无需增加品牌Header、过多说明标签或为了丰富而增加多层玻璃卡。

## 来源

- Apple, Designing for macOS：https://developer.apple.com/design/human-interface-guidelines/designing-for-macos
- Apple, Sidebars：https://developer.apple.com/design/human-interface-guidelines/sidebars
- Unclutter, Features：https://unclutterapp.com/features
- Soulver, Getting Started：https://documentation.soulver.app/documentation/getting-started
- Dropover, FAQ：https://dropoverapp.com/faq
- 本产品原生视觉V2：https://github.com/haohongfei2001-png/nearpane/blob/1d7fc062b2b7e99ad56721c3fc012e3c48f4f4b0/design/NEARPANE-VISUAL-AUTHORITY.md

这些资料只用于设计与API证据。原型使用自制合成内容，不拷贝竞品截图、UI资源或歌词。
