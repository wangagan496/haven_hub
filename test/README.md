# 按业务查找和运行测试

Flutter 测试和 `server/test/` 都按功能、业务归类，同一业务下同时保留模型、接口和页面流程测试。

| 目录 | 负责的场景 |
| --- | --- |
| `auth/` | 登录验证码、会话、Token 存储与刷新、角色切换 |
| `house/` | 小区定位、楼栋楼层选择、房屋资料、草稿、提交、审核与删除 |
| `repair/` | 报修提交、预约排班、取消、改派、履约、售后与并发冲突 |
| `visitor/` | 访客邀请、提交回执、通行证图片与分享 |
| `worker/` | 师傅工作台、技能、工单列表与权限 |
| `notifications/` | 通知路由、推送订阅、投递与生命周期 |
| `shared/` | 跨业务请求、错误处理、公共组件和通用接口边界 |
| `helpers/` | 被多个业务使用的测试工具，不注册测试 |
| `integration/` | Flutter 到真实本机 HTTP 服务及 SQLite 的跨业务联调 |
| `server/test/management/` | 物业管理审计及管理页面 |
| `server/test/operations/` | 配置、备份恢复、监控、日志、维护、迁移与进程生命周期 |

报修专用数据放在各端的 `repair/`，短信专用数据放在服务端 `auth/`；只有跨业务复用的工具进入 `helpers/`。

## 运行方式

在仓库根目录运行 Flutter 全量或单个业务：

```powershell
pwsh -File ./tool/flutter_ohos.ps1 test --no-pub
pwsh -File ./tool/flutter_ohos.ps1 test --no-pub test/house
pwsh -File ./tool/flutter_ohos.ps1 test --no-pub test/repair
```

在 `server/` 目录运行服务端全量或单个业务；首次运行或服务端源码变化后先构建，部分测试会启动编译后的子进程：

```powershell
npm run build
npm test
npm exec -- tsx --test "test/house/*.test.ts"
npm exec -- tsx --test "test/repair/*.test.ts"
```

服务端每个 `.test.ts` 都能独立注册并运行用例，`npm test` 会递归发现业务目录中的测试；无需导入另一个测试文件来注册用例。

仓库根目录的 `tool/check_project.ps1` 仍是完整检查入口，`tool/test_local_backend.ps1` 单独启动隔离的临时服务并启用 `integration/local_backend_integration_test.dart`；普通 Flutter 测试不带联调开关时仍跳过该用例。

新增测试放入对应业务目录，以用户行为或接口约束命名；不再新建以开发阶段、修复批次或笼统优化为名的文件；已有文件名保留，方便对照历史记录。

## 本次迁移验证

2026-11-04：Flutter 全量 651 项通过，普通运行时保留 1 项联调条件跳过；服务端全量 666 项通过；该联调通过 `tool/test_local_backend.ps1` 单独启用后 1 项通过，实际通过共 1318 项；Flutter 静态检查和 TypeScript 构建通过。

服务端房屋业务目录单独运行 29 项通过，这 29 项已包含在全量结果中；迁移前后服务端 592 处静态测试声明内容一致，Flutter 73 个测试文件的用例名称和断言调用数量一致，参数化测试的实际数量以全量运行结果为准。
