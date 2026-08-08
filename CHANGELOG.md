# 变更日志

本文档记录 Haven Hub 项目的所有重要变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，
本项目遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

### 当前验证状态（2026-08-06）
- 房屋列表、详情、编辑、添加房屋、位置、楼栋、房间、表单、保存和删除流程已通过浏览器真实操作验证。
- Web 调试使用 `tool/web_api_proxy.dart`，腾讯位置服务通过本地代理处理浏览器跨域限制。
- 当前仓库不保留自动化测试文件；功能回归以浏览器真实流程和 `flutter analyze --no-pub --no-fatal-infos` 为准。

### 新增
- 创建 `BuildingInfo` 模型类，替代 Map 存储建筑信息
- 新增 `LoadingStateMixin` 用于统一异步加载状态管理
- 新增 `Validators` 工具类，提供可组合的表单验证
- 为 `House` 模型添加便捷方法：`genderText`, `statusText`, `isPending`, `isApproved`, `isRejected`
- 创建 `CONTRIBUTING.md` 贡献指南
- 创建 `.env.example` 环境配置示例文件
- 在 `analysis_options.yaml` 中启用更多 lint 规则

### 变更
- **[破坏性]** `BuildController.buildingInfo` 类型从 `Map<String, dynamic>` 改为 `BuildingInfo` 对象
  - 迁移指南：使用 `buildingInfo.name` 替代 `buildingInfo['name']`
- 优化 `LocationList` 搜索过滤性能，添加结果缓存
- 改进 README.md，添加项目结构和技术栈说明
- 为所有公共 API 添加详细的文档注释

### 修复
- 修复 `BuildController` 类型安全问题
- 修复 `location_list.dart` 中的 Map 类型声明
- 统一房屋、位置、楼栋、房间相关页面的 `AppRoutes` 路由
- 修复房屋详情和表单的类型化路由参数解析
- 修复首页房屋导航 import 的大小写问题
- 删除公告详情的 404 测试页面入口

### 文档
- 完善 `lib/constant/index.dart` 文档注释
- 完善 `lib/api/house.dart` 文档注释
- 完善 `lib/models/house.dart` 文档注释
- 完善 `lib/utils/app_exception.dart` 文档注释
- 完善 `lib/controller/build_controller.dart` 文档注释

### 验证
- ✅ 静态分析无编译错误
- ✅ 浏览器真实流程验证通过

## [1.0.0] - 2026-08-05

### 新增
- 初始版本发布
- 用户认证与个人信息管理
- 房屋信息录入与审核
- 社区公告浏览
- 基于腾讯位置服务的智能选址
- 多平台支持（Android、iOS、HarmonyOS、Web）

### 技术特性
- Flutter 3.6+ 支持
- Null Safety 完整支持
- GetX 状态管理
- Dio 网络请求封装
- Token 自动刷新机制
- 统一错误处理

---

## 版本说明

### 语义化版本格式

给定版本号 MAJOR.MINOR.PATCH (主版本号.次版本号.修订号)，递增规则如下：

1. **MAJOR (主版本号)**: 做了不兼容的 API 修改
2. **MINOR (次版本号)**: 向下兼容的功能性新增
3. **PATCH (修订号)**: 向下兼容的问题修正

### 变更类型

- **新增 (Added)**: 新功能
- **变更 (Changed)**: 现有功能的变更
- **弃用 (Deprecated)**: 即将移除的功能
- **移除 (Removed)**: 已移除的功能
- **修复 (Fixed)**: 错误修复
- **安全 (Security)**: 安全相关的修复

---

## 里程碑

- **v1.0.0** (2026-08-05) - 初始版本发布
- **v1.1.0** (计划中) - 性能优化和代码质量提升

---

[未发布]: https://github.com/your-org/haven_hub/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/your-org/haven_hub/releases/tag/v1.0.0
