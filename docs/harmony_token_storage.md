# 鸿蒙登录凭证安全存储

日期：2026-10-29；范围：鸿蒙 NEXT 客户端的本地登录凭证，不代表整体安全或生产交付验收。

## 实现及升级行为

`TokenManager` 在非 Web 的 `TargetPlatform.ohos` 上默认选择 `HarmonyTokenStorage`，页面继续使用原有 `tokenManager`；Web 和其他平台仍使用原有偏好存储，未因本次改动获得系统安全存储保护。

`SecureTokenStoragePlugin.ets` 使用系统 Asset Store，将版本、access token、refresh token 合并为一条 JSON，全部放进加密的 `SECRET` 字段；固定别名 `haven_hub.session.v1` 不包含账号资料。Dart 和原生均检查 UTF-8 编码长度，完整记录最多 1024 字节，超过时保存失败，调用方不得视为登录成功。没有使用明文标签保存凭证，也没有自行管理加密密钥。

访问策略为 `DEVICE_FIRST_UNLOCKED`，同步策略显式为 `NEVER`；未启用持久化权限，未要求设备必须设置锁屏密码。首次解锁后可访问不等于每次读取都需要解锁或生物认证；无锁屏密码时也不能宣称密码保护。兼容 SDK 仍为 API 12，未升级工程 SDK。

升级时删除旧的两项偏好凭证，不导入旧登录，用户需要重新登录；保留其他偏好设置。删除失败会阻止加载和保存；两项删除分别尝试，第一项返回失败或抛错都不阻止尝试第二项。退出时即使旧偏好删除失败，也仍尝试清空系统资产，最终返回失败供调用方处理；不能把仅清内存当成磁盘退出成功。

第一次读先用 `THROW_ERROR` 添加空会话，仅忽略官方“记录已存在”错误 24000003，再读取现有资产；不会把数据库损坏、服务不可用、权限拒绝等当作无会话。这样也处理了首次尚未创建资产数据库时查询可能失败的情况。保存用单条资产的 `OVERWRITE`，不先删后加；退出覆盖为空会话记录，后续不会回读旧偏好。单条调用不作为跨进程崩溃恢复或系统事务保证的证明。

Dart 串行处理加载、写入和清理，并检查失效代数，防止迟到读取恢复已退出会话；TokenManager 保留原有刷新、换号和持久化失败处理。原生拒绝重叠调用，分离引擎后不返回成功。系统错误只返回固定提示，不包含凭证、系统原始异常或堆栈；插件缺失和系统失败都不回退到普通偏好存储。

## 本地证据

- `test/auth/harmony_token_storage_test.dart` 通过模拟 MethodChannel 验证默认平台选择、双凭证重启、退出、旧数据清理及失败重试、系统失败和插件缺失、坏数据、UTF-8 边界、启动重试、迟到刷新/加载和换号。它实际执行生产 Dart 实现，但没有执行设备资产库，不能称为加密或真机安全验收。
- `test/auth/token_persistence_race_test.dart` 继续验证原有持久化会话竞争；两文件定向运行共 22 项通过。
- 最终统一检查 `pwsh -File tool/check_project.ps1 -SkipRestore -LogDirectory C:/Users/23203/AppData/Local/Temp/haven-enterprise-secure-storage-20261029/final-checks-2` 通过后端548项、Flutter618项和显式启用的真实Dart/HTTP/SQLite联调1项，共1167项零失败；静态检查、服务端构建、网页语法和npm审计通过，审计为0项已知漏洞。
- 本地命令 `pwsh -File tool/flutter_ohos.ps1 build hap --debug --no-pub` 已完成 ArkTS 编译并生成签名调试 HAP，产物为 `build/ohos/hap/entry-default-signed.hap`；它不替代正式发布签名与设备测试。
- 构建及定向检查脚本为本机临时目录的 `haven-secure-storage-check-20261029.ps1`，构建日志为同目录 `haven-secure-storage-build-20261029.log`；本地原始构建诊断可能包含构建参数，不提交或公开上传。

## 仍需设备验收

本批未安装或清除设备现有应用，未实测系统资产库。需在专用测试安装中验证首次安装、首次解锁前后、无锁屏密码、设备重启、系统拒绝访问、写入中断、退出后重启和卸载重装，并检查其他应用无法读取资产；不得用真实住户凭证演练。旧版本应用不知道新资产记录，回退前须确定登录态处置和版本支持策略。

系统保护强度、备份或迁移行为、硬件实现及平台攻防结论均以目标设备和系统为准；仅有桥接代码、模拟测试和构建产物不构成这些保证。G1 保持部分完成。

## 核对依据

核对本机 SDK 的 `@ohos.security.asset.d.ts`、`@ohos.util.d.ts`，以及 2026-10-29 通过华为官方文档接口获取的正文：

- https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-asset
- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/asset-js-add
- https://developer.huawei.com/consumer/cn/doc/harmonyos-references/errorcode-asset

其中 `SECRET` 上限、固定别名的明文属性、首次解锁策略、禁止同步、重复记录错误及首次数据库查询说明与当前 SDK 声明一起用于实现核对。
