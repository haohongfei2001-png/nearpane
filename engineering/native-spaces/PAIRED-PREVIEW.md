# 正式侧栏双窗预览取证

此验收在同一块屏幕、同一个当前普通桌面上，用两个标准 Field Notes 窗口各显示七种唯一色标。六次变化产生 12 个逐窗观测。两扇窗口的测试资料和 AppKit 用户目录均在本轮临时目录内。运行器要求正式 `/Applications/Nearpane.app` 持有隔离资料写锁。它不移动桌面、切换台前调度或修改侧栏设置。

## 运行

从原生工作树构建一次。`--preflight-only` 只读已安装 Host 签名、侧栏可见性、观察器现有权限和当前桌面的窗口数量。台前调度开启且侧栏不可见时，`result.json` 记录 `BLOCKED` 与 `sidebarUnavailableWithStageManagerOn`。已有普通窗口的桌面也会在创建夹具之前返回。

```sh
kit=$(scripts/acceptance/native-spaces/build-paired-preview.sh)
python3 scripts/acceptance/native-spaces/paired-preview.py "$kit" build/preview-preflight --preflight-only
```

在已经准备好的空普通桌面，用现有正式安装版的隔离会话运行。已在该会话中时可直接调用 `paired-preview.py`。`--expected-space ID` 可额外锁定准备好的桌面。每次应使用新的输出目录。

```sh
python3 scripts/acceptance/native-spaces/installed_profile.py build/preview-profile -- \
  python3 scripts/acceptance/native-spaces/paired-preview.py "$kit" build/preview-physical
python3 -m unittest discover -s scripts/acceptance/native-spaces -p test_paired_preview.py
```

## 读回和判定

- 系统窗口编号、进程出生时间与签名、显示器、普通桌面归属、Host 卡片 AX 标识及坐标共同限定采集。夹具窗口并排显示。每一批次前后均验证前后遮挡顺序、桌面成员、被采区域、进程与物理输入。运行期间重复取得独立的卡片位置证明。
- 两个源窗口分别只采中央 4×4 pt。一个单独的 ScreenCaptureKit 画面覆盖两张 Host 卡片中央之间、仅包含这两张受控卡片的窄条。只对其中两个 4×4 pt 区域分类。两条卡片记录共享同一帧、取样时段和可用的系统展示时间，不保存图像或页面标题。
- 两次连续观测确认一次特定颜色的变化。`latencyMs` 为观测区间的上下界。它使用最后一次旧色和第一次新色的时间为变化定位，系统提供更早的画面展示时间时放宽下界。按成功读到的变化计算 nearest-rank P50、P95、P99 和最大值，逐窗附样本数。每窗最多六个延迟样本，P95/P99 可能与最大值相同。
- `simultaneous` 列出每个阶段的同帧匹配次数。`MATCH`、`BLANK`、`STALE`、`WRONG_WINDOW`、`UNKNOWN` 分别保留。空白指有实际像素的受控色标范围呈中性或透明；采集服务无法给出有效图像时记为未知。颜色已更新但此前有连续空白的阶段另留 `consecutiveBlankSamples`。
- `PASS` 要求两个窗口的六次变化均有独立源与卡片匹配，每阶段至少连续两次确认两张卡片同帧匹配，且夹具清理成功。原生台前调度缩略图需要在独立、同等条件下另外测量，当前收据始终将该对照记为 `NOT_MEASURED`。
