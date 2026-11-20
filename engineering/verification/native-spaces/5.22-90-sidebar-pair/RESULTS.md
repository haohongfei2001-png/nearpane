# 同屏拖放与切窗实测

macOS 27.0（26A428），单块 1470 × 956 点的物理显示器。每次使用正式安装路径及独立资料，在已登记普通桌面打开专用签名 Field Notes 的 A、B 两扇文档窗。每次安装事务均恢复原 App、配置与桌面。

## 同屏分屏

签名构建 `203e34e` 保持 5.22（90）。在正式侧栏，拖动 A 的卡片到 B 卡的右半时，B 在左、A 在右；拖到左半时，A 在左、B 在右。边框均使用全局逻辑点。

| 动作 | 实际 A 矩形 (x, y, w, h) | 实际 B 矩形 (x, y, w, h) | 结果 |
| --- | --- | --- | --- |
| 拖回 A 本身 | (555, 392, 320, 193) | (585, 367, 320, 193) | PASS，自拖过程中及结束后均保持原位 |
| A 拖到 B 右侧 | (615, 33, 615, 923) | (0, 33, 615, 923) | PASS |
| A 拖到 B 左侧 | (0, 33, 615, 923) | (615, 33, 615, 923) | PASS |

两次有效排布均由 Host 报告 `pairVerified`，并分别得到两次互相一致的系统 AX 和 WindowServer 读回。相邻边界为 x = 615，侧栏占用最右 240 点。右拖在放开后 1.92 秒首次被独立读回为目标几何，左拖为 1.60 秒，读回时间含采样开销。[逐动作 JSON](binding-drag/pair-pointer.json) · [正式 Host 日志与恢复](binding-drag/protected-installation.json)

![右拖录屏最后一帧，B 在左，A 在右](binding-drag/right-drag-final.png)

无声录像保留两扇测试窗和不透明底色。它包含从初始重叠到最终并排的 46 帧，时长 3.22 秒。鼠标事件与生产侧栏归属另由时间戳和 PID 收件确认。[实机 MP4](binding-drag/right-drag-fixture-windows.mp4) · [帧与动作时间](binding-drag/right-drag-film.json) · [A 窗原图](binding-drag/paired-ordinary-window-A.png) · [B 窗原图](binding-drag/paired-ordinary-window-B.png)

## 入场失败及中间候选

| 试次 | 实机证据 |
| --- | --- |
| 旧版 `d81c458` 首轮 | 观察器记录了点击，未取得目标键盘焦点。该版发送器未保存时间戳与 Host 收件，无法归因。修正读取器后，旧版真实鼠标输入 10/10。[首轮](baseline/pair-pointer.json) · [受控复测](baseline-routed/pair-pointer.json) |
| `e3c4d16` 初版拖放 | 在正确面板收到 down、9 段 drag 和 up 后，两份窗的坐标都未改变，右拖 FAIL。[收件与几何](current-drag/pair-pointer.json) |
| `6c5b4a1` 面板入口 | 命中检查遇到系统光标层级，当时未能证明遮挡者身份，实际派发 0 次，BLOCKED。[入场读回](panel-drag/pair-pointer.json) |
| `7ad17dc` | 右拖到达生产操作，启动了同包签名控制器。旧验收器在放开后约 0.94 秒丢失卡片读回并清理，最终几何 UNKNOWN。独立聚焦试次在 Launch Services 短暂无法确认时结束，实际点击 0 次。[拖放](bounded-drag/pair-pointer.json) · [点击前拒绝](measured-focus/pair-pointer.json) |
| `203e34e` 的画面观察 | 10 次鼠标选择和唯一键盘标记通过，画面观察在读全桌面时中止。只接受真实可见目标帧，保留 UNKNOWN。[输入](binding-focus/pair-pointer.json) |

对旧版的独立鼠标复测，把全桌面库存检查收窄为真实采样区域后，10 次都收到了显示流，但 9 次无法确认固定尺寸色块，1 次缺少呈现时钟的前后见证。10 对键盘标记仍然全部正确。每份原始画面收据均已保留。[旧版同屏实测](original-display-focus/pair-pointer.json)
