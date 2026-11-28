# 5.22（90）原位翻译实机记录 · d81c458

**原位翻译验收失败。** 受控夹具在调用原生 Services 前持有输入焦点，调用返回时已失去焦点。六次面板采样的前后共十二次读回都指向正式 Host，均未指向原选区。正式 Host 的辅助功能、屏幕录制和事件投递权限均为已授权。[正式调用收据](translation/result.json) · [Host 权限](host-permissions.json) · [调用前的选区](translation/selection.png)

| 项目 | 结果 | 实机证据 |
| --- | --- | --- |
| Services 注册与递送 | PASS | 唯一已安装 provider 收到一次请求，队列和 Host 读回同一 UUID 和源文本哈希。 |
| 通用指针反馈 | PASS | 同一 Host 窗口 53822 的五个无遮挡样本均读出匹配的缺模型提示。每次都核对了窗口像素、OCR 和带请求 UUID 的 AX 内容。 |
| 初次取图 | 已拒绝 | 第一个样本的窗口身份、几何或透明度检查未稳定，观察器跳过取图。其后五次均只捕获已确认的 Host 提示窗。 |
| 原选区焦点 | FAIL | 夹具从调用前有焦点变为返回时无焦点。六个样本的位置均匹配请求时指针。 |
| 精确选区定位 | BLOCKED | Host 记录调用方未获认证，六个样本均未位于夹具的真实选区。 |
| 实际翻译、写词和重启 | BLOCKED / NOT_RUN | 系统支持英译中，本机缺少语言模型。本次匹配词条为零，因而没有本次词条的重启读回。 |

![正式 Host 的缺模型提示](translation/generic-feedback.png)

RunningBoard 记录显示，Apple 的 `com.apple.coreservices.launchservicesd` 为已登记 Host PID 10498 申请了前台断言。申请发生在该请求的 Host 回调前 4.499 毫秒、首个面板出现前 18.193 毫秒。同一断言在申请后 53 微秒记录为将以 active 状态创建。Host 在该段时间内记录了同 UUID 的 Services 阶段。夹具调用区间及其前后的 11 秒查询均未发现 Host 的 open 或 reopen 标记。现有记录能识别系统断言的直接申请者，未指认更上游的 AppKit 调用，也没有证据显示本次经过产品的设置窗口强制激活分支。[Host 与系统时间线](host-foreground.json)

候选验证结束后，受保护安装事务恢复原日常版本 d2d0bb6、日常配置和写锁，清理通过。[恢复收据](rollback.json) · [原始文件校验与统计](verification.json) · [本轮汇总](result.json)
