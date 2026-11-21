# 当前桌面选窗的 Apple 原生对照

**原生速度对照 NOT_RUN。** 正式 5.22（90）`f7997a7` 的十次同应用选窗均有原始点击、实呈目标画面、目标编辑器按键以及夹具和文件读回。以鼠标按下为起点，十次样本的首个目标画面 P95 区间是 207.96–234.81 ms，第一条实收测试键 P95 区间是 846.50–855.22 ms。后一个区间包含验收程序等待、随后才提供测试键的时间。本包缺少当时的显示刷新率、减少动态效果设置和预先固定的键入时机；也缺少 Apple 对应点击。原生延迟、速度优劣以及合同 P95 差值均未取得。[逐次回放](qualification.json) · [正式安装和原始收据](../final-installed/manifest.json)

两个问题需要各自的 Apple 数据。旧双窗变色账本里，三个 SCK 通道归属于两个夹具源窗和一个正式 Nearpane 面板。独立观察曾见 Mission Control，收据为 `linkedFixtureButton=false`。从该账本可归属的 Apple 缩略图呈现样本共零个。[变色账本核查](../../5.22-90-active-display-previews/apple-reference/qualification.json) · [系统观察原行](../../5.22-90-active-display-previews/apple-reference/mission-observation.jsonl)

## 只读回放

```sh
python3 scripts/acceptance/native-spaces/native-focus-reference.py
python3 scripts/acceptance/native-spaces/apple-preview-reference.py
```

第一条在对照尚未运行时保留 JSON 并返回 2；确认较慢返回 1，完整通过返回 0。传入 `--product DIR --native DIR` 可复核两份独立归档。它校验 manifest、实际路由的按下/抬起、提交到显示器的逐帧时钟和物理叠放、目标编辑器的带标记事件、文件/AX/夹具三方摘要。历史单边样本单独列出。对照需要同一个作用中的夹具会话、启动代际、显示器和刷新模式、普通桌面 UUID、原窗几何及动态效果设置，计时从两个界面的选择入口均已可见时按下鼠标开始。打开 Mission Control 的耗时单独计量。

沿用 P5 的 20 次产品预热、5×20 次正式量测和 20 次原生参考。固定目标顺序和预先登记的键盘探针投递时机，以下发所在的实际显示刷新周期检查其可比性。按同一目标方向分别保留首次画面与真实输入的 P50、P95、P99 和最慢一次。较慢的尾部保留 FAIL，采样区间重叠时保留 UNKNOWN。另列合同“输入 P95 比同机原生增加不超过 150 ms”的结果。合同门槛与样本中的原生速度持平是两项独立判定。[验收合同](../../../../native-spaces/ACCEPTANCE.md)

## 真实环境的只读准入

在现有已注册双文档 P2 租约内，使用该会话持有的 `RegisteredRun` 和两个当前夹具摘要。普通桌面先查 `focus-reference-environment`。在主控已安排、同一租约的 Mission Control 可见期间可查 `apple-focus-reference`。

```python
scene = run.call("focus-reference-environment", {"digests": hashes})
tiles = run.call("apple-focus-reference", {"digests": hashes})
```

两种模式读取同一保护租约中的正式 Host、签名夹具、进程生辰、两个原始 AX 对象和两向 Space 归属。系统卡准入另核验运行中的 Apple Dock/WindowManager 代码签名、指定物理显示器上的系统分组和两个可见按钮。只有连续两次读到系统按钮唯一链接至指定原文档，且中心命中同一签名按钮，才记录 `LINKS_OBSERVED`。两次查询本身均不发输入、不读像素。新 kit 可用现有签名 builder 生成。

```sh
kit=$(mktemp -d /private/tmp/nearpane-d01.apple-reference.XXXXXXXX)
bash scripts/acceptance/native-spaces/build-marker-witness.sh "$kit" --pair-pointer
```

完整 Apple 点击/收键/实呈序列仍待取得。原生投递记录必须把按下与抬起绑定到同一代际、同一原件的 Apple 按钮，当次和整批前后需有独立环境读回。相同采样区域必须有开头源窗证据、真正到达的目标像素、相邻物理叠放证据和可换算的呈现时钟。若系统概览占用此区域、隐藏原件或没有逐窗 AX 关联，记录具体拒绝并停止该项。共享系统表面可能包含其他应用，现有验收只保留两个已登记文档的画面证据。此处没有实测可用的 Apple 原生点击采集器。
