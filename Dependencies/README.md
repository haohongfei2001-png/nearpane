# 构建依赖

全量构建从 Nearpane 的单个检出目录开始。运行 `scripts/build-app.sh debug`、`scripts/build-app.sh release` 或 `scripts/test.sh` 时，解析器按 [domains.lock.json](domains.lock.json) 访问 GitHub 的 HTTPS 提交归档。目前两份归档可匿名读取。首次构建需要能访问 `codeload.github.com`。缓存完整后可设置 `NEARPANE_OFFLINE=1`。独立 Host 设置 `NEARPANE_FOUNDATION_ONLY=1`，可以直接在空缓存下离线构建。

| 领域和固定提交 | 文件数 | 选定内容 SHA-256 |
| --- | ---: | --- |
| [Saytile v0.18-beta.492](https://github.com/haohongfei2001-png/saytile/tree/012999c2018f591f3cf9a529e4c0ae81e7b81f21) | 121 | `5214893b076c8428c169289e80fbe1504bcb9c8a640a2de66b038eb6420d775f` |
| [Riftlet v1.0.3-zip](https://github.com/haohongfei2001-png/Riftlet/tree/189782dd943f5215da43539b30db27e482a78b3c) | 89 | `b45581cae27047a0e203222b2719ce9f37dc28c7476baa6205d6bd1a7e182f9a` |

SaytileKit、SaytileVoiceUI 和音频底层来自同一语音发布版。Nearpane 使用自己的资料目录、凭据作用域和编辑保护。七份本机识别模型清单随包校验，模型权重由独立的使用与许可条件约束。Riftlet 的导入、队列、JPEG/PNG 截图资源处理、上传回执与托盘视觉来自同一发布版。Nearpane 对网页程序摘要和所有外部输入位置独立加守卫。

**校验与缓存。** 锁文件记录来源仓库、40 位提交、选取范围、文件清单、逐文件 SHA-256 和汇总 SHA-256。将路径排序，每行写为 `<sha256><两个空格><相对路径><换行>`，对 UTF-8 字节计算汇总值。GitHub gzip 压缩方式改变不影响结果。下载器校验 tar 的 Git commit 标记、归档根目录、文件类型和文件内容，只将清单中的普通文件写入临时目录。文件全部通过校验后原子换入缓存。下载有超时和大小限制。每次使用已存在的缓存都重验文件、检查多余文件和符号链接。并发准备使用同一把锁。

默认缓存位于 `.build/domain-cache-v1/<commit>-<treeSHA256>/`。七个上游内部 Swift 文件与当前检出的 NearpaneTray 适配器通过忽略目录内的编译目标链接在一起。SwiftPM 从同一个锁文件读取版本。网络失败、校验不符或离线缺少缓存会以非零状态退出，错误包含固定来源或对应文件。若本地缓存损坏，先把报错所指的那一个缓存目录移到忽略目录中留证，再联网运行构建即可重新取回。此前 P3 使用过的缓存与历史收据可以保留。

**许可证与来源。** 开发包的 `Contents/Resources/Upstream/{saytile,riftlet}/` 含当前提交的来源清单、内容指纹和原始声明。Saytile 包含项目第三方声明、WebRTC BSD 与 wrapper MIT 文本。Riftlet 保留 Screenshoss、Sukurini 和 Tendedero 随附的四份文本。原文件内的版权头也随校验过的源码保留。两个固定提交的根目录均未提供项目级 LICENSE，本仓库未赋予额外许可。未进入二进制的独立研究或静态原型依赖不计入选取的编译文件。

**受控升级。** 在 GitHub 确定完整目标提交后运行下列命令。生成器从该提交的 Git tree 枚举选取范围，核对归档内容与 Git blob ID，再生成新的 SHA-256 清单。候选文件要求新路径，当前锁文件不会被覆盖。

```sh
python3 scripts/prepare-domains.py --propose saytile <40位提交> build/saytile-candidate.lock.json
git diff --no-index Dependencies/domains.lock.json build/saytile-candidate.lock.json
```

审查新增或移除的源文件、接口、许可证和桥接文件，明确采纳后替换锁文件并运行 `scripts/verify-standalone.sh`。升级 Riftlet 使用域名参数 `riftlet`。项目本身的 SwiftPM 定义、未公开组件的接口或许可范围发生变化时也要审查相应目标。不存在轮询分支或自动更新版本的任务。

Saytile 的两个 Swift 文件在上游通过符号链接与 `SaytileVoiceUI` 共享。锁文件的 `sharedSources` 逐个声明映射，升级提案验证 Git 树中的链接目标。构建只读取对应的已校验常规文件。原先的 RC2 加三份替换源码已整体升级为同一发布提交。成品的 `Upstream/{saytile,riftlet}/source.json` 记录 releaseTag、提交、来源和指纹。
