# Apple 原生缩略图延迟对照

**NOT_MEASURED。** 5.22（90）候选 `32b9f92` 的第二轮取得了两窗共 12 次 Nearpane 变色延迟。按原始逐帧账本的 SHA-256、三个滤镜的窗口号、来源和取样坐标复核，Apple 缩略图有效样本数为 0，延迟保留为 `null`。[原始测量](../physical-09/result.json) · [离线复核结果](qualification.json)

| 实机证据 | 实际确认的内容 | 可用于 Apple 延迟的样本 |
| --- | --- | --- |
| 同一普通桌面、台前调度关闭 | 两扇 Field Notes 源窗以窗口号和进程出生时间绑定；第三通道只包含正式 Nearpane 面板。带实际显示时间的合格完整帧分别为 1,424、1,415、1,414 | 0。[原呈现账本](../physical-09/presentation-frames.jsonl.gz) |
| 台前调度开启 | 同候选的 Host 两次读回均已让出窗口区域、生产流为 0。本轮租约另识别出两个 Apple 签名 WindowManager 离屏合成窗，均为 103 × 97 pt，位于相同坐标，实际读图为 0 | 0。[Host 系统状态](../physical-08/installed-stage-manager.json) · [租约和成员证据](../physical-09/lease.json) |
| 历史调度中心单窗试验 | 2026-11-13 的独立实机检查看到 `linkedFixtureButton=false`。当次没有确认证明系统按钮唯一关联自有 AXWindow 的关系。该试验与彩色双窗的时间和显示器均不同 | 没有原生逐窗色标及时间戳。[原始收据摘行](mission-observation.jsonl) · [当次探针](../../../../../scripts/acceptance/observe-secondary-space-controls.swift) |

ScreenCaptureKit 对 `SCWindow` 报告所属进程与自己的 CGWindowID。AX 的 `AXWindow` 表示控件所在的窗口，`AXLinkedUIElements` 如存在可提供显式关联。台前调度还可把应用组合显示。同一进程、几何位置、窗口数和两个不同测试色，均无法单独确定系统卡片所代表的原文档。[SCWindow](https://developer.apple.com/documentation/screencapturekit/scwindow) · [AXWindow](https://developer.apple.com/documentation/applicationservices/kaxwindowattribute) · [AXLinkedUIElements](https://developer.apple.com/documentation/applicationservices/kaxlinkeduielementsattribute) · [Apple 台前调度说明](https://support.apple.com/en-ie/guide/mac-help/mchl534ba392/27/mac/27)

缺少的一次独立观测需在相同硬件、刷新率和七组色标下，逐一确认 Apple 签名系统表面上的两块可见缩略图与本轮两扇文档的 PID、出生时间和 CGWindowID 的对应关系。每块取样区域和所属显示器、Space 必须在每段前后复核。Apple 的单窗采集会交付整个窗口；若系统把多个应用画在同一载体中，须能在像素交付前安全隔离，或在完全隔离且只有测试内容的 macOS 会话中验证。满足后，分别以源窗和 Apple 图块的实际呈现时钟记录逐窗变色区间；Nearpane 的原时钟和样本单独保留。[单窗口捕获边界](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/sourcerect)

仓库根目录可执行以下只读复核。命令核对解压后账本摘要，并在通道、滤镜、裁剪或窗口身份变化时退出；它只读取归档文件。

```sh
python3 scripts/acceptance/native-spaces/apple-preview-reference.py
```

历史摘行是 `build/verification/secondary-route-followup/b1451ff8-7f39-4e28-a285-621a490f2ceb/observe.jsonl` 的第 9 行，保留原字节。原日志的 SHA-256 为 `ef8d10edcf9f7c1d78c68acc0a66761a78ff940bf48168461bc1650f65fdc27f`。
