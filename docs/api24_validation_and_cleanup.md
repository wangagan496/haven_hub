# API 24 验证与白名单清理

执行日期：2026-09-20。本文记录本次实际结果，不替代旧系统真机、生产接口或发布验收。

## 当前配置与结论

- 目标版本：HarmonyOS 6.1.1 / API 24。
- 最低兼容配置：HarmonyOS 5.0.0 / API 12。
- 本机 SDK：6.1.1.125 Release；使用项目的 `tool/flutter_ohos.ps1` 包装脚本。
- 原样构建最低 24／目标 24 成功后，仅恢复最低版本到 12，再验证成功，最后执行清理和回归。
- 已构建的 x64、ARM64 正常入口 HAP 均确认 `minAPIVersion=50000012`、`targetAPIVersion=60101024`，并分别包含 x86_64、arm64-v8a 的原生库。
- 当前 Flutter 嵌入层依赖声明最低 API 12，但没有 API 12 设备运行证据；不能据此宣称全部旧设备兼容。

`ohos/build-profile.json5` 仍保留原来的 Git `skip-worktree` 标记。本次直接核对其文件内容，除最低版本字段外没有改变签名或其他字段。普通 `git diff` 不显示这项本机配置变化，换机必须单独核对。

## 验证结果

| 检查 | 结果 | 证据或边界 |
| --- | --- | --- |
| 最低 24／目标 24 基线 x64 构建 | 通过 | 修改兼容版本、删除文件之前完成；HAP 清单确认两者都是 API 24 |
| 最低 12／目标 24 x64 构建 | 通过 | 仅调整最低版本后完成；内部清单确认 12／24 |
| 清理后全项目静态检查 | 通过 | `analyze --no-pub`，No issues found |
| 清理后全部 Flutter 测试 | 通过 | `test --no-pub`，32 个测试通过 |
| 清理后正常入口 x64 Debug HAP | 通过 | `-t lib/main.dart --target-platform ohos-x64` |
| 清理后正常入口 ARM64 Debug HAP | 通过 | `-t lib/main.dart --target-platform ohos-arm64`；未在 ARM64 真机运行 |
| Web 默认 JavaScript 构建 | 通过 | `build web --no-pub -t lib/main.dart`；不代表 Wasm 支持或浏览器端完整业务验收 |
| API 24 x86_64 模拟器正常入口 | 通过 | 实际安装后检查首页、我的标签、资料入口登录保护及空登录表单提示；没有登录或提交业务 |
| 原生系统分享 | 通过 | 现有本地测试入口显示无通行权限测试图，打开分享面板并检查预览，关闭后按钮恢复，再次打开成功；未选择接收方或实际发送 |
| 测试后恢复正常入口 | 通过 | 重新覆盖安装正常 x64 包并启动，确认恢复首页；没有卸载或清空应用数据 |
| 相机、定位权限实际交互 | 未验证 | 当前模拟器未登录，相关页面受登录保护；未使用真实账号或绕过鉴权 |
| API 12 设备运行 | 未验证 | 本次没有 API 12 设备 |
| Release HAP／生产发布 | 未验证 | 原生构建为 Debug，不作为上架验收 |

清理后的两个正常 HAP 内均已确认三个删除图片不再打包，首页 banner 仍存在；正常首页也检查了实际截图。

## 保留的问题与警告

原生构建不是零警告：API 24 基线和恢复 API 12 后，各有 396 个唯一的“来源位置＋消息”警告，集合差异为 0。Hvigor 日志会累积，因此没有把第二次日志中的重复记录算成新增问题。

警告主要来自 Flutter 嵌入层和第三方插件，包含弃用接口、可能抛异常、部分权限声明、类型和 NAPI 检查提示。应用原生代码也有 `getShared`、`getContext` 弃用提示及分享缓存文件枚举的异常提示；文件枚举调用的异常由上层分享流程捕获。本次未为消除第三方可选能力警告而批量增加权限、改依赖缓存或升级依赖。

Web 构建的 Wasm 预检查提示 `geolocator_web` 使用 `dart:html`，不能据本次 JavaScript 构建成功声称支持 WebAssembly。本次未启用 Wasm，也没有通过关闭检查来隐藏警告。

## 清理结果与恢复

共删除 119 个文件：37 个非缓存文件已逐一备份并验证哈希，82 个文件属于可重建输出；另删除空的 `scripts` 目录。删除时旧文件合计 469,985,462 字节，这不是最终净释放空间，因为验证会重新产生构建文件并保存证据。

删除范围：

- 独立的 `arkts_simple_demo` 工程，包括其本地附属文件；完整备份后删除。
- `assets/images/blank@2x.png`、`marker.png`、`share_poster.png`。
- `lib/utils/.gitkeep`、根目录旧 Flutter 日志及 `tmp` 中四个旧日志。
- 指定的旧测试缓存、Web 输出、根 HAP 输出和 entry 模块 HAP 输出；验证所需输出已重新生成。

保留范围：现有未提交业务与测试改动、Web 工程、学习和历史文档、开发工具、依赖缓存、IDE 配置、签名和本地环境参数、国际化与插件注册文件、整个历史验证目录及手工截图。历史验证目录中仍被占用的模拟器日志没有触碰。

项目外备份：`D:\haven_hub-cleanup-backup\20260920-211836`。

- `baseline`：执行前已跟踪及未忽略文件的快照。
- `removed`：实际删除的非缓存文件，按原项目相对路径保存；恢复时只复制所需条目，不整体覆盖现有工作区。
- `baseline-hashes.json`、`protected-hashes.json`：源文件与受保护文件校验记录。备份含本机配置，仅供本地恢复，不发布。

## 本次产物与证据

证据目录：`build/verification/api24-20260920-211836/`（受 Git 忽略，仅在本机保留）。

- `haven-hub-api24-normal-x64.hap`：正常入口模拟器包，也是测试后恢复安装的包。
- `haven-hub-api24-normal-arm64.hap`：正常入口手机目标包。
- `haven-hub-api24-share-smoke-x64.hap`：本地分享测试包，不是正常应用交付包。
- `final-hap-manifests.json`：最终正常包的版本、架构、资源和 SHA-256 记录。
- `baseline-api24-*.log`、`compatible-api12-*.log`、`final-*.log`：分阶段构建、分析、测试日志。
- `warning-comparison.json`：两阶段警告集合比较。
- `device-results.json`、`normal-*.json/png`、`share-*.json/png`：本次设备结果与界面证据。
- `cleanup-manifest-before.json`、`cleanup-manifest-after.json`：明确删除路径、文件大小和哈希。

默认 `build/ohos/hap/entry-default-signed.hap` 最终为正常入口 ARM64 Debug 包。不同架构或入口构建会覆盖默认输出，使用留存的具名包区分用途。
