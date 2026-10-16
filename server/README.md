# 享家本地学习后端

TypeScript + Express 5 + Node 24 内置 SQLite。配合现有 Flutter / HarmonyOS 客户端学习接口、鉴权和数据库，不是星檬的内部技术实现。

## 启动

在项目根目录 `D:\haven_hub`：

```powershell
cd server
npm ci
npm run build
npm start
```

默认监听 `http://127.0.0.1:3000`，首次启动自动建表，数据库在 `server/data/haven.sqlite`。停止服务用 Ctrl+C；再次启动数据仍在。Node.js 要求 24 或更高版本，内置 SQLite 可能显示实验性提示。开发时可用 `npm run dev` 自动重启。

需要自定义时，将 `.env.example` 复制为 `.env` 后编辑；无需填写任何短信或模型密钥。这个服务仅提供开发验证码，拒绝 `NODE_ENV=production`，不能直接部署到公网。

## 连接 App：保留真实腾讯地图

继续使用已有 `tool/dart_defines.local.env` 中的腾讯地图 Key，不修改或复制其中的秘密。编译时覆盖业务 API 地址并设置独立的本地登录凭证空间：

```powershell
# 在 D:\haven_hub，开发模式运行 Web
.\tool\flutter_ohos.ps1 run -d chrome --web-port=8080 --dart-define=LOCAL_BACKEND=true --dart-define=API_BASE_URL=http://127.0.0.1:3000/ --dart-define=TENCENT_MAP_API_BASE_URL=http://127.0.0.1:3001/tencent-map/
```

Web 还需要原有腾讯地图代理；在另一个终端，使用 Flutter OH SDK 自带的 Dart：

```powershell
# 本机已安装的 SDK 路径；更换电脑后调整路径
& 'C:\flutter_flutter_3.41.10_ohos\bin\dart.bat' run tool/web_api_proxy.dart 3001
```

这个 Web 配置的业务请求走 3000，只有腾讯地图请求走 3001。GPS、IP 定位与小区查找继续调用腾讯服务；腾讯 Key 的配额、权限和可用性仍按原配置处理。

鸿蒙模拟器或手机上的 `127.0.0.1` 指设备自己，不能直接当成电脑。可采用以下方式：

1. 使用 HDC 的设备到主机端口转发，让设备的 3000 对应电脑的 3000（按当前 HDC 版本的 `rport` 帮助操作）。
2. 或在可信局域网中配置服务 `.env` 的 `HOST=0.0.0.0`、`PUBLIC_BASE_URL=http://电脑局域网IP:3000`，App 的 `API_BASE_URL` 使用同一个地址。需要 Windows 防火墙允许访问该端口。

原生鸿蒙保持腾讯地图直连，不传 Web 的 `TENCENT_MAP_API_BASE_URL` 覆盖。这个仓库默认仍连接课程接口；只有显式 `LOCAL_BACKEND=true` 并覆盖 API 地址的构建连接自建服务。本地 Token 与课程 Token 分开保存。首次切换本地服务需要重新登录；数据库换新后旧本地 Token 也需要重新登录。

## 使用流程

1. 启动后端和 App，进入登录页，输入格式正确的虚构手机号，点击获取验证码。
2. 后端生成随机六位开发码，返回 `development: true`；Debug App 自动填入，不发送短信。验证码五分钟有效，获取间隔60秒，五次输错后需重新获取。
3. 首次登录自动创建账号。账号开始时没有房屋；通过原有腾讯地图选小区，再选择楼栋、房间，上传两张示例图片完成添加。
4. 新增/编辑房屋统一进入“待审核”。物业后台可“通过”或填写原因后“打回”；住户修改同一份资料并重新提交。状态为“待审核、已通过、已打回”。
5. 提交报修返回最新完整列表；取消保留历史记录，状态变成“已取消”。创建访客也返回完整列表，并生成带 `LOCAL DEMO` 标识的 PNG 二维码，仅作展示和系统分享测试，不接真实门禁，也不实现自动核销/到期调度。

图片限8MB，服务端实际解码校验，限制1600万像素，转为最长边2048的PNG并去除元数据。为兼容现有图片组件和系统分享，图片通过随机256位地址读取；持有链接即可访问。此学习服务请只使用示例图片和虚构资料，不能作为真实证件托管服务。

## 接口与完整列表契约

成功响应仍是 `{ "code": 10000, "message": "成功", "data": ... }`。已知业务校验失败用非10000业务码；认证失效返回HTTP401，未知资源404，限流429。内部错误不把数据库或调用栈返回给用户。日志只记请求ID、方法、状态、耗时，不记录手机号、验证码、Token或请求体。

| 方法与路径 | 数据 |
|---|---|
| GET `/code?mobile=...`、POST `/login` | 开发验证码、Token和Refresh Token |
| POST `/refreshToken` | Bearer携带Refresh Token；轮换两种凭证，旧凭证作废 |
| GET/PUT `/userInfo` | 当前账号资料；修改返回完整资料 |
| POST `/upload` | multipart字段`file`，可选`type=avatar`；返回图片URL |
| GET `/announcement`、GET `/announcement/:id` | 本地示例公告 |
| GET `/room`、GET `/room/:id` | 当前用户房屋列表、详情 |
| POST `/room`、DELETE `/room/:id` | 新增/编辑/删除，返回完整房屋列表 |
| GET `/repairItem`、GET `/repair`、GET `/repair/:id` | 维修项目、分页报修历史、详情 |
| POST `/repair`、PUT `/cancel/repaire/:id` | 新增/取消报修，返回完整报修列表；保留既有路径拼写 |
| GET `/visitor`、GET `/visitor/:id`、POST `/visitor` | 访客列表、详情、创建；创建返回完整列表 |
| GET `/health`、GET `/ready` | 服务模式、数据库可用性 |

三个集合的写接口返回：

```json
{
  "code": 10000,
  "message": "成功",
  "data": {
    "complete": true,
    "total": 1,
    "rows": [{ "id": "记录ID", "status": 1 }]
  }
}
```

示例只省略业务字段；真实行包含列表/详情所需字段。`rows` 是当前账号全部记录，按创建顺序倒序，编辑和取消不改变创建顺序。删除最后一条返回空数组和`total: 0`。

SQLite短事务中依次执行校验、写入、读取完整列表，再提交。如果构造列表失败，整个事务回滚。事务成功但响应在网络中丢失，客户端仍无法确认结果；现有报修“结果未确认”提示继续保留。本版未实现请求幂等键，不承诺断网重试绝不重复。

Flutter 的 `lib/utils/mutation_list.dart` 将这份响应暂存给下一次列表加载，消费一次后丢弃，后续手动刷新重新GET。普通分页响应不进入此通道；列表不完整、解析失败、响应过期、会话变化或并发写顺序不明确时重新查询。解析列表失败不把已成功的写入改报成提交失败。房屋编辑返回详情时可直接从该列表读取对应记录。

## 数据和代码入口

- `src/app.ts`：HTTP路由、请求校验、上传、响应与错误出口。
- `src/auth.ts`：开发验证码、账号、访问凭证与刷新凭证；数据库仅存Token哈希。
- `src/community.ts`：房屋/报修/访客规则，账号权限，写入后返回完整列表。
- `src/database.ts`：SQLite建表迁移、参数化SQL、事务。`users/sessions/codes/uploads` 保存基础数据；`rooms/repairs/visitors` 各自保存ID、账号、顺序以及校验过的JSON业务字段。
- `src/config.ts`：集中读取并校验环境变量。

这是小数据量本地学习服务：同步数据库连接串行处理短事务，没有连接池、分布式缓存、真实短信或音频转写引擎。物业后台位于 `/admin/`；维修人员使用 App 内独立工作台。完整列表会随记录量增长而增大；更大规模时应评估分页或返回变更记录。

## 房屋审核与报修派单

报修的五个可视节点为：住户申请 → 物业派单 → 待接单 → 处理中 → 已完成。物业派单后由被指派的师傅接单，接单直接进入处理中，师傅本人提交完成。

首次配置物业账号（在 `server` 目录运行；使用你选定的开发手机号）：

```powershell
npm run role -- 19900000002 admin
npm run build
npm start
```

浏览器访问 `http://127.0.0.1:3000/admin/`，使用该手机号和开发验证码登录。后台“维修人员”可添加师傅的姓名和独立登录手机号。师傅在连接同一服务的 App 登录后自动进入维修工作台。角色由后端校验，普通登录和个人资料接口不能自行提升权限。

独立演示环境使用 `npm run demo`，端口3010，数据库 `data/workflow-demo.sqlite`，不会修改 `data/haven.sqlite`。内置虚构账号：住户19900000001、物业19900000002、师傅19900000003。首次启动创建示例房屋和报修，后续启动保留操作结果。

维修工作台网页先在项目根目录构建一次：`.\tool\build_workflow_web.ps1`。随后在 `server` 目录运行 `npm run demo`，同一个服务提供物业后台 `http://127.0.0.1:3010/admin/` 和师傅入口 `http://127.0.0.1:3010/workflow/#/worker`。师傅使用 `19900000003` 获取开发验证码并登录，验证码会自动填入。终端需要保持运行；不要双击 HTML 文件或使用 `file://` 地址。修改 Flutter 页面后重新构建再刷新。

数据库启动时将旧版迁移到版本2，给已有账号补充默认住户角色。房屋审核及报修操作携带 `revision`，旧页面重复操作或并发覆盖返回409，刷新后再处理。新建报修最多8张本人已上传的照片；同一张报修单保留派单、接单、完成的真实时间。物业可在师傅接单前重新派单，完成后不可再次处理；住户只可在物业派单前取消。

## 验证

```powershell
# server目录
npm run build
npm test

# 项目根目录，普通测试不会访问后端
.\tool\flutter_ohos.ps1 analyze --no-pub
.\tool\flutter_ohos.ps1 test --no-pub

# 先启动本地服务，再显式运行真实Dart接口联调；只允许回环地址
.\tool\flutter_ohos.ps1 test --no-pub test/local_backend_integration_test.dart --dart-define=RUN_LOCAL_BACKEND_TEST=true --dart-define=LOCAL_BACKEND=true --dart-define=API_BASE_URL=http://127.0.0.1:3000/
```

联调测试会创建虚构账号和测试记录。可给服务设置`DATABASE_PATH=data/integration.sqlite`隔离测试数据库。后端测试使用独立临时数据库，验证重启持久化、越权拒绝、验证码、Token轮换、超过20条的完整列表、上传和事务回滚；Flutter测试检查写后不追加GET、列表实际更新、手动刷新、账号变化和迟到读取。构建与自动测试不等于鸿蒙设备验收。
