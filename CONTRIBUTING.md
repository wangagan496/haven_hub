# 贡献指南

感谢你对 Haven Hub 项目的关注！本文档将帮助你了解如何为项目做出贡献。

## 开发环境要求

- Flutter SDK 3.6 或更高版本
- Dart SDK 3.6.2 或更高版本
- Android Studio / VS Code (推荐安装 Flutter 插件)
- Git

## 代码规范

### Dart 代码风格

项目遵循 [Effective Dart](https://dart.dev/guides/language/effective-dart) 和 Flutter Lints 规则。

**关键规范：**

1. **命名约定**
   - 类名使用 `PascalCase`
   - 变量、方法名使用 `camelCase`
   - 常量使用 `lowerCamelCase`
   - 文件名使用 `snake_case`
   - 私有成员以 `_` 开头

2. **导入顺序**
   ```dart
   // Dart SDK
   import 'dart:async';
   
   // Flutter
   import 'package:flutter/material.dart';
   
   // 第三方包
   import 'package:dio/dio.dart';
   
   // 项目内部（使用相对路径）
   import '../models/house.dart';
   ```

3. **文档注释**
   - 所有公共类、方法、属性必须添加文档注释
   - 使用 `///` 而不是 `//`
   - 提供使用示例（可选但推荐）
   
   ```dart
   /// 获取房屋列表。
   ///
   /// 返回当前用户的所有房屋信息列表。
   ///
   /// 抛出：
   /// - [NetworkException]: 网络请求失败
   /// - [BusinessException]: 业务逻辑错误
   Future<List<House>> getHouseListApi() async {
     // 实现
   }
   ```

4. **类型安全**
   - 始终显式声明返回类型
   - 避免使用 `dynamic`，除非必要
   - 充分利用 null safety

5. **常量使用**
   - 尽可能使用 `const` 构造函数
   - 将魔法数字提取为常量
   - 使用 `final` 声明不可变变量

### 项目特定规范

1. **错误处理**
   - 网络层错误使用 `NetworkException`
   - 业务逻辑错误使用 `BusinessException`
   - 数据格式错误使用 `FormatException`
   - 使用 `describeError()` 统一转换错误消息

2. **异步操作**
   - 使用 `async/await` 而非 `then()`
   - 在 `initState` 中使用 `unawaited()` 包装异步调用
   - 异步回调前检查 `mounted` 状态

3. **状态管理**
   - 页面级状态使用 `StatefulWidget`
   - 跨页面状态使用 GetX `Controller`
   - 可选：使用 `LoadingStateMixin` 简化加载状态管理

4. **API 调用**
   - 所有 API 方法定义在 `lib/api/` 目录
   - 返回类型化的模型对象，而非 `Map`
   - 提供 typedef 以支持依赖注入（便于测试）

## 提交规范

### Commit 消息格式

使用语义化提交消息：

```
<type>(<scope>): <subject>

<body>

<footer>
```

**类型 (type):**
- `feat`: 新功能
- `fix`: 修复 bug
- `docs`: 文档更新
- `style`: 代码格式调整（不影响功能）
- `refactor`: 重构（不是新功能也不是修复）
- `perf`: 性能优化
- `test`: 添加或修改测试
- `chore`: 构建过程或辅助工具的变动

**示例：**
```
feat(house): add house deletion feature

- Add delete button in house detail page
- Implement deleteHouseApi in API layer
- Add confirmation dialog

Closes #123
```

中文项目也可以使用中文提交消息：
```
feat(房屋): 添加房屋删除功能

- 在房屋详情页添加删除按钮
- 在 API 层实现 deleteHouseApi
- 添加确认对话框

关闭 #123
```

## 开发流程

### 1. Fork 并克隆项目

```bash
git clone https://github.com/your-username/haven_hub.git
cd haven_hub
```

### 2. 创建功能分支

```bash
git checkout -b feature/your-feature-name
```

### 3. 安装依赖

```bash
flutter pub get
```

### 4. 开发

- 编写代码
- 添加/更新测试
- 更新文档（如有必要）

### 5. 运行检查

```bash
# 代码分析
flutter analyze

# 运行测试
flutter test

# 格式化代码
dart format lib test
```

### 6. 提交代码

```bash
git add .
git commit -m "feat: your feature description"
```

### 7. 推送并创建 Pull Request

```bash
git push origin feature/your-feature-name
```

然后在 GitHub 上创建 Pull Request。

## 测试

### 单元测试

```bash
flutter test test/unit/
```

### Widget 测试

```bash
flutter test test/widget/
```

### 集成测试

```bash
flutter test integration_test/
```

### 测试覆盖率

```bash
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html
```

## 目录结构规范

新增文件时遵循以下结构：

```
lib/
├── api/              # API 接口层（一个文件对应一组相关接口）
├── constant/         # 常量定义
├── controller/       # 状态控制器
├── models/          # 数据模型（对应后端 API 的实体）
├── pages/           # 页面组件（按功能模块分组）
│   └── feature/
│       ├── feature_page.dart     # 主页面
│       └── components/           # 页面专用组件
│           └── feature_item.dart
├── platform/        # 平台适配层
├── router/          # 路由配置
├── theme/           # 主题和样式
├── utils/           # 工具类（通用辅助功能）
└── widgets/         # 通用组件（可在多个页面复用）
```

## 性能优化建议

1. **使用 const 构造函数**
   - 对于不会改变的 Widget，使用 `const`

2. **避免不必要的重建**
   - 合理使用 `StatelessWidget`
   - 考虑使用 `const` 和 `final`
   - 将计算密集型操作移出 `build()` 方法

3. **列表优化**
   - 长列表使用 `ListView.builder`
   - 提供 `itemExtent` 或 `prototypeItem`（如果高度固定）

4. **图片优化**
   - 使用适当的图片尺寸
   - 考虑使用 `CachedNetworkImage`

## 常见问题

### Q: 如何添加新的 API 接口？

1. 在 `lib/api/` 对应模块文件中添加函数
2. 定义 typedef（用于依赖注入）
3. 添加文档注释
4. 创建或更新对应的模型类

### Q: 如何添加新页面？

1. 在 `lib/pages/` 创建新目录
2. 创建页面主文件（如 `my_page.dart`）
3. 在 `lib/router/index.dart` 注册路由
4. 添加路由常量 `routeName`

### Q: 分析报错怎么办？

运行 `flutter analyze` 查看具体错误，根据提示修复。常见问题：
- 缺少文档注释：添加 `///` 注释
- 未使用的导入：删除多余的 import
- 类型推断问题：显式声明类型

## 获取帮助

- 查看 [Flutter 文档](https://flutter.dev/docs)
- 查看 [Dart 文档](https://dart.dev/guides)
- 提交 Issue 讨论问题

## 许可证

通过贡献代码，你同意你的贡献将在与项目相同的许可证下发布。
