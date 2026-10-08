# 报修草稿与会话设备验证

## 已完成的自动检查

2026-10-08，在 `feature/repair-list-improvements` 完成以下本地提交：

- `68de27e`：会话与凭证变化后停止旧请求和自动重试。
- `add2fd1`：按用户隔离报修草稿，保留提交结果未确认状态。
- `6760e10`：鸿蒙图片使用内存缓存，并覆盖加载、失败和布局。
- `c9575fc`：构建脚本长路径支持与恢复规则说明。

项目包装脚本的全项目静态分析通过，116 条测试通过。新增设备验证入口也已通过全项目分析并构建出已签名的 x64 Debug HAP。构建成功不代表下面的设备流程已经通过。

## 验证入口和边界

### 复审后的生产身份回归（2026-10-08）

新增 `test/repair_identity_test.dart` 的 11 条 widget 测试，未注入 `draftUserKey`，实际经过 `UserInfoController` 与 `tokenManager` 的生产身份解析分支。覆盖资料在选项加载期间/之后到达、已有输入保护、未确认状态合并、草稿读取失败后重试、真实会话编号变化后的隔离，以及离开页面后的监听清理。网络加载器和 SharedPreferences 后端仍为测试替身。

新增 `test/token_persistence_race_test.dart` 的 4 条测试，使用实际 `SharedPreferencesTokenStorage` 加 mock 偏好设置后端，控制写入完成与返回之间的时序：排队清理成功后重新加载为空；仅清内存或清理失败时仍能读回残留；清理重试能移除残留；后续新登录不会被旧清理覆盖。本轮未修改凭证管理器的生产逻辑，也未模拟设备断电或原生存储故障。

本轮全量测试为 131 条通过（此前 116 条，本轮新增 15 条）。以下模拟器记录对应上一批代码；本次身份晚到修复尚未重新安装到模拟器，也未完成真实账号登录与服务端联调，不能把新增 widget 测试等同于设备验收。

### 原设备验证入口

`tool/repair_lifecycle_smoke.dart` 复用正式的 `RepairFormPage`、`RepairDraftStore` 和真实 SharedPreferences 插件。它用专用的 `repair-lifecycle-smoke:A/B` 用户标识隔离测试草稿，通过内存会话变化模拟账号替换，不读写正式登录凭证。房屋和维修项目使用固定数据；提交只计数、等待 20 秒并抛出超时，不调用服务端。

这能验证设备上的页面、插件存储、切后台与进程重启。入口注入了 `draftUserKey`，绕过正式页面基于 `UserInfoController` 和登录会话派生用户 ID 的分支，因此不能证明生产身份解析、用户资料晚到时的草稿行为、真实登录、401 刷新接口或服务端创建结果；这些需要另做联调。测试入口与正式应用使用同一个 bundle，安装后会暂时替换启动入口，完成后应重新构建并安装 `lib/main.dart`。安装更新保留应用数据，不要卸载或清空存储。

```powershell
.\tool\flutter_ohos.ps1 build hap --debug --no-pub --target-platform ohos-x64 -t tool/repair_lifecycle_smoke.dart
```

产物：`build/ohos/hap/entry-default-signed.hap`。这是 x64 模拟器包，真机须按目标架构另行构建。用 HDC 安装并启动 `com.example.haven_hub` 的 `EntryAbility`。

## 操作与验收

### 1. 换账号隔离

1. 在 A 下写入初始测试草稿，打开正式表单，把故障描述改为一个容易识别的值。
2. 保持旧表单打开，点顶部“切到 B”，尝试提交。应提示账号已变化，发送次数仍为 0。
3. 返回验证首页，在 B 下打开表单，不应恢复 A 的内容。
4. 切回 A 再打开，应该恢复 A 原来的草稿。首页“读取 A / B 草稿”可核对两份真实存储。

### 2. 杀进程后恢复

1. 修改 A 的表单内容，等候超过 300 毫秒保存延迟。
2. 切到系统桌面，再通过 HDC `aa force-stop` 结束本应用，重新启动。不得清除数据或卸载。
3. 打开 A 的表单，应恢复已保存内容。
4. 另测刚输入就强制结束的情况，记录最近输入是否丢失；不能承诺未完成的异步写入一定落盘，也不能假定系统必定调用 `dispose`。

### 3. 提交中返回

1. 在完整的测试草稿上点击提交，确认顶部发送次数增加为 1。
2. 在 20 秒模拟响应结束前返回，再打开表单。应看到“提交结果未确认”。
3. 再次点提交，应出现二次确认；选择“先不提交”，发送次数仍为 1。
4. 等模拟超时返回后再次核对草稿，未确认状态应继续保留。

## 当前设备结果

2026-10-08，在 HDC `127.0.0.1:5555` 上完成验证。设备为 x86_64 模拟器，API 24，系统版本 `emulator 6.1.0.126(SP1DEVC00E120R4P11)`。使用 `1c78cb3` 对应的验证入口和真实 SharedPreferences 插件；通过设备 `uitest`、界面树与截图核对。

| 场景 | 实际结果 |
| --- | --- |
| A 的旧表单切到 B 后尝试提交 | 提示“登录账号已变化，请返回后重新打开报修页面”；发送次数保持 0 |
| B 重新打开表单 | 没有 A 的描述、电话或已选房屋，没有恢复 A 草稿 |
| 切回 A 后重新打开 | 恢复编辑后的 `draft-Adraft-A-edited`、电话、房屋和日期 |
| 保存后切后台、force-stop、重启 | 进程从 5720 变为 7885，原进程已退出；A 的编辑内容完整恢复 |
| 提交后在 20 秒延迟结束前返回、重开 | 出现“提交结果未确认”，输入仍在 |
| 再次提交并选择“先不提交” | 出现重复创建风险确认；取消后发送次数保持 1 |
| 迟到超时及再次进程重启 | A 草稿仍保留 `resultUnconfirmed=true`，未被迟到结果清除 |

边界检查：对 B 执行输入 `rapid-stop` 后立即调用 `aa force-stop`，重启只恢复原有 `draft-B`。输入命令返回成功，用时 1329 毫秒；从输入命令返回至停止命令结束约 338 毫秒。该次没有额外截取停止前输入画面，因此不据此精确归因输入完成时刻或存储插件时序。对照操作输入 `rapid-check` 后先取得界面树，确认显示 `draft-Brapid-check`，再结束进程；重启后能恢复该内容。

验收边界：已保存的草稿及未确认状态能够跨进程恢复；不能保证最近一次输入在立即杀进程时不丢失，300 毫秒防抖及异步落盘窗口仍存在。本次不将它改写成“完全防丢失”，也不声称完成了真机、真实账号登录或服务端幂等验收。

本地证据保存在忽略提交的 `build/` 下：

- `repair-account-blocked.jpeg`：换账号后旧表单提交被拦截，发送次数为 0。
- `repair-b-empty.json`、`repair-a-restored.json`：B 空表单与 A 内容恢复。
- `repair-after-restart.json`、`repair-after-restart.jpeg`：进程重启后的恢复。
- `repair-pending-reopened.json`、`repair-confirmation.jpeg`：未确认状态与二次确认。
- `repair-final-drafts.jpeg`：取消再次提交后计数仍为 1，A 未确认状态仍在。
- `repair-rapid-restart.jpeg`、`repair-rapid-before.json`、`repair-rapid-control.jpeg`：快速停止与对照。

验证结束后，已用 `lib/main.dart` 重新构建已签名 x64 Debug HAP，并以 `hdc install -r` 更新安装、启动正式 `EntryAbility`。设备界面树和截图确认回到“社区”首页，出现“我的房屋 / 我的报修 / 访客登记”和公告；测试入口已替换，未卸载或清空应用数据。恢复证据：`build/repair-main-restored.json`、`build/repair-main-restored.jpeg`。
