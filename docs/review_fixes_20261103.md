# 代码审查问题修复记录（2026-11-03）

工作目录：`D:\haven_hub`；分支：`feature/optimization-followups`；HEAD：`4bc28329f9b042cc35102b56834b140b928e2d4a`。本次基于已有未提交工作区增量修改，未提交、推送或新增依赖。

## 逐项修复与回归测试

| 问题 | 修改文件 | 修复结果及对应测试 |
| --- | --- | --- |
| 1. 代理登录限流、续期误登出 | `server/src/config.ts`、`server/src/app.ts`、`server/.env.example`、`server/.env.production.example`；`lib/utils/request_dio.dart` | 新增代理跳数 `TRUST_PROXY`（0—8），开发默认0，生产未显式配置即拒绝启动；按配置取得真实来源IP。刷新凭证只有HTTP 401/403明确拒绝才清会话，429、503、超时、断网、响应不完整和本机保存失败均保留会话并报告网络错误。`server/test/shared/trust-proxy.test.ts`验证两个来源分别限流及默认忽略伪造转发；`server/test/operations/config-validation.test.ts`验证配置边界；`test/auth/token_refresh_retry_test.dart`新增429/503及其他暂时失败不登出测试。生产测试配置同步修改`server/test/auth/sms-fixture.ts`。 |
| 2. 后台版本硬编码 | `server/src/app.ts`；`server/public/admin/app.js`、`audit.js`、`index.html`、`audit.html`；`tool/check_project.ps1` | 两个页面先加载同一服务端`/admin/client-version.js`，使用与本次服务配套的版本值；普通后台和审计页均消除1.0.0硬编码。`server/test/shared/client-compatibility.test.ts`的`every requesting admin page uses the shared server version after the minimum is raised`枚举所有含fetch的脚本，检查加载顺序，最低版本提高到9.4.2后分别实际请求房屋管理与审计API并断言200；全量检查还对admin下全部JS执行语法检查。 |
| 3. 受保护图片续期重试、取消令牌归属 | `lib/utils/request_dio.dart` | 同一会话401刷新成功后只重读一次；只取消自身创建的CancelToken。`test/shared/protected_media_test.dart`新增`401 refreshes credentials once and retries the private image`，检查新旧Authorization与成功字节；新增调用方CancelToken未被取消测试。 |
| 4. 创建房屋、访客的明确失败 | `lib/utils/app_exception.dart`、`lib/pages/house/house_form.dart`、`lib/pages/visitor/visitor_pages.dart` | 业务拒绝及明确4xx清理自身回执；408、超时、断网、5xx及换号继续保留。40002显示到姓名栏，修改姓名后可重新提交；本机清理失败继续保留回执并提示。`test/house/house_submission_test.dart`和`test/visitor/visitor_submission_test.dart`分别新增创建40002→清回执→姓名栏报错→修改再提交用例；再提交503仍保留回执。房屋测试另覆盖错误分类边界。 |
| 5. 报修草稿覆盖已发送回执 | `lib/utils/repair_draft_store.dart`、`lib/pages/repair/repair_pages.dart` | 保存时原子核对已有回执，跨存储实例串行读写；不同待确认回执拒绝覆盖，已确认失败/停止时按原提交ID授权清除。页面恢复原回执并提示先处理，提供查看结果入口。`test/repair/repair_draft_store_test.dart`新增交替保存和并发保存用例；`test/repair/repair_submission_test.dart`新增另一表单已发送回执后的提示及保留用例，并同步测试替身签名。 |
| 6. 报修弹窗使用打开时版本 | `lib/pages/repair/repair_pages.dart` | 还没修好、售后返修、反馈、改约、回应改约均保留打开弹窗前的工单快照，确认时比对ID及revision；变化就提示状态已更新并刷新，发送次数为0。`test/repair/repair_action_snapshot_test.dart`包含上述五种操作的独立widget测试，通过生命周期恢复模拟弹窗期间刷新到新版本。 |
| 7. 重开后的房屋待确认入口 | `lib/pages/house/house_list.dart`、`lib/controller/build_controller.dart` | 房屋列表启动即按当前用户加载回执并显示查看结果，添加房屋也会先核对；从回执恢复已丢失的内存草稿，直接进入真实结果页，保留仍存在的编辑草稿。换号后隐藏旧账号回执。`test/house/house_submission_test.dart`的`restarted house list exposes pending receipt without selecting a room again`清空控制器后经真实HouseForm查询原提交，另测换号隐藏；`test/shared/mutation_list_test.dart`为新增身份读取注入测试用户，避免测试意外请求真实接口。 |
| 8. 强杀遗留锁、释放第二把锁 | 新增`server/src/process-lock.ts`；修改`runtime-log.ts`、`backup-job.ts`、`operations-monitor.ts`、`operations-monitor-state.ts`、`main.ts`及`server/tool/backup-job.ts`、`operations-monitor.ts` | 锁记录PID、进程启动时间和唯一runId；仅确认进程已不存在才接管并记录恢复日志，活进程或无法确定归属时明确报锁被占用。回收过程使用独占声明避免竞争者删除新锁；中断的回收声明也可恢复。备份finally逐把释放并汇总失败。`server/test/operations/runtime-log.test.ts`改为强杀后可重启且历史保留；新增`server/test/operations/process-lock.test.ts`验证归属、死进程及回收竞争；`backup-job.test.ts`验证活锁、死锁和首把释放失败仍释放第二把；`operations-monitor.test.ts`验证含中断回收声明的重启与故障记录保留。 |
| 9. 旧备份重复解密及明文暂存 | `server/src/backup.ts`、`encrypted-backup.ts`、`backup-job.ts`；`server/tool/backup-job.ts`；`docs/backup_restore_runbook.md` | 默认只完整校验新快照及其副本，旧快照只检查有上限的认证清单、目录和文件；`--verify-all`另行完整检查旧快照。明文暂存位于备份根目录私有子目录，正常成功和失败均清理。新备份成功但历史异常返回status=warning/退出码2，异常快照保留并记入异常清单，其他过期合格快照照常清理。`server/test/operations/backup-job.test.ts`新增默认跳过旧数据库解密、显式检查发现并记住损坏、告警时继续清理及真实CLI退出2用例；`server/test/operations/encrypted-backup.test.ts`新增实际拦截明文落盘路径/权限/清理用例，并将清理断言移到备份根目录。 |

上表第8项未逐一重复前缀的源码均位于`server/src/`，测试均位于`server/test/`。

## 附带要求

- `third_party/image_picker_ohos/ohos/BuildProfile.ets`按HEAD原样恢复，`release`、`DEBUG=false`，该文件已没有Git差异。
- 开发/测试模式的`PUBLIC_BASE_URL`必须使用本机回环地址，公网来源拒绝启动；对应新增回归在`server/test/operations/config-validation.test.ts`。`server/test/auth/auth-security.test.ts`的开发库隔离场景改用回环来源，以继续实际验证生产库不能被开发模式打开。
- `server/.env.production.example`的`HUAWEI_PUSH_TEST_MESSAGE=false`。
- `README.md`测试章节只保留本轮全量检查数字与实际验证范围，旧的性能实验数字及旧验收数字已移出本节。

## 回归测试的失败/通过对照

保留工作区内容，临时恢复所报告的故障行为，运行相同测试，再用逆向补丁恢复修复并复跑。该对照属于受控故障注入；没有将整个工作区重置为旧提交，也不将其描述为旧分支原样构建。注入清单和执行脚本保存在下面的本机证据目录。

| 对照 | 服务端 | Flutter | 合计 |
| --- | --- | --- | --- |
| 恢复故障行为 | 0通过、10失败 | 0通过、15失败 | 25条均按预期失败 |
| 还原修复后 | 10通过、0失败 | 15通过、0失败 | 25通过、0失败 |

九项问题都有对应失败断言；另有用例覆盖暂时刷新失败、默认不信任转发及历史损坏告警。房屋入口在改用真实表单后，还实际暴露并修复了内存草稿不存在时入口失效的问题。

本机证据根目录：`C:\Users\23203\AppData\Local\Temp\haven-review-fixes-20261103`。

- `mutations.json`：只临时替换本次修复行为的清单。
- `run-regressions.ps1`：对照测试的实际命令。
- `regression-red/server.log`、`regression-red/flutter.log`：故障行为的失败日志。
- `regression-green/server.log`、`regression-green/flutter.log`：恢复修复后的通过日志。

## 全量检查

实际命令：`pwsh -File tool/check_project.ps1 -SkipRestore -LogDirectory C:/Users/23203/AppData/Local/Temp/haven-review-fixes-20261103/verified-checks`；退出码0。

| 检查 | 实际结果 | 日志（相对下述目录） |
| --- | --- | --- |
| 后端测试 | 664通过、0失败、0跳过 | `server-test.log` |
| Flutter测试 | 639通过、0失败、1跳过 | `flutter-test.log` |
| 隔离真实后端联调 | 1通过、0失败 | `integration.log`及`integration/` |
| 合计实际通过 | 1304通过、0失败 | 默认跳过的集成用例在最后一步已显式执行，不重复计数 |
| 依赖安全审计 | 0 vulnerabilities | `server-audit.log` |
| 服务端构建 | 通过 | `server-build.log` |
| 全部admin脚本语法 | 通过 | `admin-syntax.log` |
| Flutter版本核对与静态检查 | 通过，No issues found | `flutter-version.log`、`flutter-analyze.log` |

最终日志目录：`C:\Users\23203\AppData\Local\Temp\haven-review-fixes-20261103\verified-checks`。

此前的检查也保留：`check-1`在后端663通过/1失败时停止，原因是旧测试的公网开发来源被新增保护正确拦截；`check-2`后端664通过，Flutter637通过/1失败/1跳过，发现真实房屋回执入口仍依赖已消失的内存草稿；这两处已修复。`final-checks`曾完整通过664项后端、638项Flutter及1项隔离后端联调；之后补齐监控回收声明兼容与4xx/超时分类断言，最终数字以`verified-checks`为准。

## 未修问题与验证边界

九项及附带修复均已实现，没有跳过项。

默认备份不会解密旧数据库，因此无法发现所有旧数据库密文位翻转；需要按手册运行`--verify-all`，已发现异常的快照会持续保留。PID仍存在（包括可能复用）、权限不足或锁记录损坏时采取不接管策略，明确提示占锁，避免覆盖活进程。

本轮证据来自本机自动化测试、构建、静态检查、脚本语法及隔离HTTP/SQLite联调；不包含浏览器交互、真机、实际短信收信、生产部署或远程CI验收。
