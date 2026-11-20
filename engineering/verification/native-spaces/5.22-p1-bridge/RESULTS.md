# P1 Bridged Window Management 准备

此分支基于正式候选 `f50d6ac`。在 macOS 27.0 (26A428) arm64 上，只读检查通过。系统类、初始化方法及无参数的 `performWithWMBridgeDelegate` 均符合指定 ABI。独立 Objective-C 夹具只创建一个模拟操作，持有不可变的单窗口数组并验证 64 位 Space ID、重复提交拒绝、无效签名及释放时机。[逐项收据](bridge-abi.json)

生产入口保持关闭。在实际窗口上，操作创建、提交和迁移次数均为零。P0 未通过，此分支独立于 PR #15 的安装版本。后续的系统移动合同要求逐窗核对目的桌面归属、同应用兄弟窗原始归属与代际，并让调用方持有该事务至终态。回退可直接使用 PR #15 的签名候选 `f50d6ac`。

在此工作树的 macOS SDK 上可复算收据。

```sh
out=$(mktemp -d)
xcrun clang -fobjc-arc -Werror -framework Foundation -framework CoreGraphics \
  -ISources/CNativeSpaceActions/include -ISources/CNativeSpaceActions \
  Sources/CNativeSpaceActions/NativeSpaceActions.m scripts/acceptance/native-spaces/bridge-abi-fixture.m \
  -o "$out/bridge-abi-fixture"
"$out/bridge-abi-fixture"
```
