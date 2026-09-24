# Haven Hub

享家社区 Flutter 项目 - 社区物业管理移动应用。

## 分支导览（面试阅读入口）

这些分支记录项目逐步扩展的开发阶段，后续分支继承前序功能，并非互相隔离的单模块示例。下表按已提交代码说明各分支的重点；分支名不代表该功能已经通过真实接口、设备或发布验收。

| 分支 | 中文说明 | 主要内容与面试讲解重点 |
| --- | --- | --- |
| `main` | 项目初始化 | Flutter 工程及 OpenHarmony、Web 平台基础配置。适合介绍项目结构与平台入口；当前停留在初始化阶段，不是完整业务展示版本。 |
| `dev` | 基础业务与登录状态 | 首页与公告详情、验证码登录、个人资料、Token 刷新和账户状态同步。重点讲解请求封装、登录态管理与页面访问控制。 |
| `feature/tencent-location` | 腾讯定位与选房流程 | 在基础业务上增加腾讯位置服务与房屋录入：位置 → 楼栋 → 房间 → 房屋表单。重点讲解定位权限、位置搜索与跨页面选房状态传递。 |
| `feature/house-management` | 房屋管理与表单校验 | 增加房屋详情、编辑、删除与表单校验，并整理类型化路由、数据模型、通用组件和核心逻辑测试。重点讲解数据校验、页面参数和业务代码复用。 |
| `feature/complete-pending-functions` | 报修与访客管理 | 在房屋管理基础上增加报修提交、列表、详情、取消，以及访客登记、列表与详情。重点讲解表单提交、业务状态展示和操作后的列表更新。 |

推荐阅读顺序：`main` → `dev` → `feature/tencent-location` → `feature/house-management` → `feature/complete-pending-functions`。希望先看当前已提交业务范围时，可从最后一个分支入手，再回看前序阶段。

**开发中内容（截至 2026-09-20）：** 访客通行码鸿蒙系统分享、报修稳定性补充改造和新增回归测试尚未提交，不属于上表分支现有提交的交付内容。面试介绍时应分别说明代码实现、自动化测试结果、真实接口联调和设备验证情况。

**分支名称与可见性：** 房屋管理分支统一使用 `feature/house-management`。本导览位于 `feature/complete-pending-functions` 分支的 README，其他分支的 README 保留各自阶段的内容；Git 的本地 `branch.description` 不会随普通推送发布。

## 项目概述

Haven Hub 是一个基于 Flutter 开发的社区物业管理应用，支持多平台部署（Android、iOS、HarmonyOS、Web）。
主要功能包括：

- 用户认证与个人信息管理
- 房屋信息录入与审核
- 社区公告浏览
- 基于腾讯位置服务的智能选址

## 房屋业务流程

登录后可从“我的”进入“我的房屋”，支持以下完整流程：

```text
房屋列表 → 房屋详情 → 编辑 → 保存
添加房屋 → 位置 → 楼栋 → 房间 → 房屋表单 → 提交审核
房屋详情 → 删除房屋 → 返回房屋列表
```

房屋相关页面统一使用 `AppRoutes` 中的路由常量，避免直接拼接旧路径。房屋详情和编辑表单通过类型化参数传递房屋 ID。

## 项目结构

```
lib/
├── api/              # API 接口层
│   ├── home.dart    # 首页相关接口
│   ├── house.dart   # 房屋管理接口
│   ├── location.dart # 腾讯位置服务接口
│   └── user.dart    # 用户相关接口
├── constant/         # 常量定义
│   ├── index.dart   # 全局常量和配置
│   └── tab_config.dart # 底部导航配置
├── controller/       # GetX 状态控制器
│   ├── build_controller.dart # 选楼流程状态
│   └── user_info_controller.dart # 用户信息状态
├── models/          # 数据模型
│   ├── building_info.dart # 建筑信息模型
│   ├── house.dart   # 房屋信息模型
│   ├── notice_data.dart # 公告数据模型
│   └── user_info.dart # 用户信息模型
├── pages/           # 页面组件
│   ├── building/    # 楼栋选择
│   ├── home/        # 首页
│   ├── house/       # 房屋管理
│   ├── location/    # 位置选择
│   ├── login/       # 登录
│   ├── mine/        # 我的
│   ├── not_found/   # 404页面
│   ├── notice_detail/ # 公告详情
│   ├── profile/     # 个人资料
│   ├── room/        # 房间选择
│   └── tabs_page/   # 底部导航容器
├── platform/        # 平台适配层
│   ├── avatar_picker.dart # 头像选择器
│   ├── local_image.dart # 本地图片加载接口
│   └── local_image_io.dart # IO平台实现
├── router/          # 路由配置
│   └── index.dart   # 路由表
├── theme/           # 主题配置
│   ├── app_colors.dart # 颜色常量
│   └── app_theme.dart # 主题定义
├── utils/           # 工具类
│   ├── app_exception.dart # 异常定义
│   ├── emitter.dart # 事件总线
│   ├── location.dart # 位置工具
│   ├── request_dio.dart # 网络请求封装
│   ├── toast.dart   # Toast提示
│   └── token_manager.dart # Token管理
├── widgets/         # 通用组件
│   ├── async_state_view.dart # 异步状态视图
│   ├── camera_dialog.dart # 相机选择对话框
│   ├── community_picker.dart # 社区选择器
│   ├── house_status_tag.dart # 房屋状态标签
│   ├── loading_state_mixin.dart # 加载状态Mixin
│   └── section_title.dart # 区域标题
└── main.dart        # 应用入口
```

## 技术栈

- **框架**: Flutter 3.6+
- **状态管理**: GetX
- **网络请求**: Dio
- **本地存储**: SharedPreferences
- **位置服务**: Geolocator + 腾讯地图API
- **权限管理**: PermissionHandler
- **图片选择**: ImagePicker

## 代码质量

- ✅ 类型安全：全面使用 Dart 3 null safety
- ✅ 错误处理：统一的异常处理机制
- ✅ 文档注释：公共API均有详细文档
- ✅ 代码规范：遵循 Flutter Lints 规则
- ✅ 静态检查：`flutter analyze --no-pub --no-fatal-infos` 无编译错误
- 自动化测试位于 `test/`，覆盖基础逻辑、报修交互、路由返回值、提示浮层、通行码下载与平台桥接；真实接口与鸿蒙设备效果单独验收。

## 鸿蒙分享与稳定性改造

访客详情支持通过应用内自定义 MethodChannel 调用鸿蒙系统分享现有 PNG/JPEG 通行码图片。
非鸿蒙平台显示不可用提示；已访问、已失效或缺少图片的记录不能分享。
分享面板关闭仅表示本次操作结束，不提示“发送成功”。报修流程补充了提交、取消、失败重试、返回后刷新和异步退出的回归测试。

运行检查：`./tool/flutter_ohos.ps1 analyze --no-pub`、`./tool/flutter_ohos.ps1 test --no-pub`。
实现调用链、复现命令、验证边界与面试讲解见 [鸿蒙分享与报修稳定性说明](docs/harmony_share_and_reliability.md)。

## 最近优化 (2026-08-05)

### 架构优化
- ✅ 将 `BuildController` 的 Map 存储改为类型安全的 `BuildingInfo` 模型
- ✅ 优化搜索过滤性能，添加结果缓存避免重复计算
- ✅ 创建 `LoadingStateMixin` 统一异步加载状态管理

### 代码质量提升
- ✅ 为所有公共API添加详细文档注释
- ✅ 增强 `analysis_options.yaml`，启用更严格的lint规则
- ✅ 改进异常类文档和示例
- ✅ 为 `House` 模型添加便捷属性方法

### 性能优化
- ✅ `location_list` 搜索过滤添加缓存机制
- ✅ 增加 const 构造函数使用

详细优化内容请查看 [OPTIMIZATION_REPORT.md](OPTIMIZATION_REPORT.md)

## 快速开始

### Web/桌面浏览器真实验证

课程接口的登录验证码接口在测试环境会直接返回测试验证码，手机号只需符合手机号格式即可。启动 Web 调试代理后运行 Flutter Web：

```powershell
dart run tool/web_api_proxy.dart
flutter run -d web-server --web-port 8767 `
  --dart-define=API_BASE_URL=http://127.0.0.1:3001/ `
  --dart-define=TENCENT_MAP_API_BASE_URL=http://127.0.0.1:3001/tencent-map/ `
  --dart-define=TENCENT_MAP_KEY=你的腾讯位置服务Key
```

`TENCENT_MAP_KEY` 不能省：位置页在发起请求前就要用它，缺失时页面会停在
“正在获取当前位置”，并提示“未配置腾讯位置服务 Key”，一个 `/tencent-map/`
请求都不会发出。本机调试通常改用下面「Web 连接课程接口」里的
`--dart-define-from-file` 写法，把 Key 放在 Git 忽略的
`tool/dart_defines.local.env` 里。

浏览器验证建议按“登录 → 我的房屋 → 房屋列表/详情/编辑 → 添加房屋 → 位置/楼栋/房间/表单”的顺序执行。Web 环境会优先请求浏览器定位权限，权限不可用或超时会自动切换为腾讯 IP 定位。IP 定位结果可能落在境外；如果没有返回附近社区，这是定位数据没有匹配到社区，不代表楼栋、房间或表单路由异常。

## API 环境切换

默认请求课程接口：

```text
https://live-api.itheima.net/
```

可以使用 `API_BASE_URL` 编译参数切换接口，不需要修改源代码：

```powershell
flutter run --dart-define=API_BASE_URL=https://example.com/
```

地址需要以 `/` 结尾。

### Web 连接课程接口

课程接口没有开放浏览器跨域访问，Flutter Web 直接请求时会被 CORS
拦截。Web 调试需要先在一个终端启动项目自带的本机代理：

```powershell
dart run tool/web_api_proxy.dart
```

再在另一个终端启动 Flutter Web，并将接口地址切换到代理：

```powershell
flutter run -d chrome `
  --dart-define-from-file=tool/dart_defines.web.local.env `
  --dart-define-from-file=tool/dart_defines.local.env
```

使用内置浏览器或手动打开网址时，也可以启动 Web Server：

```powershell
flutter run -d web-server --web-port 56891 `
  --dart-define-from-file=tool/dart_defines.web.local.env `
  --dart-define-from-file=tool/dart_defines.local.env
```

两个文件都要传。`dart_defines.web.local.env` 只放两个代理地址，
`TENCENT_MAP_KEY` 在 `dart_defines.local.env` 里（该文件被 Git 忽略）。
只传前者时应用能正常启动，但位置页会停在“正在获取当前位置”，并且不会发出
任何 `/tencent-map/` 请求。

该代理仅监听 `127.0.0.1`，只接受来自 `localhost` 或 `127.0.0.1`
网页的请求，并分别固定转发到课程接口和腾讯位置服务。它只用于本机开发，不应部署到线上。
鸿蒙和其他原生平台仍可直接使用默认课程接口。

## 本地 Mock 接口

课程接口不可用时，可以先启动项目自带的 Mock 服务：

```powershell
dart run tool/mock_api_server.dart
```

Web 或 Windows 调试：

```powershell
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:3000/
```

鸿蒙真机调试时，将 `127.0.0.1` 换成电脑的局域网 IPv4 地址，并允许
Windows 防火墙访问 3000 端口：

```powershell
.\tool\flutter_ohos.ps1 run `
  --dart-define=API_BASE_URL=http://192.168.1.100:3000/
```

Mock 服务提供以下接口：

- `GET /announcement`
- `GET /announcement/{id}`

响应结构与课程接口一致，业务成功码为 `10000`。

## 鸿蒙构建

当前本机目标版本为 HarmonyOS 6.1.1 / API 24，最低兼容配置为
HarmonyOS 5.0.0 / API 12。最低版本配置和编译通过不等于已完成 API 12
设备运行验收；本次验证记录见 [API 24 验证与清理](docs/api24_validation_and_cleanup.md)。

本机 `ohos/build-profile.json5` 带有 Git `skip-worktree` 标记，普通
`git status` 不显示其本地版本字段变更。换机时需单独检查这两个版本字段，
不要为了同步版本而提交本机签名材料。

请通过包装脚本执行鸿蒙命令。脚本会自动查找本机的 Flutter OH SDK，
并使用项目所在 D 盘的依赖缓存，避免 Hvigor 因跨盘插件路径构建失败：

```powershell
.\tool\flutter_ohos.ps1 doctor -v
.\tool\flutter_ohos.ps1 pub get
.\tool\flutter_ohos.ps1 analyze --no-pub
.\tool\flutter_ohos.ps1 test --no-pub
# 手机目标
.\tool\flutter_ohos.ps1 build hap --debug --no-pub -t lib/main.dart --target-platform ohos-arm64
# x86_64 模拟器目标
.\tool\flutter_ohos.ps1 build hap --debug --no-pub -t lib/main.dart --target-platform ohos-x64
```

静态分析也必须通过包装脚本执行。项目内的 `analysis_options.yaml` 已排除
鸿蒙构建生成目录、依赖缓存及其 Junction，避免全项目分析递归扫描数万个
非业务 Dart 文件而长时间无响应。

自动查找失败或电脑安装了多个 Flutter OH SDK 时，可以设置环境变量，
也可以为单次命令显式指定 SDK 根目录：

```powershell
$env:FLUTTER_OHOS_HOME = 'C:\flutter_flutter_3.41.10_ohos'
.\tool\flutter_ohos.ps1 doctor -v

.\tool\flutter_ohos.ps1 `
  -FlutterOhosSdk 'C:\flutter_flutter_3.41.10_ohos' `
  build hap --debug
```

Debug HAP 输出位置：

```text
build\ohos\hap\entry-default-signed.hap
```

不同架构和测试入口共用此输出路径，后一轮构建会覆盖前一轮；需要同时保留时，
每次构建完成后按架构和入口另存。分享测试入口验证结束后应重新安装正常入口包。

## 腾讯位置服务

“选择社区”页面使用 `geolocator` 获取 GPS 经纬度，再调用腾讯位置服务完成：

1. 自动区分真机 GPS（WGS84）和虚拟机拾取坐标（GCJ-02），仅在需要时转换坐标。
2. 逆地址解析，得到当前地址。
3. 地点周边搜索，得到附近社区列表，并在 Debug 控制台打印接口原始返回值。

腾讯控制台中需要创建用途为 **WebService API** 的 Key。调试时通过编译参数传入，
不要把 Key 直接写进 Dart 源码：

推荐只在本机配置一次：复制 `tool/dart_defines.example.env` 为
`tool/dart_defines.local.env`，然后填写真实 Key。`local` 文件已被 Git 忽略，
`tool/flutter_ohos.ps1` 启动时会自动加载：

```dotenv
TENCENT_MAP_KEY=你的腾讯位置服务Key
LOCATION_COORDINATE_SYSTEM=auto
```

之后每次只需要运行：

```powershell
.\tool\flutter_ohos.ps1 run
```

`flutter_ohos.ps1` 会在运行或打包前校验 `TENCENT_MAP_KEY` 是否有效；缺少
Key 时会直接停止构建，因此不会再安装一个进入“选择社区”后才提示未配置的包。
不要直接用 DevEco/Hvigor 的 HAP 构建按钮或裸 `flutter run`，它们不会自动读取
`dart_defines.local.env`。

正式发布时，将生产配置文件保存到 CI/CD 的 Secret 或发布机受保护路径，并通过同一
入口显式指定它：

```powershell
.\tool\flutter_ohos.ps1 `
  -DartDefinesFile 'C:\secure\haven-hub.release.env' `
  build hap --release
```

生产配置文件与本地配置文件格式相同，且必须包含 `TENCENT_MAP_KEY`；不要提交到 Git。

也可以不创建本地配置文件，临时通过命令行覆盖：

```powershell
.\tool\flutter_ohos.ps1 run `
  --dart-define=TENCENT_MAP_KEY=你的腾讯位置服务Key
```

当前调用的官方接口为：

- `GET https://apis.map.qq.com/ws/coord/v1/translate`
- `GET https://apis.map.qq.com/ws/geocoder/v1/`
- `GET https://apis.map.qq.com/ws/place/v1/search`
- `GET https://apis.map.qq.com/ws/location/v1/ip`

腾讯 WebService API 不允许浏览器直接跨域调用。Web 调试时需要同时启动上面的
本机代理，并传入：

```powershell
--dart-define=TENCENT_MAP_API_BASE_URL=http://127.0.0.1:3001/tencent-map/
```

原生和鸿蒙端不要设置该参数，会继续直连腾讯官方接口。

移动端包内的编译参数仍可能被逆向获取。正式环境应由业务后端保存 Key，App 只调用
自己的后端接口，由后端转发腾讯位置服务请求并限制调用频率。

### 坐标拾取器与鸿蒙虚拟机

腾讯地图坐标拾取器：[https://lbs.qq.com/getPoint/](https://lbs.qq.com/getPoint/)

腾讯和高德坐标拾取器给出的坐标都是 GCJ-02。完整调试流程如下：

1. 在腾讯坐标拾取器中搜索目标地址，复制坐标。页面通常显示为“经度,纬度”。
2. 打开鸿蒙虚拟机的定位模拟面板，把纬度填入 `Latitude`，经度填入 `Longitude`，不要填反。
3. 设置坐标后，回到 App 点击“重新定位”。
4. 启动虚拟机调试时建议明确指定 `gcj02`，确保拾取器坐标不会被重复转换：

```powershell
.\tool\flutter_ohos.ps1 run `
  --dart-define="TENCENT_MAP_KEY=你的腾讯位置服务Key" `
  --dart-define="LOCATION_COORDINATE_SYSTEM=gcj02"
```

也可以写成一行：

```powershell
.\tool\flutter_ohos.ps1 run --dart-define="TENCENT_MAP_KEY=你的腾讯位置服务Key" --dart-define="LOCATION_COORDINATE_SYSTEM=gcj02"
```

`LOCATION_COORDINATE_SYSTEM` 支持以下值：

- `auto`（默认）：虚拟定位按 GCJ-02 处理，真机 GPS 按 WGS84 处理。
- `gcj02`：用于腾讯/高德坐标拾取器写入虚拟机的坐标，跳过坐标转换。
- `wgs84`：用于真机原始 GPS，先转换为腾讯地图使用的 GCJ-02。

如果虚拟机没有正确上报 `isMocked`，请使用上面的 `gcj02` 参数；真机调试通常不需要额外参数。
