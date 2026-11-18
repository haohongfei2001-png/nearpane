# Nearpane 5.21 build 75 实机结果

安装于 `/Applications/Nearpane.app`。独立签名核验及运行中 CDHash 匹配。该次验收的源码为 `49c7fce277c6b1ec5b736cee0de32f8c87bc8b1e`，Host SHA-256 为 `6e6ed002961b03bd22a5388cea0b499101c5cfa2dea09850126a4dac9bf44c20`。

| 项目 | 安装版观察与判定 |
| --- | --- |
| 库存和高亮 | 一块 1470 × 956 pt 的显示器。生产侧栏显示三个普通桌面及一个原生全屏行。四行身份逐一对应独立 WindowServer 读回，桌面 3 的高亮与 current=6 一致。 |
| 空间和迁窗动作 | 生产 helper 报告 ready=true、canSwitch=false、canMove=false。安装 Host 自报辅助功能和屏幕录制均未授权。未在个人桌面发起切换或拖动。 |
| 同一桌面点击 | 两轮隔离测试各使用一个新签名进程，分别只有一扇和两扇普通文档窗口。通过正式侧栏发起 2 次 AXPress，均返回成功。4 秒内均未取得目标窗口的 key/main 见证，精确输入判 FAIL。标记发送次数为 0。当前证据未确定单窗失败发生在哪个产品分支。 |
| 清理 | 两次均由测试进程正常退出。测试窗号全部消失，原前台、原 AX focused window 和 Space 均恢复。 |
| 隐藏开销 | 从正常菜单隐藏后，自第 2 秒至第 62 秒 7 次观测，零新增像素请求、零捕获中操作、零活动流；菜单恢复原侧栏。该样本运行于 Host 无录屏权限的条件下。完整 N01 尚待同机原生动作基准、授权后的像素流及进程树内存测量。 |
| 实拍 | 单窗过滤、源裁切后取得 120 × 34 像素的当前行标题“● 桌面 3”。最初两个独立取证器错误样本均保留，修正临时颜色的生命周期后取得实际图片。 |

[库存与高亮](../5.21-75-readback-01/manifest.json) · [生产能力](../5.21-75-capabilities/manifest.json) · [单窗点击](single-window/actions.jsonl) · [双窗点击](controlled-window/actions.jsonl) · [隐藏和恢复](hidden-budget/actions.jsonl) · [已核对的原生标题图片](../5.21-75-title-03/current-row-title.png)

该构建的专项状态为 PARTIAL。S01 的受控三桌面与空桌面证明、S02、S03、W01–W03、D01、V01、P01、R01、I01 均未达到合同门槛。实机仅有一块显示器，M01 的第二块物理屏及两种系统配置组合尚缺。L01、L02、C01、F01、R02 和完整的 N01 也没有本次合格样本。
