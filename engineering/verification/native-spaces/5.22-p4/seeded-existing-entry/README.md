# 已存词条随 Host 重启恢复

此用例将本机词典中的 `bicycle → 自行车` 作为既有记录。生产 `SidebarNotebook.commit` 在离线构建夹具时生成原始文件，附带真实词条 UUID、关联 UUID、时间戳和内容摘要。本用例的 Services 请求数为零。真实新句子的翻译、面板送达和保存另有验收入口。

从工程根目录构建只包含这一条记录的私有 kit。

```sh
KIT=$(scripts/acceptance/native-spaces/build-p4-wordbook.sh)
```

在受保护候选会话中，由外层先登记新的空白 Home 和活动代际，再用以下命令检查。它继承 `NEARPANE_TEST_HOME`、`NEARPANE_TEST_GENERATION`。原 notebook 已存在时停止。输出目录需为新路径。

```sh
python3 scripts/acceptance/native-spaces/p4-wordbook-recovery.py "$KIT" "$OUTPUT" --expected-source "$INSTALLED_REV"
```

夹具在正式 Host 正常退出后获得同一个 writer.lock，以排他方式发布新文件。随后两次由 Launch Services 正常打开正式 Host，分别复核运行签名、PID 和出生时间、同一代际与私有锁、磁盘文件摘要，以及真实进程自己的 `wordReopened` 日志。设置页必须在同一可见窗口的同一行连续两次显示准确的词和释义。各进程的磁盘、日志与可见层收据分别保存在 `result.json` 的 `hostReads`。最后保留持有外层原隔离代际的正式 Host，供外层统一恢复日常配置。

本次编译及离线测试通过。正式安装版恢复状态等待实机收据。[离线记录](offline.json)
