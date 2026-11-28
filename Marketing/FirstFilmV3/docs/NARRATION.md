# 中文解说与声音处理

六句旁白依次解释：音乐与歌词、切到文件继续阅读、悬停控制、两个播放器来源、组合功能、截图后展开。全文和最终落点以`config/narration-zh.json`及`assets/audio/narration/mix-receipt.json`为准。

音色选用Qwen3-TTS通用预设Uncle_Fu，低而平稳的男声；0.6B版本不支持风格指令，本片没有伪称用指令精细控制了模型风格。使用中文短句、保留逗号停顿、逐句固定种子合成。

模型：`Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice`，固定revision `85e237c12c027371202489a0ec509ded67b5e4b5`。运行时`qwen-tts==0.1.1`、`torch==2.8.0+cpu`、`torchaudio==2.8.0+cpu`。CPU float32、SDPA，不克隆真实人物。

## 重新合成

在独立Python环境安装CPU版torch/torchaudio及qwen-tts0.1.1；使用Hugging Face的`snapshot_download`下载上述指定revision到工程外的模型缓存。然后运行：

```bash
python src/synthesize_narration.py --weights /absolute/path/to/Qwen3-TTS-0.6B-CustomVoice
python src/prepare_narration_mix.py
```

脚本在首次导入运行库之前设置`ORT_DISABLE_TELEMETRY=1`、`HF_HUB_DISABLE_TELEMETRY=1`、`DO_NOT_TRACK=1`及离线模式。初次尝试中，运行库默认遥测被自动审批拦截；后续采用官方运行时禁用项，全部旁白成功在本地已下载模型上生成。不是通过更换网络端点绕过拦截。

仅修剪首尾静音，留140ms呼吸边界；无变速、无变调。对白双声道目标−18LUFS，轻微高通及2:1压缩，歌曲在对白期间一般降低13dB，播放器名称一句降低18dB，进入220ms、恢复480ms。成片混音目标−16LUFS、真峰值上限−2dBTP。最终编码数值另列于验收报告。

## 可核验的范围

独立faster-whisper-small以中文、多语词汇逐一识别六句旁白（最终播放器句直接从完成的混音中核对），未把预期文稿作为提示。没有漏句或新增句。识别器将“切到”写成“切，道”、将“移入”写成“一入”；记录为同音识别差异，不能据此确认全部声调或人的主观听感。初稿中的英文播放器名称在混音后误识别为iPhone Music，降低音乐后仍不稳定，因此最终旁白改为“也能跟随 QQ 音乐。”。Apple Music与QQ音乐的名称仍完整保留在实际画面和大字来源说明中。最终该句混音复检得到“也能跟隨QQ音樂”，除繁简体及标点外一致。完整记录见`NARRATION-ASR-REVIEW.json`与`MIX-SOURCES-RECHECK.json`。

当前环境没有人的主观听审，不能把ASR或响度检查描述成已经试听通过。交付包含独立对白轨，便于确有听感问题时替换，不需重做界面镜头。
