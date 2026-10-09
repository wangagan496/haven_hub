# 报修草稿与会话设备验证

## 最新联调结果（2026-10-09）

本节为当前结果，下文 2026-10-08 内容保留为历史。使用既有测试账号 `sss36`，真实连接课程后端；没有服务端源码，也没有修改服务端。

### 修复与实测

| 项目 | 实际证据 |
| --- | --- |
| 完整列表检查 | 原客户端默认只显示 10 条，实际 `total = 38`。只读 `pageSize=100` 返回 38/38；再用 `current=1..4&pageSize=10` 获得 10、10、10、8 条，共 38 个不同 ID。原测试标记未在当前完整结果中找到 |
| 唯一诊断 POST | 独立标记 `replay-probe-20261009-remaining`、日期 `2026-10-10`，返回 HTTP 500、业务码 500，message 为 `ER_NO_DEFAULT_FOR_FIELD: Field 'attach' doesn't have a default value`。随后完整列表仍 38 条，无该标记 |
| 附件参数修复 | 列表与详情的 `attachment` 为数组，已有空数组记录。无附件表单显式提交 `attachment: []`，不改 ID 或日期类型 |
| 正式应用创建 | 首轮更新安装的正式 `lib/main.dart`，进程 19868。页面恢复旧草稿后改为独立标记 `device-fixed-20261009-attachment`、日期 `2026-10-10`，确认后仅提交一次。返回 HTTP 200、业务码 10000，页面显示“报修提交成功”并刷新列表 |
| 服务端读回 | 完整列表变为 39 条，准确标记仅一条。详情 ID `7338026907516928`，房屋 `7177501402628096`、项目 `1001`、测试电话 `13800138008`、日期与描述匹配，`attachment=[]`、`status=1` |
| 成功后草稿清理 | 再进入新增表单为空，不再出现未确认横幅。只读偏好设置确认当前账号草稿键不存在；结束进程后重开仍为空。凭证未打印、未直接改写 |
| 取消接口核对 | 应用原路径 `PUT /cancel/repair/{id}` 实际 404，有限 REST 候选 `PUT /repair/{id}` 也 404。同课程公开示例提示 `PUT /cancel/repaire/{id}`；只针对刚创建的准确记录调用该路径，返回 200 / 10000，详情读回 `status=0` |
| 取消状态修复 | 客户端原先把 0 当作待处理。现已改为“已取消”、不进入待处理筛选、不显示再次取消按钮；保留既有 4 的已取消展示兼容 |
| 后续未知状态修正 | 状态缺失或无法解析时显示“状态未知”，只在“全部”列表可见，不提供取消操作。这项修正由新增的两条测试覆盖，尚未重新构建或安装到模拟器 |
| 本轮已安装包界面 | 附件、分页、取消契约和日志修复已构建到正式 x64 Debug HAP，更新安装保留数据，进程 1208。列表显示新记录“已取消”；切待处理后不再显示该记录；详情显示已取消且没有取消按钮；新增表单为空。该记录早于后续未知状态修正 |
| 最终分页 | 正式应用日志确认使用 `current=1&pageSize=20` 和 `current=2&pageSize=20`，两页均返回 200，不再只取默认第一页 |

本轮共有两次创建尝试：一次独立诊断失败，一次修复后正式应用创建成功。只新增一条测试历史，现已取消，并非从服务端删除；没有取消其他既有记录，也没有创建访客对照。

**验证边界**：创建和草稿清理走正式页面；成功取消使用独立诊断 HTTP 调用。修复后的取消 API 用适配器测试核对路径、方法、ID 编码，widget 测试覆盖成功返回后刷新；最终设备验证覆盖取消状态的显示、筛选和按钮。没有为再测一次取消按钮而额外创建记录，不声称全链条每一步都已由最终包重新操作。

同课程公开例子的 baseURL 已核对一致，但它仅为定位线索，实际契约由 API 返回确认：

- https://github.com/zhouyan57/enjoy-plus/blob/master/miniprogram/repair_pkg/pages/detail/index.js
- https://github.com/zhouyan57/enjoy-plus/blob/master/miniprogram/repair_pkg/pages/detail/index.wxml

### 自动检查和构建

- 收尾复核全量测试 **160 条通过**（增加两条未知状态测试），严格静态分析 `--fatal-infos --fatal-warnings` 无问题。
- 11 个相关 Dart 文件格式只读检查 0 changed；`git diff --check` 无空白错误。
- 附件参数、取消路由/状态、日志泄漏保护都有修复前失败、修复后通过的证据。
- 接口与日志修复已用 `.\tool\flutter_ohos.ps1 build hap --debug --no-pub --target-platform ohos-x64 -t lib/main.dart` 构建正式入口签名 HAP；通过 `hdc install -r` 更新成功，未卸载、未清空数据。后续未知状态修正未重新打包，不能把这次构建当作当前全部代码的构建验证。Git 收尾范围见 `docs/repair_work_conclusion.md`。
- 设备仍为 API 24 x86_64 模拟器，不是真机；身份隔离/草稿的原有注入和正式入口测试见下方历史记录。

### 当前证据文件

忽略提交的 `build/` 中：

- `repair-backend-replay-20261009.log`：完整列表、唯一诊断 POST 和 attach 报错。
- `repair-fixed-device-network-20261009.log`：正式应用带空附件创建成功及分页日志；手机号已脱敏。
- `repair-cancel-contract-20261009.json`：取消路径、结果读回与草稿键删除的核对摘要。
- `repair-final-device-network-20261009.log`：最终包的分页、详情与选项读取。
- `repair-identity-remaining-fixed-submit-ready.json`、`repair-identity-remaining-fixed-confirm.json`、`repair-identity-remaining-fixed-submitted.json`、`repair-identity-remaining-fixed-created-list.json`：实际提交前后。
- `repair-identity-remaining-final-list-cancelled.json`、`repair-identity-remaining-final-pending-filter.json`、`repair-identity-remaining-final-cancelled-detail.json`、`repair-identity-remaining-final-empty-form.json`：最终包状态验证，均有同名 JPEG。
- `remaining-full-tests-20261009.log`、`remaining-analyze-20261009.log`、`remaining-hap-build-20261009.log`：最终自动检查及构建。

原响应未保存在已检查的本地证据中，今天的新响应不能恢复昨天的原响应。当前已确认无附件创建及取消契约可用；未验证服务端幂等、数据库默认值修复或任意状态的后端行为。草稿 300ms 防抖及异步落盘窗口仍存在。

## 已完成的自动检查

2026-10-08，在 `feature/repair-list-improvements` 完成以下本地提交：

- `68de27e`：会话与凭证变化后停止旧请求和自动重试。
- `add2fd1`：按用户隔离报修草稿，保留提交结果未确认状态。
- `6760e10`：鸿蒙图片使用内存缓存，并覆盖加载、失败和布局。
- `c9575fc`：构建脚本长路径支持与恢复规则说明。

项目包装脚本的全项目静态分析通过，116 条测试通过。新增设备验证入口也已通过全项目分析并构建出已签名的 x64 Debug HAP。构建成功不代表下面的设备流程已经通过。

## 验证入口和边界

### 复审后的生产身份回归（2026-10-08）

新增 `test/repair_identity_test.dart` 的 20 条 widget 测试，未注入 `draftUserKey`，实际经过 `UserInfoController` 与 `tokenManager` 的生产身份解析分支。覆盖冷启动主动获取身份并恢复/提交、资料获取失败及重试、空用户 ID、并发请求去重、凭证刷新期间的身份响应、账号替换、页面退出、缺少登录凭证、资料已就绪时跳过请求、已有输入保护、未确认状态合并、草稿读取失败提示及重试，以及离开页面后的监听清理。网络加载器和 SharedPreferences 后端仍为测试替身。

新增 `test/token_persistence_race_test.dart` 的 5 条测试，使用实际 `SharedPreferencesTokenStorage` 加 mock 偏好设置后端，控制写入完成与返回之间的时序：排队清理成功后重新加载为空；仅清内存或清理失败时仍能读回残留；token 已删除但 refreshToken 删除失败时能复现部分清理状态；清理重试能移除残留；后续新登录不会被旧清理覆盖。本轮未修改凭证管理器的生产逻辑，也未模拟设备断电或原生存储故障。

本轮全量测试共 141 条通过（此前 131 条，本轮新增 10 条）。已有身份优先于迟到请求的用例还控制了草稿读取时序：读取未完成时首击提交，读取完成后只发送一次请求，迟到的空身份响应不覆盖已确认的资料。本次按需身份加载修复已通过正式入口安装到模拟器，并使用现有测试账号调用实际服务端；具体结果和未通过的创建环节见下文。widget 测试中的加载器仍为测试替身，不能单独作为设备验收依据。

### 正式入口与测试账号的接口联调（2026-10-08）

使用 `lib/main.dart` 构建已签名的 x64 Debug HAP，通过 `hdc install -r` 更新安装并保留应用数据。设备为 HDC `127.0.0.1:5555` 上的 x86_64 模拟器，API 24，系统版本 `emulator 6.1.0.126(SP1DEVC00E120R4P11)`。复用现有已登录测试账号（昵称 `sss36`），本轮没有重新执行短信验证码登录。以下请求实际连接课程后端 `https://live-api.itheima.net/`，没有注入 `draftUserKey`、房屋数据、维修项目或提交加载器。

| 场景 | 实际结果 |
| --- | --- |
| 保存草稿后完整结束进程，再从首页进入“我的报修 → 新增报修”，不访问“我的” | 进程从 8822 变为 20520，停止后 `pidof` 为空；身份警告消失，显示“已恢复当前账号的报修草稿” |
| 冷启动草稿内容 | 房屋 `健朗花园 7号楼 1002`、维修项目 `水路卫浴`、测试电话 `13800138008`、预约日期 `2026-10-09`、描述 `Codex-test-20261008-0952` 全部恢复 |
| 首次点击“提交报修” | 请求到达 `POST /repair`，HTTP 响应为 500；表单和草稿保留，显示“提交结果未确认” |
| 返回列表，明确下拉刷新，再检查至列表末尾 | 当时没有找到匹配候选，因此未取消任何记录。2026-10-09 确认旧客户端仅取默认第一页 10 条，此项不构成完整列表核对 |
| 返回表单，再次点击提交并选择“先不提交” | 出现“上次提交结果未确认”的重复创建风险确认；取消再次提交后，五个字段和未确认提示保留 |
| 再次完整结束进程，仍从首页直接进入新增报修 | 进程从 20520 变为 21428，停止后 `pidof` 为空；五个字段和未确认状态仍恢复。网络日志确认报修页主动调用 `GET /userInfo` 并返回 200，房屋和维修项目接口也返回 200 |
| 重启后再次提交，选择“先不提交” | 二次确认仍出现；持续监听应用网络日志，操作期间没有新增 `POST /repair`，草稿保持完整 |

首次创建请求的房屋 ID 为 `7177501402628096`、维修项目 ID 为 `1001`，其余字段与上表一致。HTTP 500 和当前列表未出现匹配记录，仍不足以证明服务端从未创建记录。

**仅凭这次历史记录不能判定 500 原因。** 当时 `RequestDio` 只记录包含状态码文本的 `DioException.message`，没有独立状态字段和失败响应体。这是可修的证据缺口，但补日志本身不保证完成归因；另有列表未完整读取的验证缺口。2026-10-09 的新诊断和修复结果见本文顶部。

Claude 随后补齐了失败日志并增加两条用例，当时全量 143 条通过但尚未重装。因此本历史段来自**日志补全前、身份修复后**的构建。最新代码又增加自由文本保护和非结构化 body 省略，并已安装到设备；当前用例总数及结果见顶部。

在 2026-10-08 当时没有盲目重发，创建成功、成功后清理草稿、取消和幂等均未验证。原响应无法从已检查的本地证据恢复；新请求只能提供新证据，也可由服务端当次日志或可信契约协助查证。今天的新增验证不覆盖服务端幂等。

本轮结论：冷启动主动获取身份、当前账号草稿恢复、HTTP 500 后的输入与未确认状态保留、跨进程恢复和再次提交确认已在正式入口与测试账号下通过。创建成功环节未通过，不能称为完整端到端验收。测试结束后保留正式入口安装包并返回社区首页，测试草稿仍在，未清空应用数据。

本地证据保存在忽略提交的 `build/` 下：

- `repair-identity-draft-before-restart.json`、`repair-identity-cold-home-ready.json`、`repair-identity-cold-form.json/.jpeg`：首次进程重启和冷启动恢复。
- `repair-identity-submitted.json/.jpeg`：首次提交后保留表单和未确认提示。
- `repair-identity-list-refreshed-ready.json`、`repair-identity-list-scroll-down.json`、`repair-identity-list-scroll-bottom.json`：刷新后从列表顶部至末尾的检查。
- `repair-identity-uncertain-confirm.json/.jpeg`、`repair-identity-uncertain-declined.json`：再次提交确认与选择“先不提交”。
- `repair-identity-uncertain-restart-home.json`、`repair-identity-uncertain-restart-form.json/.jpeg`：未确认状态和五个字段跨进程恢复。
- `repair-identity-uncertain-restart-confirm.json/.jpeg`、`repair-identity-uncertain-restart-declined.json`、`repair-identity-final-home.json/.jpeg`：重启后再次确认、取消提交和最终正式首页。

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

## 注入验证入口的设备结果

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

验收边界：已保存的草稿及未确认状态能够跨进程恢复；不能保证最近一次输入在立即杀进程时不丢失，300 毫秒防抖及异步落盘窗口仍存在。本段记录只覆盖注入验证入口，不声称完成了真机、账号登录接口或服务端幂等验收；正式入口与测试账号的接口联调结果见上文。

本地证据保存在忽略提交的 `build/` 下：

- `repair-account-blocked.jpeg`：换账号后旧表单提交被拦截，发送次数为 0。
- `repair-b-empty.json`、`repair-a-restored.json`：B 空表单与 A 内容恢复。
- `repair-after-restart.json`、`repair-after-restart.jpeg`：进程重启后的恢复。
- `repair-pending-reopened.json`、`repair-confirmation.jpeg`：未确认状态与二次确认。
- `repair-final-drafts.jpeg`：取消再次提交后计数仍为 1，A 未确认状态仍在。
- `repair-rapid-restart.jpeg`、`repair-rapid-before.json`、`repair-rapid-control.jpeg`：快速停止与对照。

验证结束后，已用 `lib/main.dart` 重新构建已签名 x64 Debug HAP，并以 `hdc install -r` 更新安装、启动正式 `EntryAbility`。设备界面树和截图确认回到“社区”首页，出现“我的房屋 / 我的报修 / 访客登记”和公告；测试入口已替换，未卸载或清空应用数据。恢复证据：`build/repair-main-restored.json`、`build/repair-main-restored.jpeg`。
