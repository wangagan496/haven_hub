# Haven Hub 项目面试准备指南

> 本指南帮助你系统学习 Haven Hub 项目，掌握核心技术和业务逻辑，应对实习面试和笔试。

> 2026-10-20 更新：前半部分保留原学习笔记，历史分支、规模、行号与旧示例不作为现状承诺。求职介绍请优先使用文末“2026-10-20 求职补充”；当前以鸿蒙 / Web 入口为准，普通改约尚无双方分别确认模型，最新测试为服务端 253 通过、Flutter 402 通过 / 1 跳过。

## 📋 目录

- [项目概览](#项目概览)
- [核心技术栈](#核心技术栈)
- [架构设计](#架构设计)
- [业务模块详解](#业务模块详解)
- [关键技术点](#关键技术点)
- [面试高频问题](#面试高频问题)
- [实战演练](#实战演练)
- [学习路线图](#学习路线图)

---

## 项目概览

### 项目背景
Haven Hub（享家社区）是一个**社区物业管理移动应用**，基于 Flutter 开发，支持多平台部署（Android、iOS、HarmonyOS、Web）。

### 核心功能
- 用户认证与个人信息管理
- 房屋信息录入与审核管理
- 社区公告浏览
- 报修服务管理
- 访客登记与通行码分享
- 基于腾讯位置服务的智能选址

### 项目规模
- **代码量**：约 5,840 行 Dart 代码
- **测试覆盖**：32 个自动化测试用例
- **分支结构**：5 个主要功能分支，层层递进
- **平台适配**：支持 HarmonyOS API 24、Web、Android、iOS

---

## 核心技术栈

### 1. Flutter 框架
- **版本**：Flutter 3.6+，Dart 3.6.2
- **UI 框架**：Material Design
- **国际化**：`flutter_localizations`，支持中英文

### 2. 状态管理
- **GetX**：轻量级状态管理方案
  - `UserInfoController`：用户信息全局状态
  - `BuildController`：选房流程状态管理

### 3. 网络请求
- **Dio**：HTTP 客户端
  - 拦截器机制：Token 注入、日志记录、错误处理
  - Token 自动刷新机制
  - 401 重放机制

### 4. 本地存储
- **SharedPreferences**：Token 持久化存储

### 5. 位置服务
- **Geolocator**：获取设备 GPS 位置
- **腾讯位置服务 WebService API**：
  - 坐标转换（WGS84 ↔ GCJ-02）
  - 逆地址解析
  - 周边搜索

### 6. 权限管理
- **PermissionHandler**：统一权限请求

### 7. 图片处理
- **ImagePicker**：相机拍照和相册选择
- **CachedNetworkImage**：网络图片缓存

### 8. 鸿蒙平台
- **MethodChannel**：Flutter 与鸿蒙原生通信
- **系统分享**：鸿蒙 ShareController API

---

## 架构设计

### 整体架构

```
lib/
├── api/              # 接口层：网络请求封装
├── models/           # 数据模型层
├── pages/            # 页面视图层
├── widgets/          # 通用组件
├── controller/       # 状态管理控制器
├── router/           # 路由配置
├── utils/            # 工具类
├── theme/            # 主题配置
├── platform/         # 平台适配层
└── main.dart         # 应用入口
```

### 分层职责

#### 1. API 层（`lib/api/`）
- **职责**：封装所有网络请求，提供类型安全的接口
- **特点**：
  - 每个业务模块一个文件（`home.dart`、`house.dart`、`user.dart`...）
  - 使用 `typedef` 定义 Loader 类型，便于测试注入
  - 统一错误处理

**示例**：
```dart
// 房屋列表加载器类型定义
typedef HouseListLoader = Future<List<House>> Function();

// 获取房屋列表
Future<List<House>> getHouseListApi() async {
  final dynamic data = await requestDio.get(HttpPath.houseList);
  // 数据解析 + 类型校验
  return houses;
}
```

#### 2. Model 层（`lib/models/`）
- **职责**：定义数据结构，封装业务逻辑
- **特点**：
  - 不可变对象（`const` 构造函数）
  - `fromJson` / `toJson` 序列化
  - 便捷属性方法（`fullName`、`statusText`）

**示例**：[`House` 模型](lib/models/house.dart)
```dart
class House {
  const House({...});
  
  // 容错解析：字段可能是数字也可能是字符串
  factory House.fromJson(Map<String, dynamic> json) => House(...);
  
  // 便捷属性
  String get fullName => <String>[point, building, room]
      .where((s) => s.isNotEmpty).join(' ');
  
  bool get isApproved => status == 2;
  
  // 提交时省略空值字段
  Map<String, dynamic> toJson() => {...};
}
```

#### 3. Pages 层（`lib/pages/`）
- **职责**：页面 UI 构建与交互逻辑
- **特点**：
  - 使用 `LoadingStateMixin` 统一异步状态管理
  - 依赖注入：通过构造函数注入 Loader，便于测试

#### 4. Utils 层（`lib/utils/`）
- **核心工具**：
  - `RequestDio`：网络请求封装
  - `TokenManager`：Token 生命周期管理
  - `Validators`：表单校验
  - `Toast`：用户提示
  - `EventBus`：全局事件通信

---

## 业务模块详解

### 模块 1：用户认证

#### 登录流程
1. 用户输入手机号 + 验证码
2. 调用 `/user/login` 接口
3. 存储 Token 和 RefreshToken
4. 获取用户信息并更新全局状态
5. 跳转到目标页面

**关键代码**：[`LoginPage`](lib/pages/login/index.dart)

#### Token 管理机制
```dart
class TokenManager {
  int _sessionVersion = 0;  // 凭证代次
  int _sessionId = 0;        // 会话身份
  
  // 登录/手动设置 Token
  Future<bool> setToken(String token, {String refreshToken});
  
  // 刷新 Token（推进 version，不推进 sessionId）
  Future<bool> setRefreshedToken(String token, {required String refreshToken});
  
  // 登出
  Future<bool> deleteToken();
}
```

**设计亮点**：
- **会话版本号**：区分「刷新」和「换账号」
- **刷新标记**：防止跨账号重放
- **磁盘清理失败兜底**：`invalidateLocalSession()`

#### Token 自动刷新与安全读取恢复（2026-10-22 校正）

**流程**：
```
请求 → 401 → 检查 RefreshToken → 调用刷新接口 
    → 成功：存储新 Token，同会话白名单 GET 恢复一次；写操作不重放
    → 失败：仅清理仍属于本次刷新会话的凭证，不影响新账号
```

**关键代码**：[`RequestDio` 拦截器](lib/utils/request_dio.dart:76-162)

**会话隔离条件**（安全读取还须符合 GET 白名单和恢复次数预算，写操作不重放）：
1. **同一会话**：`sessionId` 相同
2. **凭证换代**：`sessionVersion` 不同
3. **来自刷新**：`refreshSessionVersion == sessionVersion`

**面试重点**：
- 为什么需要 `sessionId` 和 `sessionVersion` 两个字段？
  - `sessionId`：防止跨账号重放（A 的请求不能用 B 的 Token）
  - `sessionVersion`：判断凭证是否已更新

---

### 模块 2：房屋管理

#### 完整流程
```
登录 → 我的房屋 → 房屋列表
              ↓
        添加房屋 → 选择位置 → 选择楼栋 → 选择房间 → 填写表单 → 提交审核
              ↓
        房屋详情 → 编辑 / 删除
```

#### 选房流程状态管理

**BuildController**：保存用户在选房流程中的选择
```dart
class BuildController extends GetxController {
  BuildingInfo buildingInfo = const BuildingInfo();
  
  void updateLocation(String name) {...}
  void updateBuilding(String building) {...}
  void updateRoom(String room) {...}
  void reset() {...}
}
```

**数据模型**：
```dart
class BuildingInfo {
  final String name;      // 小区名称
  final String building;  // 楼栋
  final String room;      // 房间号
}
```

#### 房屋表单校验

**校验规则**：
- 小区、楼栋、房间：不能为空
- 业主姓名：2-15 位中文
- 手机号：1 开头的 11 位数字
- 身份证照片：正反面都必须上传

**关键代码**：[`validateHouseFormData`](lib/pages/house/house_form.dart:51-81)

#### 图片上传流程
1. 用户选择拍照或相册
2. 读取图片字节（最大 8MB）
3. 调用 `/upload` 接口上传
4. 服务端返回图片 URL
5. 保存 URL 到表单

**面试重点**：
- 为什么要限制图片大小？（防止内存溢出、提升上传速度）
- 如何处理上传失败？（显示错误提示，保留已选图片，允许重试）

---

### 模块 3：位置服务

#### 腾讯位置服务集成

**坐标系统**：
- **WGS84**：GPS 原始坐标（真机）
- **GCJ-02**：国测局加密坐标（腾讯地图、高德地图）

**坐标转换流程**：
```dart
Future<Position> getPosition() async {
  final position = await Geolocator.getCurrentPosition();
  
  if (position.isMocked) {
    // 模拟器坐标已经是 GCJ-02，直接用
    return position;
  } else {
    // 真机 GPS 坐标是 WGS84，需要转换
    return await translateCoordinates(position);
  }
}
```

**API 调用链**：
1. `Geolocator.getCurrentPosition()` → 获取 GPS 坐标
2. `translateCoordinates()` → 坐标转换（如需）
3. `reverseGeocode()` → 逆地址解析（坐标 → 地址）
4. `searchNearby()` → 周边搜索（找附近社区）

**面试重点**：
- 为什么需要坐标转换？（国家安全要求，民用地图必须加密）
- 如何判断是真机还是模拟器？（`position.isMocked`）

---

### 模块 4：报修服务

#### 数据模型
```dart
class RepairRecord {
  final String id;
  final String houseId;          // 关联房屋
  final String repairItemId;     // 报修项目 ID
  final String repairItemName;   // 报修项目名称
  final String mobile;           // 联系电话
  final String appointment;      // 预约时间
  final String description;      // 问题描述
  final int status;              // 1待处理 2处理中 3已完成 4已取消
  
  bool get canCancel => status == 1 || status == 0;
}
```

#### 可靠性改造

**问题 1**：连点取消导致多个确认框
- **根因**：锁只覆盖请求阶段，未覆盖确认阶段
- **修复**：增加确认阶段标记

**问题 2**：退出后出现迟到的错误提示
- **根因**：`catch` 中缺少 `mounted` 检查
- **修复**：所有异步回调前检查 `mounted`

**问题 3**：路由返回值类型不匹配
- **根因**：路由工厂声明 `MaterialPageRoute<void>`，实际 `pushNamed<bool>`
- **修复**：统一为 `MaterialPageRoute<bool>`

**面试重点**：
- 如何防止连续点击？（防抖标记 + UI 禁用）
- 为什么要检查 `mounted`？（Widget 可能已销毁，setState 会抛异常）

---

### 模块 5：访客管理与鸿蒙分享

#### 访客通行码
```dart
class VisitorRecord {
  final String id;
  final String houseId;
  final String name;
  final String mobile;
  final String visitDate;
  final int status;         // 0待访问 1待访问 2已访问 3已失效
  final String url;         // 通行码图片地址
  final int validTime;      // 有效时长（非时间戳）
  
  bool get canShare => (status == 0 || status == 1) && url.isNotEmpty;
}
```

#### 鸿蒙系统分享

**完整调用链**：
```
Flutter Widget
  ↓ (点击分享按钮)
MethodChannel.invokeMethod('shareImage', {bytes, anchor})
  ↓
鸿蒙 VisitorPassSharePlugin.onMethodCall
  ↓ (校验 + 写入缓存)
systemShare.ShareData
  ↓
ShareController.show()
  ↓ (用户选择分享目标)
面板关闭 → 回调 → MethodResult.success(null)
```

**关键设计**：
- 不传敏感信息（姓名、手机号、住址）
- 复用 `requestDio`，外部资源不触发登录逻辑
- 锚点坐标转换：`position * devicePixelRatio`
- 缓存清理：24 小时后自动删除旧文件

**面试重点**：
- MethodChannel 的作用？（Flutter 与原生平台通信桥梁）
- 为什么要检查 `mounted` 和路由栈？（下载期间可能切走/退出）

---

## 关键技术点

### 1. 异步状态管理

**LoadingStateMixin**：统一异步加载模式
```dart
mixin LoadingStateMixin<T extends StatefulWidget> on State<T> {
  bool _isLoading = false;
  String? _errorMessage;
  
  Future<bool> loadData(
    Future<void> Function() task, {
    String? Function(Object error)? onError,
    bool showErrorToast = true,
  }) async {
    setState(() { _isLoading = true; });
    
    try {
      await task();
      return true;
    } catch (error) {
      // 统一错误处理
      if (showErrorToast) await PromptAction.showError(message);
      return false;
    } finally {
      setState(() { _isLoading = false; });
    }
  }
}
```

**使用示例**：
```dart
class _MyPageState extends State<MyPage> with LoadingStateMixin {
  @override
  void initState() {
    super.initState();
    loadData(() async {
      final data = await fetchData();
      setState(() { _data = data; });
    });
  }
}
```

---

### 2. 错误处理体系

#### 异常分类
```dart
// 网络异常（连接失败、超时、HTTP 错误）
class NetworkException extends AppException {
  final int? statusCode;
}

// 业务异常（业务 code ≠ 10000）
class BusinessException extends AppException {
  final int? code;
}
```

#### 统一错误描述
```dart
String describeError(Object error, {String fallback}) {
  if (error is NetworkException) return error.message;
  if (error is BusinessException) return error.message;
  return fallback;
}
```

**面试重点**：
- 为什么要区分网络异常和业务异常？
  - 网络异常：用户应检查网络
  - 业务异常：用户应修改输入或联系客服

---

### 3. 依赖注入与测试

#### 为什么要依赖注入？
- **可测试性**：可以注入 Mock Loader，不依赖真实网络
- **灵活性**：可以切换不同实现（真实接口 / Mock 接口）

**示例**：
```dart
class HouseForm extends StatefulWidget {
  const HouseForm({
    this.photoPicker = pickHousePhoto,       // 默认实现
    this.uploadPhotoLoader = uploadPhotoAPI,
    this.submitHouseLoader = submitHouseAPI,
    super.key,
  });
  
  final HousePhotoPicker photoPicker;
  final UploadPhotoLoader uploadPhotoLoader;
  final SubmitHouseLoader submitHouseLoader;
}
```

**测试时注入 Mock**：
```dart
testWidgets('上传照片失败显示错误', (tester) async {
  await tester.pumpWidget(
    HouseForm(
      uploadPhotoLoader: (_) async => throw NetworkException('网络错误'),
    ),
  );
  
  // 触发上传 → 验证错误提示
});
```

---

### 4. 日志脱敏

**敏感字段**：
- `authorization`、`token`、`password`、`mobile`、`secret`
- URL 查询参数中的 `key`、`appKey`、`apiKey`
- 请求/响应体中的 `code`（验证码）

**脱敏策略**：
```dart
static bool _isSensitiveLogKey(String key, {required bool requestSide, int depth = 0}) {
  final normalized = key.toLowerCase().replaceAll(RegExp(r'[-_]'), '');
  
  // 固定黑名单
  if (_sensitiveLogKeys.contains(normalized)) return true;
  
  // 子串匹配
  for (final fragment in _sensitiveLogKeyFragments) {
    if (normalized.contains(fragment)) return true;
  }
  
  // 验证码特殊处理：请求侧全脱敏，响应侧只脱敏嵌套的
  if (normalized == 'code' && (requestSide || depth > 1)) return true;
  
  return false;
}
```

**面试重点**：
- 为什么响应顶层的 `code` 不脱敏？（那是业务状态码 10000/10001，不是验证码）
- 为什么要递归处理？（敏感字段可能嵌套在对象或数组中）

---

## 面试高频问题

### 技术类

#### 1. Flutter 基础
**Q：Flutter 的渲染原理？**
- Widget → Element → RenderObject
- Widget 是配置，Element 是实例，RenderObject 负责布局和绘制

**Q：StatefulWidget 和 StatelessWidget 的区别？**
- StatelessWidget：不可变，rebuild 时重新创建
- StatefulWidget：持有 State，State 可变

**Q：`setState` 做了什么？**
- 标记 Element 为 dirty
- 在下一帧重建 Widget 树

#### 2. 状态管理
**Q：为什么用 GetX 而不是 Provider？**
- GetX 更轻量，不需要 Context
- 简单场景下更直观（`.obs` + `Obx`）

**Q：全局状态如何管理？**
- `UserInfoController`：用户信息
- `BuildController`：选房流程临时状态

#### 3. 网络请求
**Q：Dio 拦截器的执行顺序？**
- 请求：按添加顺序执行
- 响应：按添加顺序逆序执行
- 错误：按添加顺序执行

**Q：Token 刷新机制如何避免并发刷新？**
```dart
Future<bool>? _refreshTokenFuture;

Future<bool> _tryRefreshToken() {
  if (_refreshTokenFuture != null) {
    return _refreshTokenFuture!;  // 复用进行中的刷新
  }
  
  _refreshTokenFuture = _doRefresh();
  return _refreshTokenFuture!;
}
```

#### 4. 异步编程
**Q：`async/await` 的原理？**
- 编译器将异步函数转换为状态机
- `await` 暂停当前函数，返回 Future
- 等待完成后恢复执行

**Q：如何处理并发请求？**
```dart
final results = await Future.wait([
  fetchHouses(),
  fetchRepairs(),
  fetchVisitors(),
]);
```

#### 5. 测试
**Q：如何测试异步逻辑？**
- `await tester.pumpAndSettle()`：等待所有动画和异步完成
- `await tester.pump(Duration(...))`：手动推进指定时间

**Q：如何 Mock 网络请求？**
- 依赖注入：传入 Mock Loader
- 不依赖全局单例

---

### 业务类

#### 1. 房屋管理
**Q：为什么要分成"选位置 → 选楼栋 → 选房间"三步？**
- 数据量大：一次加载所有数据会很慢
- 用户体验：逐步缩小范围更清晰

**Q：房屋审核状态有哪些？**
- 1 审核中、2 审核成功、3 审核失败

#### 2. 位置服务
**Q：为什么要坐标转换？**
- GPS 原始坐标（WGS84）不能直接用于民用地图
- 需要转换为 GCJ-02（国测局加密坐标）

**Q：如何判断是真机还是模拟器？**
- `position.isMocked` 字段
- 模拟器坐标已经是 GCJ-02，不需转换

#### 3. 报修服务
**Q：报修可以取消吗？**
- 只有"待处理"（status=1）和初始状态（status=0）可以取消
- 处理中/已完成不能取消

**Q：如何防止重复提交？**
- UI 防抖：`_isSubmitting` 标记
- 服务端幂等：（通常由后端保证）

#### 4. 访客管理
**Q：通行码如何分享？**
- 鸿蒙：MethodChannel → 原生 ShareController
- 其他平台：显示"仅支持鸿蒙"提示

**Q：为什么不直接传图片 URL？**
- 安全性：防止跨域访问
- 控制权：确保分享前图片已下载

---

### 设计类

#### 1. 架构设计
**Q：为什么要分层？**
- 职责分离：API 层、Model 层、View 层各司其职
- 可测试性：每层可以独立测试
- 可维护性：修改某层不影响其他层

**Q：如何处理跨平台差异？**
- 条件导入：`import '...' if (dart.library.io) '...';`
- 平台适配层：`platform/` 目录统一处理

#### 2. 性能优化
**Q：如何优化列表性能？**
- 使用 `ListView.builder`（懒加载）
- 图片缓存：`CachedNetworkImage`
- `const` 构造函数：减少重建

**Q：如何减少不必要的重建？**
- 提取子组件为独立 Widget
- 使用 `const` 构造函数
- 缩小 `setState` 影响范围

#### 3. 安全性
**Q：如何保护敏感信息？**
- Token 存储：SharedPreferences（设备本地）
- 日志脱敏：敏感字段替换为 `***`
- HTTPS：所有接口使用加密传输

**Q：如何防止 Token 泄露？**
- 不在日志中打印 Token
- 不在 URL 查询参数中传递 Token
- 使用 Authorization Header

---

## 实战演练

### 练习 1：实现一个新功能

**需求**：增加"意见反馈"功能
- 用户可以提交反馈内容
- 可以选择反馈类型（功能建议、Bug 反馈、其他）
- 可以上传截图（可选）

**步骤**：
1. 创建数据模型 `Feedback`
2. 在 `api/` 创建 `feedback.dart`
3. 创建页面 `pages/feedback/feedback_form.dart`
4. 添加路由配置
5. 在"我的"页面添加入口
6. 编写测试用例

---

### 练习 2：排查 Bug

**场景**：用户反馈"有时候退出登录后，再次进入还是登录状态"

**排查思路**：
1. 检查 `TokenManager.deleteToken()` 是否正确清除
2. 检查 `SharedPreferences.clear()` 是否失败
3. 验证 `LogoutEvent` 是否正确触发
4. 检查页面是否监听登出事件

**可能原因**：
- 磁盘清理失败但未处理
- 事件监听器未正确移除
- 页面缓存导致状态未更新

---

### 练习 3：代码审查

**任务**：审查以下代码，找出问题并优化

```dart
class MyPage extends StatefulWidget {
  @override
  _MyPageState createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  List<House> houses = [];
  
  @override
  void initState() {
    super.initState();
    loadHouses();
  }
  
  void loadHouses() async {
    final data = await getHouseListApi();
    setState(() {
      houses = data;
    });
  }
  
  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: houses.length,
      itemBuilder: (context, index) {
        return Text(houses[index].fullName);
      },
    );
  }
}
```

**问题**：
1. ❌ 没有加载状态，用户看不到 loading
2. ❌ 没有错误处理，失败后列表一直为空
3. ❌ 没有检查 `mounted`，异步回调可能在 Widget 销毁后执行
4. ❌ `loadHouses` 方法没有标记为 `async`

**优化后**：
```dart
class _MyPageState extends State<MyPage> with LoadingStateMixin {
  List<House> houses = [];
  
  @override
  void initState() {
    super.initState();
    loadData(_loadHouses);
  }
  
  Future<void> _loadHouses() async {
    final data = await getHouseListApi();
    if (mounted) {
      setState(() {
        houses = data;
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Center(child: CircularProgressIndicator());
    }
    
    if (errorMessage != null) {
      return Center(child: Text(errorMessage!));
    }
    
    return ListView.builder(
      itemCount: houses.length,
      itemBuilder: (context, index) {
        return Text(houses[index].fullName);
      },
    );
  }
}
```

---

## 学习路线图

### 第 1 天：项目概览与环境搭建
- ✅ 阅读 [README.md](../README.md)
- ✅ 理解分支结构和功能演进
- ✅ 搭建开发环境
- ✅ 运行 Web 版本，体验完整功能

### 第 2 天：核心技术栈
- ✅ 学习 Flutter 基础（如果不熟悉）
- ✅ 理解 GetX 状态管理
- ✅ 学习 Dio 网络请求

### 第 3 天：架构设计
- ✅ 理解分层架构
- ✅ 阅读 [`main.dart`](../lib/main.dart)，理解应用启动流程
- ✅ 阅读 [`router/index.dart`](../lib/router/index.dart)，理解路由机制

### 第 4 天：用户认证模块
- ✅ 阅读 [`TokenManager`](../lib/utils/token_manager.dart)
- ✅ 阅读 [`RequestDio`](../lib/utils/request_dio.dart)
- ✅ 理解 Token 刷新与重放机制
- ✅ 阅读测试用例 [`session_lifecycle_test.dart`](../test/session_lifecycle_test.dart)

### 第 5 天：房屋管理模块
- ✅ 阅读 [`House` 模型](../lib/models/house.dart)
- ✅ 阅读 [`BuildController`](../lib/controller/build_controller.dart)
- ✅ 理解选房流程：位置 → 楼栋 → 房间 → 表单
- ✅ 阅读 [`HouseForm`](../lib/pages/house/house_form.dart)

### 第 6 天：位置服务模块
- ✅ 学习腾讯位置服务 API
- ✅ 理解坐标系统（WGS84 vs GCJ-02）
- ✅ 阅读 [`location.dart`](../lib/utils/location.dart)
- ✅ 阅读 [`LocationList`](../lib/pages/location/location_list.dart)

### 第 7 天：报修与访客模块
- ✅ 阅读 [`RepairRecord` 模型](../lib/models/repair.dart)
- ✅ 阅读 [`VisitorRecord` 模型](../lib/models/visitor.dart)
- ✅ 理解报修流程可靠性改造
- ✅ 阅读 [鸿蒙分享文档](harmony_share_and_reliability.md)

### 第 8 天：鸿蒙平台适配
- ✅ 学习 MethodChannel 原理
- ✅ 阅读 [`visitor_pass_share.dart`](../lib/platform/visitor_pass_share.dart)
- ✅ 阅读鸿蒙原生代码 `ohos/entry/src/main/ets/VisitorPassSharePlugin.ets`
- ✅ 理解 Flutter 与鸿蒙通信机制

### 第 9 天：测试与质量保证
- ✅ 阅读所有测试用例（`test/` 目录）
- ✅ 理解 Widget 测试写法
- ✅ 学习如何 Mock 异步请求
- ✅ 运行测试：`./tool/flutter_ohos.ps1 test --no-pub`

### 第 10 天：模拟面试准备
- ✅ 复习面试高频问题
- ✅ 准备项目介绍（1 分钟版本 + 3 分钟版本）
- ✅ 准备技术难点讲解（选 2-3 个）
- ✅ 准备代码演示（现场写一个小功能）

---

## 面试话术模板

### 1. 项目介绍（1 分钟版本）

> 我参与开发了 Haven Hub 享家社区项目，这是一个基于 Flutter 的社区物业管理应用，支持 Android、iOS、HarmonyOS 和 Web 多平台。
>
> 项目包含**用户认证、房屋管理、报修服务、访客管理**等核心功能。我主要负责**房屋管理模块**和**鸿蒙平台适配**。
>
> 技术栈方面，使用 **Flutter + GetX + Dio**，实现了**Token 自动刷新**、**日志脱敏**、**异步状态管理**等功能。2026-10-20 实际测试为服务端 253 通过、Flutter 402 通过和 1 跳过；本轮未重新运行 Flutter Analyze。个人负责范围应按能够讲清的实际工作陈述，现行口述稿见文末。

### 2. 技术难点讲解

#### 示例 1：Token 自动刷新与重放

> **背景**：用户长时间使用应用，Token 可能过期，如果每次都让用户重新登录，体验很差。
>
> **现行方案**：实现 Token 自动刷新机制。当接口返回 401 时尝试刷新；成功后保留登录，同会话白名单 GET 安全读取恢复一次；超时及 502/503/504 在请求层内按预算重试，写操作不重放。
>
> **难点**：如何避免跨账号重放？比如用户 A 的请求在飞行途中，用户 B 登录并刷新了 Token，这时不能用 B 的 Token 去重放 A 的请求。
>
> **历史演进**：引入**会话 ID** 和**会话版本号**。会话 ID 在登录/登出/失效时变化，成功更新凭证会推进版本；下面三个条件保护会话归属；当前仅允许白名单 GET 在同会话内恢复一次，写操作不重放：
> 1. 同一会话（sessionId 相同）
> 2. 凭证确实换代（sessionVersion 不同）
> 3. 这次推进来自刷新（refreshSessionVersion == sessionVersion）
>
> 当前不会因旧请求失效而清理新账号；刷新失败也必须检查原会话归属。

#### 示例 2：鸿蒙系统分享

> **背景**：访客管理模块需要分享通行码图片，鸿蒙平台有专门的系统分享 API。
>
> **方案**：通过 MethodChannel 实现 Flutter 与鸿蒙原生通信。Flutter 侧下载图片字节，通过通道传给鸿蒙原生，原生写入缓存并调用 ShareController。
>
> **难点**：
> 1. 如何传递锚点坐标？分享按钮在 Flutter 中的坐标是逻辑像素，需要乘以 devicePixelRatio 转换为物理像素。
> 2. 如何处理页面切走？下载期间用户可能切到后台或退出页面，需要检查 mounted 和路由栈。
> 3. 如何保证安全？不传姓名、手机号等敏感信息，只传图片字节；缓存文件 24 小时后自动清理。
>
> **结果**：实现了完整的分享流程，通过了 32 个测试用例，包括前后台切换、路由覆盖、坐标转换等场景。

---

## 快速检索

### 核心文件清单

| 文件 | 功能 | 重要度 |
|------|------|--------|
| [`main.dart`](../lib/main.dart) | 应用入口 | ⭐⭐⭐⭐⭐ |
| [`router/index.dart`](../lib/router/index.dart) | 路由配置 | ⭐⭐⭐⭐⭐ |
| [`utils/request_dio.dart`](../lib/utils/request_dio.dart) | 网络请求封装 | ⭐⭐⭐⭐⭐ |
| [`utils/token_manager.dart`](../lib/utils/token_manager.dart) | Token 管理 | ⭐⭐⭐⭐⭐ |
| [`models/house.dart`](../lib/models/house.dart) | 房屋数据模型 | ⭐⭐⭐⭐ |
| [`controller/build_controller.dart`](../lib/controller/build_controller.dart) | 选房状态管理 | ⭐⭐⭐⭐ |
| [`pages/house/house_form.dart`](../lib/pages/house/house_form.dart) | 房屋表单 | ⭐⭐⭐⭐ |
| [`widgets/loading_state_mixin.dart`](../lib/widgets/loading_state_mixin.dart) | 异步状态管理 | ⭐⭐⭐⭐ |
| [`platform/visitor_pass_share.dart`](../lib/platform/visitor_pass_share.dart) | 鸿蒙分享 | ⭐⭐⭐ |

### 关键概念速查

- **Token 自动刷新**：[`request_dio.dart:76-162`](../lib/utils/request_dio.dart:76-162)
- **日志脱敏**：[`request_dio.dart:356-379`](../lib/utils/request_dio.dart:356-379)
- **异步状态管理**：[`loading_state_mixin.dart`](../lib/widgets/loading_state_mixin.dart)
- **坐标转换**：[`location.dart`](../lib/utils/location.dart)
- **表单校验**：[`house_form.dart:51-81`](../lib/pages/house/house_form.dart:51-81)

---

## 总结

这个项目虽然不大（~6000 行代码），但**五脏俱全**：

1. **完整的业务闭环**：从登录到房屋管理，从报修到访客，覆盖物业管理核心场景
2. **扎实的工程实践**：分层架构、依赖注入、单元测试、错误处理
3. **深入的技术细节**：Token 刷新、日志脱敏、坐标转换、平台适配
4. **可核对的学习项目代码**：有自动化测试、文档和可靠性改造；尚无生产部署验收

面试时，你可以从**业务理解**、**技术实现**、**工程质量**三个维度展开，展示你的全面能力。

**祝你面试顺利！** 🎉


---

## 2026-10-20 求职补充：以当前代码为准

本节对应业务提交 `01bd335`、`998074e`、`bea02bb`。此前章节保留作学习笔记；其中旧测试数、旧重放策略、旧平台和个人负责范围不能直接用于面试。以下事实在本轮重新读取源码、Git 提交或实际运行核对。路径行号按当前源码；文档历史排查记录只用于说明当时的问题，不能替代今天的验收。

本轮 `server/ npm test`：253 通过、0 失败、0 跳过；根目录 `.\tool\flutter_ohos.ps1 test --no-pub`：402 通过、0 失败、1 跳过。跳过项是 `test/local_backend_integration_test.dart:21` 的 `RUN_LOCAL_BACKEND_TEST` 开关控制的集成测试，不应宣称 403 全通过。服务端编译、Web 构建和 x64 Debug HAP 构建通过；没有连接设备，因此本轮未复测 API 24 模拟器。临时数据库的急单到确认、星期模板变更已走通。

### 1. 项目介绍：1 分钟口头版

我做的是享家社区，一个社区物业应用，主要有住户、维修师傅、物业三种角色。住户能录入房屋、看公告、登记访客和报修；师傅处理工单；物业通过网页审核和排单。

客户端用 Flutter，当前仓库主要跑鸿蒙和 Web，服务端是自己维护的 Node.js 和 SQLite。报修是我现在最适合展开讲的部分：从提交、定级、派单、维修，到住户确认和售后，都有对应规则。

排单不是简单改一个状态。我把名额、师傅时间冲突和版本检查放到写事务里，避免同一名额被重复占用，也避免旧页面覆盖新操作。现在服务端 253 项测试通过，Flutter 402 项通过，另有一项条件集成测试跳过。做过 HAP 构建和模拟器验证，但没有物理真机验收、推送送达和生产部署结果。代码是在 AI 辅助下完成的，规则取舍和审核过程我会结合具体例子说明。

### 2. 项目介绍：3 分钟口头版

享家社区是一个社区物业应用。它不是只有住户填表这一端：住户要知道什么时候上门，师傅要知道处理哪张工单，物业要处理派单、时间冲突和异常反馈。所以我把它分成住户、师傅和物业三个角色，前两个共用 Flutter 客户端，物业用网页后台，后端是 Node.js、Express 和 SQLite。

基本功能包括登录、房屋录入审核、腾讯定位选房、公告、访客通行码。我会重点介绍报修，因为它把跨角色协作、异步状态和数据一致性放在了一起。住户提交后，物业定级和安排；普通工单先派单，再由师傅接单；急单由物业从空闲师傅里人工调度，直接形成安排。师傅提交完工后先进入待确认，住户确认后才完成；没有修好或在售后期内有问题，可以继续返修，次数不设上限，每轮最终确认后均有 720 小时售后期。

排单每天有 11 个一小时时段。容量按默认、星期模板、单日覆盖逐层计算，订单自己的 slot 是占用事实，不另外维护一张占用表。这样取消、改约和返修都围绕同一份数据，但查询要读取对应时段的订单，而且必须集中维护占用规则，规模扩大以后需要重新评估。

为了防止两个页面覆盖同一工单，请求会带 revision。服务端在事务内读取最新版本，旧版本返回 409，客户端刷新并保留用户输入，不自动重放写操作。最后一个名额也在同一写事务内检查和保存。这里的证据是 SQLite 的事务实现和并发请求测试，我不会把它说成验证过大规模高并发。

时间处理也有两个区别。日期和星期统一按北京时间；72 小时确认、2 小时回应这些期限按连续时长计算。首次定时在提议时已经占住名额，到期可以按规则生效；普通改约保留旧安排，只有同意时才竞争新名额，不能因为无人回应就自动移动。当前代码还没有住户、师傅各确认一次的独立审批状态，这一点我会照实说明。

客户端我处理过 Token 刷新竞态、草稿身份晚到，以及鸿蒙图片选择插件留下旧回调的问题。AI 帮我生成代码，但不能替代审核：例如首次时间未确认就能顺延、409 原因被固定文案盖掉，都曾在审核时退回。当前有 253 个服务端测试通过、402 个 Flutter 测试通过及 1 个跳过项；HAP 构建通过，物理真机、系统推送实际送达和生产部署仍没有完成。

### 3. 报修排单：背景、取舍与实现

- **背景**：住户的“紧急诉求”是用户表达，不等于有权自己把工单定为急单；物业需要核实等级并决定人选。满额也不意味着所有师傅都忙，因此公开容量和单个师傅冲突是两种约束。
- **普通路径**：创建可选择 slot，也可等待安排。普通预约至少提前 2 小时，范围含今天 7 天，客户端只消费服务端 selectable。查不到可选项与网络失败分开展示。
- **容量**：`schedule.ts:10` 的规则常量；`repository.ts:153` 合成默认、星期、单日数据；`schedule.ts:73` 唯一占用筛选；`repository.ts:141` 用 JSON slot 表达式查询。取消状态 0 和历史状态 4 不计占用；提前完工清理未来 slot，已开始的 slot 可能保留占用。
- **急单**：`service.ts:141` 只检查目标时段有效、师傅存在且空闲；`actions.ts:306` 写入安排并进入处理中。它不抢占其他订单，但自身仍写 slot，后续公开余量会反映它，最低为 0。
- **顺延**：`policy.ts:28` 集中检查首次已确认、原时段未开始等条件；`service.ts:111` 在事务中检查新名额和师傅冲突；不是定时自动搬单。
- **职责**：`routes.ts` 接 HTTP；`service.ts` 校验/权限/编排；`repository.ts` 管事务和数据；`actions.ts`、`policy.ts`、`schedule.ts` 管规则；`views.ts` 过滤角色数据；`notification-tasks.ts` 生成待办。以上文件均位于 `server/src/repair/`。
- **边界**：本地单服务的 SQLite 写事务并非分布式锁；无创建幂等键；技能匹配、长工时、多级审批都没有对应模型。

### 4. 六道必考题

#### 4.1 工单有哪些状态，为什么新状态避开 0 和 4？

**口头要点（2 分钟内）**：主状态是 0 已取消、1 待派单、5 待接单、2 处理中、6 待住户确认、3 已完成。普通路径是 1→5→2→6→3；急单人工调度可以进入 2。未修好或售后通过会开启下一轮维修，次数不设上限；从未登记技能的原师傅可继续持有旧单，已明确清空技能、不匹配或不存在则回到 1 并交物业协调。每轮售后期均从最终确认完成起算 720 小时。取消和重新约时间还受当前阶段限制。0 已有取消语义，4 是历史 App 的取消值，不能重用成新业务状态，否则旧客户端会把新工单显示成已取消。

**代码**：`server/src/repair/model.ts:3`；`actions.ts:17` 确认，`actions.ts:127` 接单，`actions.ts:147` 完工，`actions.ts:211` 派单，`actions.ts:264` 返修；`schedule.ts:73` 排除 0/4。

**未采用的方案与原因**：没有把新增状态顺着 3 直接编成 4，也没有重编号旧状态；当前兼容代码可以证明这项选择，仓库没有独立记录一场“状态编号方案评审”。

**追问**：售后是不是新的主状态？——不是，申请和回应放在 pendings，rounds 在返修开始时只保留当前轮内容，历史已完工费用另存在 fees，时间线保留操作记录，主状态只表达当前大阶段，避免把所有组合塞进一个枚举。

#### 4.2 两个人同时修改同一工单会怎样？

**口头要点**：页面读取版本 5，提交也带 5。第一个请求在事务中确认版本一致，执行动作、保存为 6。第二个再读取时发现已经是 6，返回 409；不会覆盖前一次。授权在版本比较之前，防止用冲突信息泄露他人记录。到期结算可能先推进 revision，因此页面放置一段时间后也可能冲突。

**代码**：`server/src/repair/repository.ts:79`；`server/src/database.ts:83`；Flutter `lib/pages/repair/repair_pages.dart:334`；HTTP 409 原因映射 `lib/utils/request_dio.dart:516`。

**未采用的方案与原因**：单靠按钮禁用挡不住另一浏览器；最后一次保存覆盖会丢数据。当前实现没有自动重放旧操作，因为刷新后的状态可能使原意失效。此为实现取舍总结，不伪称存在逐字历史讨论。

**追问**：版本锁能防所有重复创建吗？——不能。新建没有同一工单 revision 可比，结果未知后的重发需要幂等键；当前没有实现。容量修改也没有 revision。

#### 4.3 最后一个名额两个人抢，为什么只成功一个？

**口头要点**：不能先查余量再在另一个请求中保存。创建调用 repository.create，再进入 withList 的事务；build 回调执行 checkSlot，检查通过才保存订单。SQLite 使用 BEGIN IMMEDIATE，同一数据库的写事务串行取得写权，后来的写请求会看到前一张订单。达到容量时 requireAvailable 抛 409。revision 解决同一单覆盖，事务内名额检查解决不同订单争同一 slot，二者用途不同。

**代码**：`server/src/repair/service.ts:163`、`repository.ts:121`、`repository.ts:132`、`repository.ts:212`、`schedule.ts:107`、`server/src/database.ts:88`。

**未采用的方案与原因**：没有依赖客户端显示的剩余量，也没有把“查余量”和“插入”拆成事务外两步；两人都读到 1 后会超卖。无需声称当时评估过 Redis 分布式锁。

**追问**：证据是什么？——`server/test/repair-schedule.test.ts:76` 的 “last capacity under simultaneous requests succeeds exactly once”，本轮包含在 253 项通过中。它证明当前服务测试场景，不证明跨多实例吞吐能力。

#### 4.4 为什么只用 slot，不另建占用表？代价是什么？

**口头要点**：订单已经有当前 slot，再维护一个占用表就有两份事实。取消、返修、顺延、首次提议拒绝都要同步，漏一次会出现幽灵名额。现在统一读取对应 slot 的订单，所有容量和师傅冲突共用 slotOrders。代价是需要解析对应订单 JSON，规则和索引必须准确；未来长维修横跨多个小时也不适合单一 slot。

**代码**：`server/src/repair/schedule.ts:73`、`schedule.ts:133`、`repository.ts:141`、`repository.ts:147`；`server/src/database.ts` 的 repairs_slot 索引。

**未采用的方案与原因**：独立占用表、缓存计数都增加双写一致性成本。仓库能证明没有采用这些实现，但没有保存独立占用表的历史评审全文，解释应表述为当前取舍。

**追问**：首次提议为什么也占名额？——首次提议直接暂存为订单 slot，agreedTime 还没生效；拒绝释放。普通改约只在 pending 里放目标，原 slot 保留，接受时再检查目标。

#### 4.5 首次定时可超时生效，普通改约为什么永不自动通过？

**口头要点**：首次定时解决没有安排的单，提议时已保留名额；给住户一个明确回应窗口，到期按规则落定。截止时间是“现在加 2 小时”和“上门前 2 小时”取更早，至少留 30 分钟。普通改约已有原安排，沉默不能说明接受新时间，而且目标名额也没预占，所以不自动通过。首次超时会写明住户未主动确认，提醒先电话确认。

**代码**：`server/src/repair/actions.ts:79`；`schedule.ts:118`；`policy.ts:121`；`service.ts:241`；`notification-tasks.ts:37`。

**未采用的方案与原因**：没有把所有 reschedule 都套一个超时自动同意规则；这会改变原有约定，且绕过确认时的容量竞争。旧 agreedTime 不为空但 slot 为空的记录也不能当成首次。

**追问**：那是不是双方都要各按一次同意？——当前不是。`actions.ts:101` 至 `123` 允许一次合法回应落定普通改约；物业有代为确认入口。首次只允许住户回应。不能把“普通改约不自动同意”夸成“已实现双方独立审批”。

#### 4.6 星期几为什么必须按北京时间算？

**口头要点**：物业按中国本地日期配置星期模板，服务器可能运行在 UTC 或其他时区。例如 UTC 周六 17 点已是北京周日凌晨 1 点，如果直接用宿主机 getDay，就可能取错周六容量。先由 UTC+8 生成业务日期，再把这个纯日期用 UTC 解析、getUTCDay 读星期，避免二次受宿主时区影响。日期口径和“连续 72 小时”的时长口径要分开。

**代码**：`server/src/repair/schedule.ts:26`、`repository.ts:159`、`policy.ts:50`；测试 `server/test/repair-weekdays.test.ts` 中 “public today uses Beijing Sunday while UTC remains Saturday”。

**未采用的方案与原因**：不直接取宿主机 getDay，不按设备本地日期决定服务端容量。代码与测试证明采用了固定业务时区，不能据此说测过所有国际时区。

**追问**：跨午夜预约范围会自动变化吗？——会，查询根据当前服务端时钟重算含今天的 7 天，不依赖午夜定时任务。`server/test/repair-schedule.test.ts:157` 有查询推进日期测试。

### 5. 未采用或仍有差距的方案

下面区分“代码证实未采用”与“历史否决理由”。没有原始讨论证据时，原因是对当前实现的解释，不虚构当时发言。

| 方案 | 当前情况与原因 | 依据 |
| --- | --- | --- |
| 急单自动挤占低等级单 | 未实现；避免悄悄破坏他人已约定时间，物业从空闲师傅人工选择，必要时另行手动顺延 | `service.ts:141`、`policy.ts:40`；本地 `repair_schedule_phase2_api.md:60` |
| 为急单固定预留名额 | 没有急单专用容量字段；当前急单可超公开容量但不能占用忙碌师傅，避免先分配一块可能闲置的公开容量。未找到“当时否决”的独立记录 | `schedule.ts:15`、`repository.ts:153`、`service.ts:150` |
| 候补 | 没有候补队列、晋升和超时确认模型，当前通过待安排队列和物业处理；不承诺自动补位 | `repair_schedule_phase2_api.md:60`、`service.ts:92` |
| 按自然日计算期限 | 当前自动确认采用连续 72 小时，每轮售后期统一为最终确认后 720 小时，避免同样“3 天”因提交时间不同而长短不一。早期交接文档只记录自然日口径待确认，不能伪称有完整否决过程 | `policy.ts:50`；`repair_phase_one_claude_handoff.md:107` |
| 只要一方同意就能改约 | **未能证实已经否决。当前普通改约确实是一次合法回应即可落定。** 若需求是住户、师傅分别确认，需新增独立回应状态、失败/撤回规则与测试，当前材料必须承认差距 | `actions.ts:101`、`server/public/admin/app.js:709` |

### 6. 已知不足及改进思路

1. **专业技能和长维修**：维修人员数据没有用于派单的专业技能模型，单 slot 不覆盖跨小时占用。先定义技能、工时区间和重叠判定，再修改调度规则与测试。
2. **容量编辑会覆盖**：`repository.ts:176`、`service.ts:410` 没有 revision；两个物业改同一格，后写覆盖前写。可增加模板版本和日期覆盖版本，冲突时刷新提示。
3. **页面文件过大**：本轮读取 `repair_pages.dart` 为 1543 行（含末尾空行），`server/public/admin/app.js` 为 868 行。按表单、详情、容量编辑拆分，并以现有行为测试约束，避免为了拆分再造通用框架。
4. **设备与送达缺口**：历史验证有 API 24 模拟器，本轮 HAP 构建通过，但无物理真机验收、Push Kit / Web Push 端到端送达结果。应分别记录安装、启动、业务和送达证据。
5. **普通改约审批**：没有双方分别确认的数据模型，不能用界面文字代替协议。
6. **创建幂等**：草稿和“结果未确认”只降低误操作，不保证服务端只创建一次。改进应使用客户端提交标识、服务端唯一约束和结果查询。
7. **平台范围**：当前 Git 中没有 android/ 或 ios/ 工程；不能将 Flutter 可跨平台说成这些平台均已构建验收。

### 7. 遇到的问题：10 个可追溯案例

#### 7.1 首选：Token 刷新与换账号竞态

- **现象**：A 的请求迟到，B 登录后又刷新，旧请求可能拿 B 的凭证重放；旧刷新失败还可能清理 B 的登录。
- **排查**：查看请求拦截器和凭证写入顺序，用可控 Future 和假 adapter 复现。提交演进包含只比版本、要求版本恰好加一、拆分身份与版本，再到完全停止旧请求重放；这些历史策略不能混写成当前策略。
- **根因**：一个递增版本既表达“换账号”又表达“刷新”，无法区分身份；持久化异步写入也存在交错窗口。
- **修复**：`e88ac5e` 处理退出与刷新竞态；`079ddd5` 加强旧请求隔离；`c8d4def` 拆分 sessionId 与凭证代次；`68de27e` 当时串行凭证修改并停止原请求及外层重试；当前版本保持会话隔离，同会话白名单 GET 安全读取恢复一次，超时及 502/503/504 在请求层内按预算重试，写操作不重放。当前位置 `lib/utils/token_manager.dart:23`、`:92`、`:108`，`lib/utils/request_dio.dart:75`、`:103`、`:423`。
- **验证入口**：`test/token_refresh_retry_test.dart:108`（`refresh keeps login and automatically restores the safe read once`）、`:311`（`does not replay a stale request when the new account then refreshes`）、`:437`（`concurrent 401 shares one refresh, only GET recovers and a second 401 stops`）、`:480`（`a late failed refresh cannot log out the new account`）；`test/request_recovery_test.dart:33` 检查超时预算，`:85` 检查短信 GET 和写操作不重试。
- **收获**：异步结果先验证归属，再讨论是否重试；身份与数据版本要分开。

**2 分钟口头版**：我遇到过一个不是单次请求能暴露的登录问题。用户 A 发请求后切到 B，如果只看 Token 有没有变，A 的迟到请求可能被当作正常刷新重试，用上 B 的凭证。最开始版本判断越来越复杂，后来我把“是谁的会话”和“凭证换到第几代”分开，并对落盘操作排队。当前策略是刷新成功保留登录，同会话白名单 GET 安全读取恢复一次，超时及 502/503/504 在请求层内按预算重试；写操作不重放，跨账号旧请求停止。测试用可控的返回顺序覆盖换号、B 再刷新、旧刷新迟到失败这些情况。我能证明这些竞态用例通过，但不会说它等于服务端的幂等保证。

#### 7.2 首选：image_picker 相机失败后相册 Future 不返回

- **现象**：API 24 模拟器相机失败后，再打开相册，Dart 的选择 Future 长时间不结束，界面像一直在等待。
- **排查**：不仅检查页面 loading，还沿 MethodChannel 读取插件原生 delegate，查看 camera_permission_error 和回调持有状态；用 `tool/platform_smoke.dart` 复现“相机失败→相册取消→再次相册取消”。未保留每一步排查耗时，不能编造。
- **根因**：相机错误路径没有清理已经完成的 pendingCallState，下一次相册结果回到旧回调，新 Future 没有完成；还存在对缺失 Promise 调用 then 的路径。
- **修复**：`2ca7cd5` 将修补版放在 third_party 并使用 path override。错误回调前清空 pending 状态，真正并发请求返回 already_active，处理不可用相机和文件描述符。位置 `third_party/image_picker_ohos/ohos/src/main/ets/image_picker/ImagePickerDelegate.ets:390`、`:400`、`:404`；来源及许可见 `third_party/image_picker_ohos/UPSTREAM.md:3`。
- **验证**：提交说明与 `UPSTREAM.md:27` 保留上述设备回归入口；本轮 HAP 编译覆盖插件，但未连接模拟器重跑原生选择，不能把 Flutter 单测当成这项原生回归。
- **收获**：跨语言异步调用要检查每条成功、失败、取消路径是否完成且释放同一份 pending 状态。

**2 分钟口头版**：这个问题表面上像 Flutter 页面没有关 loading，但真正原因在鸿蒙图片选择插件。相机先失败，插件仍保留旧请求；第二次相册结果又交给旧回调，新的 Dart Future 就一直等。我的处理不是给页面加超时掩盖它，而是沿原生 delegate 把错误路径的 pending 状态清干净，同时区分“上一个请求没清理”和“真的同时打开两个选择器”。修补版保留上游来源与许可，避免只改缓存后换机器丢失。历史上有最小设备回归入口，本轮只重新编译了 HAP，原生行为仍要在连接设备后重跑。

#### 7.3 首选：报修草稿身份晚到与读取失败混淆

- **现象**：冷启动直接进入报修页，Token 已存在但用户资料没回来，旧草稿不恢复；身份晚到可能覆盖刚输入内容。读取失败若当成“没有草稿”，还会覆盖磁盘数据。
- **排查**：分别构造资料未加载、返回空 ID、晚到资料、换账号、退出页面、磁盘读取失败，不把它们都归为网络慢；记录见 `docs/repair_draft_identity_review.md`。
- **根因**：页面生命周期早于身份解析；草稿键要求稳定用户 ID，而空草稿与读失败不是一个状态。
- **修复**：`a448149` 监听当前会话身份到达并绑定；`094e581` 冷启动按需获取身份，将读取失败单列。位置 `lib/pages/repair/repair_pages.dart:886`、`:912`、`:1061`；`lib/utils/repair_draft_store.dart:30`。有新输入时保留输入，同时保留旧的结果未确认提醒。
- **验证**：本轮包含 `test/repair_identity_test.dart:84` 冷启动恢复、`:208` 晚到身份不能更新新账号、`:436` 读失败保护、`:476` 保留输入与未确认标记，均通过。
- **收获**：身份未知、数据为空、读取失败是三个状态，不能用一个 null 表示。

**2 分钟口头版**：报修草稿必须跟账号走，但冷启动时登录凭证和用户资料不是同时准备好的。页面先打开，就可能找不到正确草稿键。我没有用匿名键凑合，因为换号会串数据，而是等待或主动获取当前会话身份。随后还有一个边界：资料回来前用户已经输入了内容，不能拿旧草稿把新输入盖掉；但旧草稿的“结果未确认”提醒又不能丢。最后我把身份、输入是否编辑、草稿读取是否成功分别管理，并用晚到返回和读失败测试验证。这个经验也能用在任何依赖账号加载本地状态的表单里。

#### 7.4 鸿蒙图片磁盘缓存不可用

- **现象**：网络图片走缓存组件时，鸿蒙缺少相应路径实现，图片加载/缓存初始化失败。
- **排查**：查缓存组件到 path_provider 的依赖，区分网络下载失败与磁盘目录获取失败；不把所有图片错误都归因 URL。
- **根因**：当前依赖组合没有可用的 OHOS 磁盘缓存路径实现。
- **修复**：`6760e10`；`lib/widgets/cached_image.dart:45` 在鸿蒙使用 Image.network 内存缓存，其他平台保留原行为。
- **验证**：该提交增加四个图片回归场景；本轮 `test/cached_image_test.dart` 随全量通过，HAP 构建通过；无本轮物理设备缓存验收。
- **收获**：跨平台包的 Dart API 可用，不等于每个平台底层实现齐全。

#### 7.5 外部图片 401 误触发业务登录处理

- **现象**：下载分享图片时，外部资源返回 HTTP 401，却触发社区业务 Token 的刷新或退出登录，图片服务的问题影响了已登录用户。
- **排查**：沿图片下载进入统一请求拦截器，比较业务请求与带 skipAuthorization 的外部请求；用返回 401 的假 adapter 检查刷新次数、退出事件和保留的 Token。来源 `docs/harmony_share_and_reliability.md:45`，没有记录额外排查弯路，不补造经历。
- **根因**：原拦截器对所有 401 执行业务刷新/登出，没有区分资源所属的认证体系。
- **修复**：`e88ac5e` 的 diff 为 401 分支增加 skipAuthorization 排除条件；后续会话重构保留边界。当前位置 `lib/utils/request_dio.dart:102` 和 `:577`，分别是认证错误分流和外部图片下载的跳过标记；`555d3b5` 补充测试。
- **验证**：本轮 `test/share_download_test.dart:55` 的 “external image 401 never refreshes or clears the app login” 通过，验证不刷新、不发退出事件且 Token 保留；它证明请求边界，不代表外部图片一定能下载成功。
- **收获**：共用 HTTP 客户端不等于共用认证域，错误处理必须先判断请求归属。

未采用长路径问题作为正式案例：`c9575fc` 可以证明子进程启用 core.longpaths，但提交未保留某一次长路径失败的完整现场；不能据此补造具体复现和错误码。

#### 7.6 报修接口 500 与客户端契约缺失

- **现象**：历史外部接口创建报修返回 500，最初只看到通用失败提示。
- **排查**：先 GET 身份、房屋、维修项目及完整分页列表，再用唯一标记做一次受控 curl 创建；拿到 `ER_NO_DEFAULT_FOR_FIELD: Field 'attach' doesn't have a default value`。核对响应中的 API 字段是 attachment 数组，没有盲改 ID 类型或日期。
- **根因**：客户端当时省略了无附件字段；外部服务暴露数据库必填字段错误。没有外部服务端源码、SQL 和当次日志，不能断言完整内部映射或把所有 500 都归到同一原因。
- **修复**：`02e782e` 显式发送 attachment: []，修正分页及历史取消契约；`078b1a3` 增加脱敏错误响应日志。当前 `lib/api/repair.dart:154` 的 submitRepairApi 为请求契约核对入口。
- **验证**：`docs/repair_500_curl_replay.md:37` 保存错误，`:47` 记录历史创建 200/10000、取消后 status=0。本轮使用自建服务临时数据库创建/完成，不重新请求旧外部接口，也不将历史取消路径写入当前 README。
- **收获**：HTTP 500 不代表客户端绝无责任，更不代表服务端一定未写入；先核对完整列表再决定是否重试。

#### 7.7 超时后草稿与重复提交风险

- **现象**：提交超时或中途离页后，用户不确定是否创建成功；直接重试可能形成重复报修，清空表单又会丢输入。
- **排查**：模拟慢返回、离页、账号替换、再次进入与存储写入顺序；检查页面是否把“失败响应”和“结果未知”混成一种状态。
- **根因**：客户端超时不能证明服务端未提交，且本地草稿与异步请求有不同生命周期。
- **修复**：`add2fd1` 引入按用户串行保存、未确认结果标记和再次提交确认。当前 `lib/utils/repair_draft_store.dart:7`、`:23`，`lib/pages/repair/repair_pages.dart:975` 保存草稿，`:1215` 提交，`:1263` 再次提交确认。
- **验证**：本轮 `test/repair_draft_store_test.dart:22` 的 “draft and unconfirmed result survive a new store instance” 和 `:64` 的 “successful cleanup cannot be undone by a pending draft save” 通过；`test/repair_flow_test.dart:359` 覆盖 HTTP 错误不能证明未创建，临时后端完成真实创建。没有幂等键，所以不能说“彻底解决重复订单”。
- **收获**：界面防重复点击、草稿恢复和服务端幂等是三件不同的事。

#### 7.8 排单审核退回：权限、错误信息和状态边界

- **现象**：审核发现首次时间可能由物业代住户确认；409 的具体原因被固定文案覆盖；非管理员时间线暴露原师傅 ID；首次时间未确认就可顺延。
- **排查**：对照角色权限、真实 adapter→RequestDio→页面链路和返回 JSON；已有直接抛 NetworkException 的页面测试没有覆盖错误转换，因此“页面测试过了”仍不足。四项来自本地阶段报告，不等同于四个独立 Git 提交。
- **根因**：复用普通改约入口时遗漏首次特例；公共错误映射丢掉 409 message；直接复用存储事件作为视图；顺延资格没检查 agreement 是否成立。
- **修复**：`998074e` 的 `server/public/admin/app.js:703` 首次提议只读；`bea02bb` 的 `lib/utils/request_dio.dart:516` 保留有效 409 原因；`01bd335` 的 `server/src/repair/views.ts:50` 去掉非 admin 的 previousWorkerId，`policy.ts:28` 阻止未确认顺延。首次服务端权限见 `actions.ts:105`。
- **验证**：本轮 253 个服务端用例包括 `repair-schedule.test.ts:223` 首次只有住户可确认、`repair-dispatch.test.ts:158` 未确认不可顺延、`repair-phase3-contract.test.ts:24` 字段隔离；Flutter 全量覆盖 409 链路。来源 `repair_schedule_phase2_review_fixes.md`、`repair_schedule_phase3_report.md` 复审段和 `repair_schedule_phase4_report.md`。
- **收获**：先验证业务授权和真实转换链，再用页面成功画面作证；AI 生成代码也需要这样的审核。

#### 7.9 未解决：模拟器宿主崩溃

- **现象**：历史 API 24 模拟器在权限切换、返回设置等生命周期路径中宿主退出；不是仅 App 抛 Dart 异常。
- **排查**：隔离小程序、宿主日志/转储、模块与调用栈比对；`docs/emulator_crash_mitigation.md:19` 记录去掉麦克风权限后仍发生 0xc0000374。
- **根因**：尚未完全确认。证据支持 Surface 资源销毁路径异常，但缺少完整分配/复用/所有权证据，不能写成已确认 UAF、double-free 或某 API 版本必然导致。
- **处理**：`076570f` 记录调查边界；权限精简有最小权限收益，**不是宿主崩溃修复**。入口 `tool/watch_emulator_crash_signals.ps1`，历史说明 `docs/emulator_crash_mitigation.md:48`。
- **验证**：已排除“只要移除麦克风权限就稳定”的说法；仍可能涉及宿主生命周期/资源回收。需要同版本完整转储或维护方修复版本做相同复现，当前停在证据不足，且本轮无连接设备。
- **收获**：包构建成功、应用启动、宿主长期稳定必须分别验收。

#### 7.10 未解决：Edge WNS 订阅失败

- **现象**：隐私窗口不能订阅；换持久配置后权限已 granted，但建立 Push Subscription 仍失败，拿不到 endpoint。
- **排查**：查看实际 `edge://push-internals/`，识别 Builtin WNS client；记录 No internet:10010、background task 0x39。去掉部分自动化开关仍失败；普通 HTTPS 和 FCM 连接不能替代 WNS 协议证据。
- **根因**：隐私窗口是第一层原因；持久模式的唯一根因仍未知，待区分网络识别、虚拟网卡、后台任务注册与 Edge WNS 客户端配合。
- **处理**：没有“修好 WNS”的提交。推送接入提交是 `6eda645`，不能用它冒充此故障修复；当前实现 `web/push.js`、`server/src/push-transport.ts`，原始诊断是未提交的 `docs/system_push_diagnosis.md:18`。
- **验证**：已排除“只有页面权限未授予”的解释；TLS 成功不能证明 WNS 已连通，Meta 在运行也不能证明 Clash 是原因。停在需要普通持久浏览器环境和更底层后台任务证据；没有系统推送送达结果。
- **收获**：权限、浏览器订阅、服务端接受、系统送达四层分别证明，不用一个成功状态覆盖整条链。

三个“首选”沿用 Token、插件回调、草稿身份：它们都有具体源码、提交和可解释的输入/输出边界，能深入追问。宿主崩溃与 WNS 适合展示诊断边界，不适合作为“我已修复”的成绩。

### 8. 关于 AI 辅助开发的口径

可以直接说：“方案和规则由我决定，代码在 AI 辅助下完成，我逐步做了审核和测试。”

继续追问时，用本章 7.8 的例子说明实际审核内容：“我不能只看 AI 说测试通过。我会核对首次定时到底由谁确认、409 的原因是不是经过真实请求封装还能显示、原师傅 ID 有没有越权暴露、没确认时间能不能顺延。这些点发现后退回修改，再看对应测试和实际流程。”

不要把代码存在等同于完全独立手写，不虚构团队规模、上线用户量、性能提升比例，也不保证未亲自掌握的底层知识。面对普通改约单方回应这项现存差距，应明确说当前代码行为和需求口径还需对齐。

### 9. 可用于简历的条目（4 条）

- 开发住户、维修师傅、物业 **3 个角色**的社区应用，使用 Flutter、Node.js / Express 与 SQLite，串联房屋审核、报修处理和访客通行码；物业操作通过网页提供。
- 将报修服务组织为 **10 个职责文件**，实现每天 **11 个一小时时段**和默认 / 星期 / 单日 **3 层容量**，通过事务内名额检查与 revision 冲突检测保护排单一致性。
- 为登录态、草稿恢复、工单状态及排单边界建立自动化验证，本轮服务端 **253 项通过**，Flutter **402 项通过、1 项条件跳过**；不将单测数量表述为覆盖率。
- 完成鸿蒙适配中的图片选择回调修补及访客通行码桥接，当前 x64 Debug **HAP 构建通过**；报修返修次数不设上限，每轮售后期均为最终确认完成后 **720 小时**。物理真机、系统推送送达与生产部署尚未验收。

### 10. 本轮验证命令与范围

| 命令 | 本轮结果 |
| --- | --- |
| server 内 npm ci / npm run build / npm test | 安装、编译退出 0；253/253 |
| 根目录 .\tool\flutter_ohos.ps1 test --no-pub | 402 通过 / 1 跳过 / 0 失败 |
| .\tool\build_local_web.ps1 / .\tool\build_workflow_web.ps1 | 均构建成功；Wasm 兼容提示不等于 Wasm 已通过 |
| .\tool\flutter_ohos.ps1 build hap --debug --no-pub -t lib/main.dart --target-platform ohos-x64 | 退出 0，entry-default-signed.hap |
| npm start / npm run demo | 分别在 3000 / 3010 监听成功 |
| .\tool\forward_local_backend.ps1 | 退出 1：没有已连接且可用的设备 |
| 地图代理 + Flutter run -d web-server --web-port=8080 | 启动成功；没有宣称本轮定位数据或真机 GPS 验收 |
| 独立副本的真实 HTTP 演示 | 急单通知存在、定级/调度成功、两角色同 slot、确认后 status=3、星期模板 08 点由可选变不可选 |
| 独立副本的浏览器操作 | 新建漏水急单、物业定级/调度、师傅完工、住户确认完成；周三 09 点模板设 0 后，住户重新打开选择器，该时段消失 |

运行日志放在本机临时目录 `C:\Users\23203\AppData\Local\Temp\haven-docs-evidence\`；本节和演示脚本仅本地保留，不随 README 提交。文中的历史文档保留当时范围，最新实现与本轮结果优先。
