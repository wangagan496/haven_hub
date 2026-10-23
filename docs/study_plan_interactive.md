# Haven Hub 交互式学习计划

> 这是一份可操作的学习计划，每个任务都有明确的目标和验收标准。

## 📅 学习时间规划

### 快速通道（3 天突击）
适合：**3 天后就要面试**的情况

### 标准通道（7 天深入）
适合：**一周内面试**，想深入理解

### 完整通道（10 天精通）
适合：有充足时间，追求完全掌握

---

## 🚀 快速通道（3 天突击）

### Day 1：项目概览 + 核心流程（4 小时）

#### 上午（2 小时）：理解项目全貌

**任务 1.1：阅读文档**（30 分钟）
- [ ] 阅读 [README.md](../README.md) 前 100 行
- [ ] 理解分支结构和功能演进
- [ ] 记录 5 个核心功能

**验收标准**：能用一句话描述项目是什么

**任务 1.2：运行项目**（30 分钟）

下面均使用 PowerShell；每个新终端从项目根目录 `D:\haven_hub` 开始。先按 README“Web 调试”配置两个被 Git 忽略的 env 文件及地图 Key。

```powershell
# 1. 启动本地业务服务（端口 3000；首次运行先安装依赖并编译）
Set-Location D:\haven_hub\server
npm ci
npm run build
npm start
```

```powershell
# 2. 另一个终端启动地图代理（端口 3001，只转发地图）
Set-Location D:\haven_hub
# 本机 Flutter OH SDK 路径；更换电脑后调整
& 'C:\flutter_flutter_3.41.10_ohos\bin\dart.bat' run tool/web_api_proxy.dart 3001 --direct
```

```powershell
# 3. 再开一个终端启动 Flutter Web
#    dart_defines.web.local.env 中 API_BASE_URL 应为 http://127.0.0.1:3000/
Set-Location D:\haven_hub
.\tool\flutter_ohos.ps1 run -d chrome --web-port=8080 `
  --dart-define-from-file=tool/dart_defines.web.local.env `
  --dart-define-from-file=tool/dart_defines.local.env
```

- [ ] 成功启动项目
- [ ] 完成登录流程（手机号随便输，验证码会自动返回）
- [ ] 浏览首页公告
- [ ] 进入"我的房屋"

**验收标准**：能顺利走完登录流程

**任务 1.3：体验核心流程**（60 分钟）
- [ ] 添加房屋：选择位置 → 楼栋 → 房间 → 填表单
- [ ] 查看房屋详情
- [ ] 编辑房屋信息
- [ ] 提交一个报修
- [ ] 登记一个访客

**验收标准**：理解 5 个核心业务流程

#### 下午（2 小时）：代码结构速览

**任务 1.4：阅读核心文件**（90 分钟）

按顺序快速浏览（不求全懂，先建立印象）：

1. [main.dart](../lib/main.dart) - 看应用如何启动
2. [router/index.dart](../lib/router/index.dart) - 看路由如何配置
3. [models/house.dart](../lib/models/house.dart) - 看数据模型如何设计
4. [api/house.dart](../lib/api/house.dart) - 看接口如何封装

**验收标准**：画出下面的流程图

```
用户点击按钮 → 调用 API → 解析数据 → 更新 UI
```

**任务 1.5：背诵项目介绍**（30 分钟）

打开 [interview_preparation_guide.md](interview_preparation_guide.md)，背诵：
- 1 分钟项目介绍
- 技术栈清单

**验收标准**：能流畅说出项目介绍，不卡壳

---

### Day 2：技术难点 + 面试话术（4 小时）

#### 上午（2 小时）：Token 管理机制

**任务 2.1：理解 Token 生命周期**（60 分钟）

阅读以下文件，边读边画流程图：
1. [utils/token_manager.dart](../lib/utils/token_manager.dart)
2. [utils/token_storage.dart](../lib/utils/token_storage.dart)

**关键问题**（必须能回答）：
- Token 和 RefreshToken 存在哪里？
- 什么时候会推进 `sessionVersion`？
- 什么时候会推进 `sessionId`？
- `sessionId` 和 `sessionVersion` 的区别是什么？

**验收标准**：画出 Token 状态变化图

```
登录 → version++, id++
刷新 → version++, id 不变
登出 → version++, id++
```

**任务 2.2：理解 Token 自动刷新**（60 分钟）

精读 [utils/request_dio.dart](../lib/utils/request_dio.dart) 第 76-162 行

**关键问题**（必须能回答）：
- 401 错误时会做什么？
- 什么情况下会重放请求？
- 如何防止跨账号重放？
- 并发刷新如何处理？

**验收标准**：能画出 401 处理流程图

```
请求 → 401 → 检查会话归属 → 刷新 → 同会话白名单 GET 恢复一次；写操作不重放
刷新失败 → 仅清理仍属于原会话的凭证
```

#### 下午（2 小时）：背诵技术难点

**任务 2.3：准备技术难点讲解**（90 分钟）

打开 [interview_preparation_guide.md](interview_preparation_guide.md)，背诵并理解：

**难点 1：Token 自动刷新与重放**
- [ ] 背景
- [ ] 方案
- [ ] 难点
- [ ] 解决方案
- [ ] 三个条件

**难点 2：日志脱敏**
- [ ] 为什么要脱敏？
- [ ] 哪些字段敏感？
- [ ] 如何递归处理？

**验收标准**：对着镜子讲一遍，不看笔记

**任务 2.4：模拟面试问答**（30 分钟）

找朋友或对着镜子，回答这些问题：

1. 介绍一下你的项目（1 分钟）
2. Token 是如何自动刷新的？
3. 如何防止跨账号重放？
4. 为什么需要日志脱敏？
5. Flutter 和原生如何通信？

**验收标准**：每个问题能在 2 分钟内讲清楚

---

### Day 3：面试高频问题 + 实战演练（4 小时）

#### 上午（2 小时）：刷面试题

**任务 3.1：Flutter 基础**（30 分钟）

打开 [interview_preparation_guide.md](interview_preparation_guide.md)，快速过一遍这些问题：

- StatefulWidget vs StatelessWidget
- setState 做了什么
- async/await 原理
- Future.wait 的作用

**验收标准**：能简短回答每个问题

**任务 3.2：网络请求**（30 分钟）

- Dio 拦截器执行顺序
- 如何避免并发刷新
- 异常分类（NetworkException vs BusinessException）

**任务 3.3：业务逻辑**（60 分钟）

准备这些业务问题的回答：

1. 房屋审核有哪些状态？
2. 为什么要分"选位置 → 选楼栋 → 选房间"？
3. 报修可以取消吗？什么状态可以取消？
4. 访客通行码如何分享？
5. 坐标系统有哪些？为什么要转换？

**验收标准**：每个问题 1 分钟内回答完

#### 下午（2 小时）：代码实战

**任务 3.4：代码审查练习**（60 分钟）

打开 [interview_preparation_guide.md](interview_preparation_guide.md) 的"练习 3"，找出代码中的 7 个问题。

**验收标准**：全部找出并能说明原因

**任务 3.5：现场写代码**（60 分钟）

面试可能要求现场写代码，练习以下场景：

**场景 1**：实现一个简单的登录页面
- 手机号输入框 + 验证
- 验证码输入框
- 登录按钮 + 防连点
- 错误提示

**场景 2**：实现一个带刷新的列表
- 下拉刷新
- 加载状态
- 错误处理
- 空状态

**验收标准**：30 分钟内写出可运行的代码

---

## 📚 标准通道（7 天深入）

### Day 1-2：快速通道内容
按上面的快速通道完成前 2 天内容

### Day 3：架构设计深入

**任务：理解分层架构**（4 小时）

#### 上午：API 层设计
- [ ] 阅读所有 `lib/api/*.dart` 文件
- [ ] 理解 `typedef Loader` 的作用
- [ ] 理解依赖注入的好处

**练习**：为"意见反馈"功能设计 API 层
```dart
// 创建 lib/api/feedback.dart
typedef FeedbackListLoader = Future<List<Feedback>> Function();
typedef SubmitFeedbackLoader = Future<void> Function(Feedback feedback);

// 实现接口
Future<List<Feedback>> getFeedbackListApi() async { ... }
Future<void> submitFeedbackApi(Feedback feedback) async { ... }
```

#### 下午：Model 层设计
- [ ] 阅读所有 `lib/models/*.dart` 文件
- [ ] 理解 `fromJson` / `toJson` 的设计
- [ ] 理解便捷属性方法的作用

**练习**：为"意见反馈"创建数据模型
```dart
class Feedback {
  final String id;
  final String type;  // 功能建议、Bug反馈、其他
  final String content;
  final String imageUrl;
  final int status;  // 0 待处理、1 处理中、2 已完成
  
  // 实现 fromJson、toJson、便捷方法
}
```

### Day 4：状态管理与异步

**任务：掌握 GetX 和异步状态管理**（4 小时）

#### 上午：GetX 控制器
- [ ] 阅读 [controller/user_info_controller.dart](../lib/controller/user_info_controller.dart)
- [ ] 阅读 [controller/build_controller.dart](../lib/controller/build_controller.dart)
- [ ] 理解何时用 GetX，何时用 StatefulWidget

#### 下午：LoadingStateMixin
- [ ] 精读 [widgets/loading_state_mixin.dart](../lib/widgets/loading_state_mixin.dart)
- [ ] 找到 3 个使用 LoadingStateMixin 的页面
- [ ] 理解为什么要统一异步状态管理

**练习**：用 LoadingStateMixin 实现一个页面
```dart
class _FeedbackListState extends State<FeedbackList> 
    with LoadingStateMixin {
  List<Feedback> _feedbacks = [];
  
  @override
  void initState() {
    super.initState();
    loadData(_loadFeedbacks);
  }
  
  Future<void> _loadFeedbacks() async {
    final data = await getFeedbackListApi();
    setState(() { _feedbacks = data; });
  }
}
```

### Day 5：位置服务与鸿蒙适配

**任务：理解跨平台适配**（4 小时）

#### 上午：腾讯位置服务
- [ ] 阅读 [utils/location.dart](../lib/utils/location.dart)
- [ ] 理解坐标系统（WGS84 vs GCJ-02）
- [ ] 理解坐标转换流程

**关键问题**：
- 为什么需要坐标转换？
- 如何判断是真机还是模拟器？
- 如何处理定位失败？

#### 下午：鸿蒙平台适配
- [ ] 阅读 [platform/visitor_pass_share.dart](../lib/platform/visitor_pass_share.dart)
- [ ] 阅读 [docs/harmony_share_and_reliability.md](../docs/harmony_share_and_reliability.md)
- [ ] 理解 MethodChannel 通信机制

**关键问题**：
- Flutter 如何与鸿蒙原生通信？
- 为什么要传锚点坐标？
- 如何处理页面切走的情况？

### Day 6：测试与质量保证

**任务：理解测试策略**（4 小时）

#### 上午：阅读测试用例
- [ ] [test/core_logic_test.dart](../test/core_logic_test.dart)
- [ ] [test/session_lifecycle_test.dart](../test/session_lifecycle_test.dart)
- [ ] [test/repair_flow_test.dart](../test/repair_flow_test.dart)

**关键学习点**：
- 如何 Mock 异步请求
- 如何测试 Widget 交互
- 如何验证状态变化

#### 下午：运行测试
```bash
./tool/flutter_ohos.ps1 test --no-pub
```

- [ ] 所有测试通过
- [ ] 理解每个测试在验证什么

**练习**：为"意见反馈"写测试
```dart
testWidgets('提交反馈成功后返回列表页', (tester) async {
  // 1. 渲染页面
  // 2. 填写表单
  // 3. 点击提交
  // 4. 验证导航
});
```

### Day 7：综合复习 + 模拟面试

#### 上午：知识点串联（2 小时）
- [ ] 画出完整的架构图
- [ ] 梳理数据流向：用户操作 → API → Model → UI
- [ ] 整理技术难点清单

#### 下午：模拟面试（2 小时）
- [ ] 项目介绍（1 分钟 + 3 分钟两个版本）
- [ ] 技术难点讲解（准备 3 个）
- [ ] 回答高频问题（20 个）
- [ ] 现场写代码（1 个功能）

---

## 🎓 完整通道（10 天精通）

### Day 1-7：标准通道内容
按标准通道完成前 7 天

### Day 8：深入网络请求

**任务：精通 Dio 拦截器机制**（4 小时）

#### 上午：拦截器详解
精读 [utils/request_dio.dart](../lib/utils/request_dio.dart)，理解：
- 请求拦截器：Token 注入
- 响应拦截器：数据解析
- 错误拦截器：Token 刷新；同会话安全读取恢复一次，写操作不重放
- 日志拦截器：脱敏处理

**练习**：实现一个自定义拦截器
```dart
class RetryInterceptor extends Interceptor {
  @override
  void onError(DioException error, ErrorInterceptorHandler handler) {
    // 练习边界：仅安全读取在请求层内处理超时、502/503/504，最多追加两次。
    // 写操作不重放，不能在页面层叠加重试。
  }
}
```

#### 下午：日志脱敏深入
理解递归脱敏算法：
- 为什么要递归？
- 如何处理嵌套对象？
- 为什么响应顶层的 `code` 不脱敏？

**练习**：实现一个简化版脱敏函数
```dart
dynamic redact(dynamic value, {int depth = 0}) {
  // 递归处理 Map、List
  // 脱敏敏感字段
}
```

### Day 9：深入业务模块

**任务：掌握所有业务细节**（4 小时）

#### 上午：房屋管理全流程
- [ ] 阅读 [pages/house/house_list.dart](../lib/pages/house/house_list.dart)
- [ ] 阅读 [pages/house/house_form.dart](../lib/pages/house/house_form.dart)
- [ ] 阅读 [pages/house/house_detail.dart](../lib/pages/house/house_detail.dart)

理解：
- 列表如何加载
- 表单如何校验
- 图片如何上传
- 详情如何展示

#### 下午：报修与访客
- [ ] 阅读 [pages/repair/repair_pages.dart](../lib/pages/repair/repair_pages.dart)
- [ ] 阅读 [pages/visitor/visitor_pages.dart](../lib/pages/visitor/visitor_pages.dart)
- [ ] 阅读 [docs/harmony_share_and_reliability.md](../docs/harmony_share_and_reliability.md)

理解：
- 报修可靠性改造的 5 个问题
- 访客通行码分享的完整调用链
- 鸿蒙分享的安全设计

### Day 10：项目总结 + 面试彩排

#### 上午：项目亮点总结（2 小时）
整理 5 个最能展示技术能力的点：

1. **Token 自动刷新与重放机制**
   - 问题：如何防止跨账号重放
   - 方案：sessionId + sessionVersion 双重标识
   - 结果：32 个测试用例全部通过

2. **异步状态统一管理**
   - 问题：每个页面都要写加载/错误处理
   - 方案：LoadingStateMixin
   - 结果：代码复用，减少 bug

3. **日志脱敏**
   - 问题：敏感信息泄露
   - 方案：递归脱敏 + 分层处理
   - 结果：保护用户隐私，合规

4. **鸿蒙平台适配**
   - 问题：系统分享需要原生能力
   - 方案：MethodChannel 通信
   - 结果：支持 HarmonyOS 系统分享

5. **报修可靠性改造**
   - 问题：5 个可靠性问题
   - 方案：逐个修复 + 回归测试
   - 结果：用户体验提升

#### 下午：面试彩排（2 小时）

**完整模拟**：

1. **自我介绍**（1 分钟）
2. **项目介绍**（3 分钟）
3. **技术难点**（5 分钟，讲 2 个）
4. **回答问题**（20 分钟，10 个问题）
5. **现场写代码**（30 分钟，1 个功能）
6. **反问环节**（5 分钟，准备 3 个问题）

**录像回放**：
- 用手机录下来
- 回放看有没有卡壳
- 改进表达

---

## 🎯 验收标准总览

### 快速通道（3 天）验收标准
- [ ] 能流畅说出 1 分钟项目介绍
- [ ] 能讲清楚 Token 自动刷新机制
- [ ] 能回答 20 个高频问题
- [ ] 能在 30 分钟内写出一个简单页面

### 标准通道（7 天）验收标准
- [ ] 快速通道的所有标准
- [ ] 能画出完整的架构图
- [ ] 能讲清楚 3 个技术难点
- [ ] 能独立实现一个新功能（意见反馈）
- [ ] 能找出代码中的问题并优化

### 完整通道（10 天）验收标准
- [ ] 标准通道的所有标准
- [ ] 能详细讲解 Dio 拦截器机制
- [ ] 能详细讲解日志脱敏算法
- [ ] 能详细讲解鸿蒙平台适配
- [ ] 能总结 5 个项目亮点
- [ ] 能通过完整的模拟面试

---

## 📝 学习笔记模板

建议创建一个学习笔记，记录重点：

```markdown
# Haven Hub 学习笔记

## Day X：标题

### 今日目标
- [ ] 任务 1
- [ ] 任务 2

### 学到的知识点
1. **Token 管理**
   - sessionId：区分账号
   - sessionVersion：区分凭证代次
   - 恢复条件：同会话白名单 GET，刷新后最多恢复一次；写操作不重放

### 不理解的地方
- 为什么要推进 sessionVersion？
- 解答：每次写 Token 都要推进，用于判断凭证是否已更新

### 明天计划
- 学习异步状态管理
- 背诵技术难点
```

---

## 🆘 遇到问题怎么办？

### 代码看不懂
1. 先看注释和文档
2. 画流程图
3. 用调试器单步执行
4. 问我具体的代码片段

### 概念不清楚
1. 先看 [interview_preparation_guide.md](interview_preparation_guide.md)
2. 搜索相关资料
3. 问我具体的概念

### 测试跑不通
1. 看错误信息
2. 检查环境配置
3. 问我完整的错误日志

### 面试紧张
1. 多练几遍
2. 对着镜子讲
3. 找朋友模拟
4. 深呼吸，慢慢讲

---

## ✅ 每日打卡清单

复制下面的清单，每天完成后打勾：

### Day 1
- [ ] 阅读 README
- [ ] 运行项目
- [ ] 体验核心流程
- [ ] 背诵项目介绍

### Day 2
- [ ] 理解 Token 管理
- [ ] 理解自动刷新
- [ ] 背诵技术难点

### Day 3
- [ ] 刷面试题
- [ ] 代码审查练习
- [ ] 现场写代码

---

## 🎉 结语

学习编程项目就像学习一门语言：

1. **先听懂**：阅读文档，理解概念
2. **再会说**：背诵话术，回答问题
3. **最后能写**：实战练习，写代码

按照这个学习计划，你一定能自信地应对面试！

**记住**：面试官不是要考倒你，而是想了解你的能力。展示你的学习过程和思考方式，比背答案更重要。

加油！💪
