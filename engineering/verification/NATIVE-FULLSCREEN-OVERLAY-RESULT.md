# 副屏真实全屏工具验收 · 2026-11-13

**PASS。** 在 macOS 27.0（26A428）的旋转副屏（800 × 1280 pt），签名隔离 Alpha 使用实际产品浮层完成一次语音工具展开和收起。全屏窗、Host、控件、操作和回读均属于同一受限会话。用户允许本次操作至北京时间 02:38，最后一笔现场收据出现在 02:35:45。

| 真实交互 | 独立读回 |
|---|---|
| 进入原生全屏 | 自建窗口 188386 从副屏普通桌面 4297 进入全屏 Space 4458。AppKit、AX、CG、窗口归属和两屏 current 均已核对。主屏 current 保持 1309。 |
| 打开工具 | 普通面板已隐藏。外部 AX 在状态条 188395 上唯一识别并按下打开按钮一次，随后在同一面板读到语音工具和关闭按钮。 |
| 收起工具 | 外部 AX 按下关闭按钮一次，随后在同一面板读回状态条及打开按钮。三个阶段均保留测试应用前台焦点，Host 没有取得 key/main 窗口。 |
| 退出与归还 | 同一全屏窗回到 4297 和原 frame。Host 收起浮层并恢复普通面板，Voice 和 Tray 实例未变，未产生录音、截图或附件输入。Host 正常排空并以 0 退出。校准窗与测试窗残留 0，系统被动回到原主屏窗口，同一 AX 焦点对象、进程代际及原 frame 已核实。 |

最终见证 UUID 为 `7B050DB4-70C4-456B-A3EF-025CEDE324C9`。控制器最终判定 `complete=true`，两笔操作均获 API 返回并有后续 UI 状态证明。受测 Host SHA-256 为 `7cc841ecdd18f189368ac340506854c2001df75a93d3c3b787f4027185edb407`。[系统收据](../../build/verification/native-timed-1113/7B050DB4-70C4-456B-A3EF-025CEDE324C9/result.json) · [控件、焦点、领域及退出收据](../../build/verification/native-timed-1113/7B050DB4-70C4-456B-A3EF-025CEDE324C9/host-result.json) · [原始样本指纹](../../build/verification/native-timed-1113/7B050DB4-70C4-456B-A3EF-025CEDE324C9/fingerprints.json) · [冻结文件清单](../../build/verification/native-timed-1113/overlay-retest/accepted.json)

**先前拒绝及修复。** 初次联验已成功显示状态条。打开前，控件助手未能确认唯一面板，停在 AXPress 之前。其时新一版快照的文件名在 Reader 完成写入之前就已可见。时间重叠可由原始文件核对，首次错误日志没有保存足够信息来断定当时有多少个 AX 候选。见证现在用私有临时文件收集 Reader 输出，成功后原子发布且拒绝覆盖已有版本。工具助手只在同一签包、进程、窗口号及副屏几何保持有效时，短暂等候 AX 发布；身份冲突会立即拒绝。另一场焦点校准曾读到 partial AX，在发起全屏前退出。现在先让 AppKit 处理焦点事件，再要求原有两次完整读回。[首次工具拒绝](../../build/verification/native-timed-1113/F911C1FE-024A-4F4C-BC90-96FCC2D0BE2C/host-result.json) · [部分 AX 读回](../../build/verification/native-timed-1113/90719730-4FE0-47CF-96F6-7D20D4310B6D/raw/snapshot-7.json)

WindowLab 20/20、浮层控制器 6/6 通过。新增回归覆盖写入中的快照不可见、旧文件防覆盖、空输出与失败清理。最终 Release 见证包签名及文件指纹通过。产品 Host 使用上轮已构建的修复版，个人 P5.7 安装未改动。[WindowLab](../../build/verification/native-timed-1113/overlay-retest/windowlab-tests.log) · [控制器](../../build/verification/native-timed-1113/overlay-retest/controller-tests.log) · [签封日志](../../build/verification/native-timed-1113/overlay-retest/freeze-settle.log)

副屏本次只有普通桌面 4297。三轮普通 A/B 往返为 0/3，跨空间移窗为 0 次。此次结论适用于上述系统构建、自建全屏窗口和隔离 Alpha 的语音工具界面。任意第三方全屏应用覆盖、真实录音及普通桌面切换均不在这项 PASS 的范围内。
