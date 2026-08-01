# ArkTS 简单示例

这是一个独立的 HarmonyOS Stage 模型工程，不会修改同级目录中的 Flutter 项目。

## 1. 在 VS Code 中修改

在终端执行：

```powershell
code D:\haven_hub\arkts_simple_demo
```

主要修改这个文件：

```text
entry\src\main\ets\pages\Index.ets
```

例如，把页面中的“我的第一个 ArkTS 应用”改成自己的标题。截图中的
`HarmonyOS-ArkTS` 扩展可以为 `.ets` 文件提供语法支持。

## 2. 在 DevEco Studio 中运行

1. 打开 DevEco Studio。
2. 选择 `File > Open`。
3. 打开 `D:\haven_hub\arkts_simple_demo`，不要只打开 `entry` 文件夹。
4. 等待右下角工程同步完成。
5. 在设备列表中选择已启动的模拟器或已连接的手机。
6. 选择运行配置 `entry`，点击绿色运行按钮。

第一次运行如果提示签名，进入 `File > Project Structure > Signing Configs`，为
`default` 产品开启自动签名，然后再次运行。

运行后，输入名字并点击“打个招呼”，页面会显示问候语和按钮点击次数。
