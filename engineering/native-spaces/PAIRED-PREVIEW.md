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
- 两个源窗口分别只采中央 4×4 pt。一个单独的 ScreenCaptureKit 画面覆盖两张 Host 卡片中央之间、仅包含这两张受控卡片的窄条。只对其中两个 4×4 pt 区域分类。两条卡片记录共享同一帧、取样时段和可用的系统展示时间，默认只保存观测数值。
- 两次连续观测确认一次特定颜色的变化。`latencyMs` 为观测区间的上下界。它使用最后一次旧色和第一次新色的时间为变化定位，系统提供更早的画面展示时间时放宽下界。按成功读到的变化计算 nearest-rank P50、P95、P99 和最大值，逐窗附样本数。每窗最多六个延迟样本，P95/P99 可能与最大值相同。
- `simultaneous` 列出每个阶段的同帧匹配次数。`MATCH`、`BLANK`、`STALE`、`WRONG_WINDOW`、`UNKNOWN` 分别保留。空白指有实际像素的受控色标范围呈中性或透明；采集服务无法给出有效图像时记为未知。颜色已更新但此前有连续空白的阶段另留 `consecutiveBlankSamples`。
- `PASS` 要求两个窗口的六次变化均有独立源与卡片匹配，每阶段至少连续两次确认两张卡片同帧匹配，且夹具清理成功。原生台前调度缩略图需要在独立、同等条件下另外测量，当前收据始终将该对照记为 `NOT_MEASURED`。

## 可分享的原始裁剪

在现有隔离会话里，给本轮私有 kit 补编只读取图工具，使用 `--witness` 保存资格已核实的原始资料。外层 `preview-workspace.py` 也可用 `--media-command` 在同轮收尾调用发布脚本。

```sh
scripts/acceptance/native-spaces/build-preview-overview.sh "$kit"
python3 scripts/acceptance/native-spaces/paired-preview.py "$kit" build/preview-with-media --witness
python3 scripts/acceptance/native-spaces/live-preview-media.py build/preview-with-media
```

`media/receipt.json` 分别列出可读截图、色标抽帧和短序列。可读截图在计时结束后取自正式 Host 的独立窗口。采集前后核对安装进程、隔离资料写锁、专用桌面成员、两个测试窗口及其空正文摘要、两张真实 AX 卡的窗口号和固定 Field Notes 标签。ScreenCaptureKit 的窗口滤镜仅包含正式侧栏这一扇窗口，排除子窗、光标和音频。系统以白色衬底生成该窗口的原尺寸图面，取证器只复制两张已绑定卡框内的像素，卡间留白。两张卡的图案必须匹配同时分别从两扇测试窗读回的实测色标。卡框、所属窗口、色标或物理输入发生变化时保留具体拒绝原因。这幅 PNG 记录窗口本身的渲染，屏幕最前方的遮挡情况不在本图的测量范围。单窗口截图的输入边界见 [Apple ScreenCaptureKit 文档](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/sourcerect)。

每个色标 PNG 保留一张卡中央的原始 8×8 像素。只在该批两源、两卡均有一致且完全不透明的测试色，并有前后两次实时卡绑定时保存。APNG 只使用连续的合格批次，至少包含一次变色，附逐帧时间和原始摘要。间隔缺读会中断序列。macOS 台前调度的原生缩略图缺少已验证的逐窗对应关系和同条件采样入口，对照保留 `NOT_MEASURED`。


## 双窗、原生目录与空桌面

Field Notes 由 Launch Services 以独立实例启动，使用临时 HOME。两扇窗口必须来自同一可执行路径、签名与进程出生时间，且被系统登记为普通应用。相邻无关窗口的进程和标题不写入收据。几何采样只读取这两个窗口和正式侧栏内绑定的色块，每次都验证实际遮挡。桌面选择和隐藏测试另需完整的受控成员清单。

双窗启动后，隔离 Host 的既有 `p0-window-audit-targets.json` 绑定这两个编号。`preview/host-window-audit/final-records.json` 保留正式 Reader、目录和呈现层实际给出的元数据。没有记录时会给出 `UNAVAILABLE`。预览计时、双卡实拍、隐藏预算和系统 A→空 B→A 分项输出，便于在缺卡时区分窗口归属、正式目录与像素读回。


计时采样在每张已核准的正式卡按钮内取中央 4×4 pt，避开 18 pt 标题栏。收据保留 AX 数值类型、识别到的状态、子元素几何与采样坐标。动态预览必须由同一正式面板帧中的两个不同色标及后续真实变化证明。单独的 `sourceReference` 只读取两扇夹具窗口。系统选择与隐藏预算分别按两次真实卡片身份读回、两条生产流及实际交付计数判定。

## 持续流呈现时间

`--preview-sampler streams` 为两扇夹具和正式侧栏各开启一个常驻 ScreenCaptureKit 过滤器，请求 60 Hz。两卡位于侧栏的同一幅采样窄条。两扇源窗的色标每阶段维持 3.6 秒，在原 sRGB 色值附近作 ±5 通道值的刷新，颜色识别使用原阈值。生产 Host 的缩略图仍由正式应用自行取得和显示。

`presentation-frames.jsonl` 保存三路各自的序列、SC 显示时间、样本 PTS、回调时间和同帧色块统计。只有位于受控身份与遮挡读回之间的 4×4 pt 色块才能留下 RGBA 范围与中位数。缺少 SC 显示时间的帧可另报 PTS。只有与 SC 显示时间实际校准过的 PTS 可以参与时延分位数。每次变化以独立源和卡片上的前一色及连续两次新色确定时间上下界。完整性、同帧匹配及精度分别见 `metrics`，普通轮询仍可选 `--preview-sampler polling`。

已归档结果可运行 `python3 scripts/acceptance/native-spaces/paired_stream_metrics.py <本轮的 preview 目录>` 复算；同时校验原始帧文件的 SHA-256。


常驻流的源读回限定于各自已登记的 Field Notes 单窗口。经验收确认的独立窗口 backing 中只读取中央 4×4 pt。若同一隔离签名 Host 的普通窗口遮住源，逐次保存该遮挡的身份与尺寸；此时测到的是夹具窗口自身呈现，而非覆盖物后的可见屏幕。任何其他源遮挡仍会中止。两张侧栏取样点每次都要求在实际显示器上无遮挡。
