# Haven Hub 项目面试准备指南

> 本指南帮助你系统学习 Haven Hub 项目，掌握核心技术和业务逻辑，应对实习面试和笔试。

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

#### Token 自动刷新与重放

**流程**：
```
请求 → 401 → 检查 RefreshToken → 调用刷新接口 
    → 成功：存储新 Token，用新 Token 重放原请求
    → 失败：清除凭证，触发登出事件
```

**关键代码**：[`RequestDio` 拦截器](lib/utils/request_dio.dart:76-162)

**重放条件**（三个必须同时满足）：
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
> 技术栈方面，使用 **Flutter + GetX + Dio**，实现了**Token 自动刷新**、**日志脱敏**、**异步状态管理**等功能。项目有 **32 个自动化测试用例**，代码质量通过 Flutter Analyze 检查。

### 2. 技术难点讲解

#### 示例 1：Token 自动刷新与重放

> **背景**：用户长时间使用应用，Token 可能过期，如果每次都让用户重新登录，体验很差。
>
> **方案**：实现 Token 自动刷新机制。当接口返回 401 时，自动调用刷新接口获取新 Token，然后用新 Token 重放原请求。
>
> **难点**：如何避免跨账号重放？比如用户 A 的请求在飞行途中，用户 B 登录并刷新了 Token，这时不能用 B 的 Token 去重放 A 的请求。
>
> **解决**：引入**会话 ID** 和**会话版本号**。会话 ID 只在登录/登出时变化，版本号在每次写 Token 时递增。重放时检查三个条件：
> 1. 同一会话（sessionId 相同）
> 2. 凭证确实换代（sessionVersion 不同）
> 3. 这次推进来自刷新（refreshSessionVersion == sessionVersion）
>
> 只有三个条件同时满足才重放，否则清除凭证并登出。

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
4. **真实的生产级代码**：有完整的测试、文档和可靠性改造

面试时，你可以从**业务理解**、**技术实现**、**工程质量**三个维度展开，展示你的全面能力。

**祝你面试顺利！** 🎉
