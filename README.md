# Haven Hub · 享家社区

面向住户、维修师傅和物业的社区物业应用：Flutter 客户端、自建 Node.js 服务和物业网页后台。

当前仓库提供鸿蒙与 Web 工程入口；Flutter 具备 Android 支持能力，但本仓库未保留 `android/` 工程，不能直接承诺 Android 构建或设备验收。服务默认本地开发模式，只监听回环地址；已增加腾讯云短信适配和严格生产配置，实际云端收信及生产部署尚未验收，配置与边界见 [腾讯云短信接入](docs/tencent_sms_setup.md)。

## 功能概览

- 验证码登录、个人资料、房屋录入与物业审核、腾讯定位选房、社区公告、访客通行码。
- 报修流程：住户提交 → 物业定级 / 排单 → 派单 / 师傅接单 → 提交完工或保存可确认结果 → 住户确认 → 售后申请及返修。返修次数不设上限，每轮从最终确认完成起算 720 小时售后期；当前轮内容保存在 rounds，历史费用保存在 fees。
- 物业网页后台提供房屋审核、报修队列、人工急单调度、顺延建议、三层时段容量和维修人员管理。
- 鸿蒙访客通行码通过自定义 MethodChannel 调用系统分享；关闭分享面板只表示操作结束，不代表接收成功。
- 图片按登录、用途及当前业务对象授权；师傅支持停用、恢复和账号变更历史，停用后旧会话失效，恢复后须重新登录。
- 已接入的错误提示可复制排查编号；服务端提供不连接数据库的维护模式和带完整性校验的在线备份、隔离恢复命令，详见 [演练手册](docs/backup_restore_runbook.md)。
- “确认修好”按钮与服务端执行共用规则，不能操作时显示原因；确认弹窗防重复，版本变化、换号及迟到刷新均有回归保护，接口说明见 [服务端说明](server/README.md#确认修好的操作快照)。
- 物业容量设置使用内容版本保护并发编辑；旧页面保存会收到冲突提示，未保存输入不会自动重放。
- 房屋编辑与物业审核共用递增版本；旧表单不能覆盖新资料或审核结果，冲突保留当前输入，确认重新加载后才能核对并再次提交。

- 访客邀请发送前保存原内容与提交回执；响应丢失或重开页面后可查询、按原内容重试或安全停止，重复请求只创建一份邀请与通行码。

- 房屋创建发送前保存提交回执，支持查询、原内容重试和安全停止；重复请求只创建一套房屋，原房屋已删除时返回删除结果，不会重新创建；多个普通选房草稿仍保留在内存中，每个账号最多保存一份待确认创建。

- 房屋删除校验用户查看时的版本，不能删除已被修改或审核的新资料；冲突或响应丢失后先刷新核对，再次确认才会删除，确认与请求期间禁止重复操作，换号或页面关闭后忽略迟到结果。

2026-10-28 已推进十六批加固：提交回执与统一检查，图片权限与账号生命周期、错误回执及本地恢复，确认操作规则与页面并发保护，容量配置并发保护，房屋编辑与审核并发保护，访客提交去重与恢复，房屋创建去重与恢复，房屋删除并发保护，报修撤销并发与结果恢复保护，推送任务领取与超时恢复，可配置的客户端最低版本门禁和升级提示，住户报修分页的内存控制，全局人手快照精简，启动待办逐条重建与失败清理，师傅资料的一次分组读取，以及住户客户端按需分页和服务端筛选；真实短信、生产部署、远程告警、异地备份策略、小区隔离、旧正式客户端兼容及真机验收仍未完成，不能据此认定已达到正式交付条件，逐项证据见 [生产化目标](docs/enterprise_readiness_goals.md)。

客户端兼容基础：`CLIENT_MIN_VERSION` 默认留空；启用后缺失、非法或过旧的版本在业务处理前收到426，Flutter统一提示升级，保留登录状态且不重放提交；物业网页也遵守门禁。构建脚本从pubspec或build-name注入实际版本，正式支持期、升级分发渠道和旧正式产物仍待验收，详见 [服务端说明](server/README.md#客户端版本门禁本地可配置基础)。

## 技术亮点

- **集中管理状态规则**：`server/src/repair/policy.ts` 处理期限、顺延资格和待办；`server/src/repair/actions.ts` 处理状态迁移，动作接收时间参数，不直接访问数据库。状态定义在 `server/src/repair/model.ts`。
- **revision 与事务**：`server/src/repair/repository.ts` 的 `mutate` 在授权后校验 revision，旧版本返回 HTTP 409，再执行动作、版本递增及保存。`server/src/database.ts` 使用 SQLite `BEGIN IMMEDIATE`；创建、名额检查、多步保存和通知入库在事务内完成。直接取消与撤销申请都必须携带查看时的 revision；缺少或过期返回409，历史无版本工单须显式提交0；直接取消仅用于未接单阶段。
- **按订单计算名额**：`server/src/repair/schedule.ts` 每天开放 11 个一小时时段（08、09、10、11、14、15、16、17、19、20、21 点），预约窗口为含今天的 7 天，普通预约至少提前 2 小时。`repository.ts` 按默认容量 → 星期模板 → 单日覆盖合成容量；只读取订单 `slot` 计算占用，不另建占用表。
- **人工急单调度和顺延**：`server/src/repair/service.ts` 的急单调度绕过公开容量上限，但检查师傅同一时段是否空闲；不会自动挤走其他单。急单仍写入 `slot` 并参与后续占用统计。`policy.ts` 只给顺延建议，实际移动必须由物业操作。
- **北京时间与惰性结算**：`schedule.ts` 用 UTC+8 生成业务日期，`repository.ts` 按该日期计算星期；期限按连续小时计算。`policy.ts` 的 `settle` 在查询 / 写入前处理过期事项，不依赖定时任务才能生效；推送投递另有轮询。
- **待办与推送分层**：`server/src/repair/notification-tasks.ts` 生成任务；`server/src/notifications.ts` 在短事务内按任务与设备领取投递，使用60秒领取期限恢复中断，并校验领取标识防止迟到结果覆盖新任务；发送不占用数据库事务。`server/src/push-transport.ts`、`ohos/entry/src/main/ets/PushPlugin.ets`、`web/push.js` 接入 HarmonyOS Push Kit 与 Web Push；外部服务已接收但本地未保存的结果仍可能重发，接入不等于设备送达或生产多实例验收。
- **Flutter 请求与恢复**：`lib/utils/request_dio.dart` 区分网络 / 业务错误，丢弃旧会话响应；401 刷新成功后，同一会话的白名单 GET 安全读取恢复一次，超时及 502/503/504 在请求层内按预算重试，写操作不自动重放；`lib/utils/token_manager.dart` 串行写凭证。`lib/pages/repair/repair_pages.dart` 与 `lib/utils/repair_draft_store.dart` 按已确认身份保存草稿和报修提交回执；新版报修创建按账号与回执在事务中去重，支持查询结果、按原内容显式重试及安全停止迟到请求，旧客户端无回执的创建仍走兼容契约。

## 目录结构

```text
.githooks/    提交检查
.github/     GitHub 工作流
assets/      图片、字体等资源
lib/         Flutter 页面、API、模型、工具和组件
ohos/        鸿蒙工程及原生桥接
server/      Node.js 24+、Express 5、SQLite 服务及物业网页
test/        Flutter 自动化测试
third_party/ 保留来源和许可的 image_picker_ohos 修补副本
tool/        Flutter OH 包装器、构建、代理、设备转发脚本
web/         Flutter Web 入口和推送脚本
docs/        开发与学习材料，部分仅保留在本地
server/src/repair/actions.ts             纯业务动作与状态迁移
server/src/repair/model.ts               状态、轮次、待处理事项、时间线
server/src/repair/notification-tasks.ts  报修通知任务生成
server/src/repair/paths.ts               新增报修 HTTP 路径
server/src/repair/policy.ts              期限、结算、队列和资格规则
server/src/repair/repository.ts          数据访问、事务、版本和容量
server/src/repair/routes.ts              HTTP 路由
server/src/repair/schedule.ts            时段、北京时间、名额和师傅冲突
server/src/repair/service.ts             参数、权限与业务编排
server/src/repair/views.ts               角色视图、联系方式和字段隔离
```

## 快速开始

以下 PowerShell 命令于 2026-10-20 实际执行。需 Node.js 24+、Flutter OH SDK；鸿蒙构建另需本机 DevEco SDK 和签名配置。包装器自动查找 Flutter OH，避免 PATH 选中错误 SDK。

### 1. 本地服务

在仓库根目录的终端执行（`npm start` 持续运行）：

```powershell
cd server
npm ci
npm run build
npm start
```

服务地址 `http://127.0.0.1:3000`，物业后台 `/admin/`，健康检查 `/health`。默认数据库为 `server/data/haven.sqlite`；本机 `.env` 可覆盖配置。代码拒绝非回环 HOST 和生产模式，不能直接当作生产部署方案。

### 2. Web 调试与腾讯定位

按 `tool/dart_defines.example.env` 创建不提交的 `tool/dart_defines.local.env`，填写腾讯 **WebService API** 的 `TENCENT_MAP_KEY`。包装器在运行 / 构建时检查 Key 是否存在；不要把 Key 写进源码或 README。

本机 SDK 路径如下，换机需替换为实际路径；在仓库根目录另开终端运行地图代理：

```powershell
& 'C:\flutter_flutter_3.41.10_ohos\bin\dart.bat' run tool/web_api_proxy.dart 3001 --direct
```

`tool/dart_defines.web.local.env` 使用以下本机地址：

```dotenv
API_BASE_URL=http://127.0.0.1:3000/
TENCENT_MAP_API_BASE_URL=http://127.0.0.1:3001/tencent-map/
AMAP_API_BASE_URL=http://127.0.0.1:3001/amap-map/
```

另开终端运行，随后打开 `http://127.0.0.1:8080`：

```powershell
.\tool\flutter_ohos.ps1 run -d web-server --web-hostname=127.0.0.1 --web-port=8080 --dart-define-from-file=tool/dart_defines.web.local.env --dart-define-from-file=tool/dart_defines.local.env
```

地图代理只转发腾讯 / 高德路径。原生端不传地图代理地址，直接请求地图服务。`LOCATION_COORDINATE_SYSTEM=auto` 自动处理坐标；模拟器手动输入腾讯 / 高德拾取器的 GCJ-02 坐标时可设为 `gcj02`，避免重复转换。编译参数不是密钥保险箱；正式服务应另行设计服务端保管和转发。

### 3. 鸿蒙转发与构建

设备内的 `127.0.0.1` 指设备自身，先连接并授权设备，再从仓库根目录执行：

```powershell
.\tool\forward_local_backend.ps1
.\tool\flutter_ohos.ps1 build hap --debug --no-pub -t lib/main.dart --target-platform ohos-x64
```

转发脚本默认把设备 TCP 3000 转到电脑 TCP 3000；本轮实跑因无可用设备失败。x64 Debug HAP 构建通过，输出 `build/ohos/hap/entry-default-signed.hap`，用于 x64 模拟器，不可当作 ARM 真机包。

本机 `ohos/build-profile.json5` 存在 `skip-worktree` 配置，签名与 SDK 配置需自行检查；`buildOption.strictMode.useNormalizedOHMUrl: true` 用于避免跨架构增量产物混用模块路径。不要提交本机签名材料。

### 4. 三角色演示数据

在根目录构建演示 Web，然后在 `server` 目录启动独立演示服务：

```powershell
.\tool\build_workflow_web.ps1
cd server
npm run demo
```

该命令在 3010 端口持续运行，使用 `server/data/workflow-demo.sqlite`，不使用默认业务数据库。住户入口 `http://127.0.0.1:3010/workflow/`，师傅入口 `/workflow/#/worker`，物业入口 `/admin/`。三个角色使用独立浏览器配置，避免同源账号存储互相覆盖。

虚构演示账号：住户 `19900000001`、物业 `19900000002`、师傅 `19900000003`。点击获取验证码后使用开发验证码登录。种子提供房屋和一条“等待安排”的报修；重复启动保留数据，不自动清空。演示不要求启用系统推送。

## 测试

Flutter 与服务端测试均按登录认证、房屋、报修、访客、师傅、通知等业务归类；目录职责、全量与单业务运行命令见[测试说明](test/README.md)。

2026-11-03 在当前未提交工作区实际运行以下全量检查，退出码为0：

```powershell
pwsh -File tool/check_project.ps1 -SkipRestore -LogDirectory C:/Users/23203/AppData/Local/Temp/haven-review-fixes-20261103/verified-checks
```

| 范围 | 通过 | 失败 | 跳过 |
| --- | ---: | ---: | ---: |
| 服务端测试 | 664 | 0 | 0 |
| Flutter测试 | 639 | 0 | 1 |
| 隔离真实后端集成测试 | 1 | 0 | 0 |
| 实际通过合计 | 1304 | 0 | — |

Flutter普通测试默认跳过的本地后端集成用例，已由统一入口最后一步显式启用并实际执行；合计不重复计数。服务端构建、admin目录全部JavaScript语法检查、Flutter固定版本核对与静态检查均通过，静态检查输出`No issues found`，依赖安全审计输出`0 vulnerabilities`。

九项审查问题均补有回归测试；另对25条用例进行受控故障注入对照，恢复故障行为时25条失败，还原修复后同样25条通过，这不是旧分支原样构建。逐项文件、测试、对照方法与验证边界见[修复记录](docs/review_fixes_20261103.md)。

最终全量日志位于`C:\Users\23203\AppData\Local\Temp\haven-review-fixes-20261103\verified-checks`，包括`server-test.log`、`flutter-test.log`、`integration.log`及构建、静态检查、审计日志；对照日志位于同级`regression-red`和`regression-green`目录。本轮未重新运行历史性能实验，也未进行浏览器、真机、实际短信收信、生产部署或远程CI验收。

## 踩过的坑

- **刷新撞上换号**：旧请求可能使用新账号凭证；拆分会话身份和凭证版本并串行写入，历史修复曾停止旧请求重放（`e88ac5e`、`c8d4def`、`079ddd5`、`68de27e`）。当前同一会话的安全读取恢复一次，跨会话请求和写操作不重放。
- **相册一直等待**：相机失败后原生插件保留旧回调，下一次选择回到旧请求；清理 pending 状态并拒绝真正的并发调用（`2ca7cd5`）。
- **草稿身份晚到**：页面先打开、用户资料后到，草稿绑定与读取时机不一致；按会话监听身份、按需取资料，区分读失败与空草稿（`a448149`、`094e581`）。
- **鸿蒙网络图片缓存失败**：依赖的磁盘缓存路径没有可用 OHOS 实现；鸿蒙改用内存缓存，保留占位、错误图及其他平台行为（`6760e10`）。

## 验证现状与限制

- 本轮通过：上述自动化测试、服务端编译、后台脚本语法、Flutter静态检查，以及隔离HTTP/SQLite后端集成测试。
- 历史覆盖：鸿蒙 API 24 模拟器业务交互；本轮无可连接设备，没有重做该项。模拟器宿主崩溃根因未完全确认。
- 未覆盖：物理真机验收、系统推送实际送达、生产部署。
- 已支持按技能和休假匹配维修人手，技能由师傅自行登记，不代表资质认证；暂不支持跨小时长维修，容量配置并发保护已通过本地验收，实际试点容量仍待压测。
- 普通改约由一次合法回应生效，没有“住户和师傅各确认一次”的机制；首次定时只允许住户回应。急单调度和物业顺延属于立即生效的运营调整。
- 大页面文件、全量读取后分页仍有维护与规模限制；无回执的旧版房屋、报修和访客创建仍不保证重试去重，旧客户端不传版本的房屋编辑和删除会被拒绝，须配套更新；正式客户端支持策略及其他业务的删除契约核对仍待补齐，生产化进展与验收边界见 `docs/enterprise_readiness_goals.md`。

## 开发历程

这些分支是沿同一条提交历史推进的阶段记录。`main` 汇集完整项目，其余分支保留作过程参考；旧分支名不代表当前最新功能。按提交内容核对如下：

- `main`：从 `14589a2` 工程初始化快进到完整业务及本文档。
- `dev`（`4e3250d`）：基础页面、公告、登录、Token 刷新与账号状态。
- `feature/tencent-location`（`e36992b`）：腾讯定位和社区 → 楼栋 → 房间 → 房屋表单。
- `feature/house-management`（`8f34902`）：房屋详情 / 编辑 / 删除、类型和表单校验、核心测试。
- `feature/complete-pending-functions`（`d07b8c5`）：报修、访客、鸿蒙分享以及请求和会话可靠性改进。
- `feature/repair-list-improvements`：远端停在 `6994d79`（自建后端及权限流程）；本地阶段指针为 `6eda645`，继续包含确认 / 改约 / 售后及推送接入，本次未推此分支。
- `feature/repair-refactor-slot-scheduling`：`01bd335` 拆分报修与时段规则、`998074e` 物业调度及容量网页、`bea02bb` 住户 / 师傅预约交互，再补充本 README。
