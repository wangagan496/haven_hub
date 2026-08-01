# haven_hub 项目 Agent 指引

这是一个 Flutter 项目，编写代码时必须遵守以下规范，优先复用已有封装，不要重复造轮子。

---

## 已封装的核心工具（必须复用）

### 1. UI 提示 → `PromptAction`（`lib/utils/toast.dart`）

```dart
PromptAction.showToast('普通提示');    // 灰色
PromptAction.showSuccess('操作成功');  // 绿色
PromptAction.showError('操作失败');    // 红色
PromptAction.showWarning('格式错误');  // 黄色
```

禁止直接调用 `Fluttertoast.showToast`，禁止使用 `ScaffoldMessenger.showSnackBar`。

### 2. Token 存取 → `tokenManager`（`lib/utils/token_manager.dart`）

```dart
// 全局单例，直接使用
tokenManager.getToken();                               // 同步读取
tokenManager.getRefreshToken();                        // 同步读取
await tokenManager.setToken(token, refreshToken: rt); // 写入，返回 bool
await tokenManager.deleteToken();                      // 清除
```

禁止用 `SharedPreferences` 直接读写 token。

### 3. 网络请求 → `requestDio`（`lib/utils/request_dio.dart`）

```dart
// 全局单例，自动注入 Bearer Token，自动解析业务响应（code == 10000）
// 网络失败抛出 NetworkException，业务失败抛出 BusinessException
await requestDio.get(url, params: {...});
await requestDio.post(url, data: {...});
await requestDio.put(url, data: {...});
await requestDio.delete(url, data: {...});
```

禁止使用 `http` 包或直接 new `Dio()`。

### 4. 错误类型 → `NetworkException / BusinessException`（`lib/utils/app_exception.dart`）

`requestDio` 的公开请求方法会将失败统一转换为以下两种类型，上层 catch 块直接使用：

```dart
// 网络层错误（超时、断网、HTTP 4xx/5xx）→ NetworkException
// 业务层错误（HTTP 200 但 code != 10000）→ BusinessException

// 标准 catch 写法：
} on Object catch (error) {
  final String msg = switch (error) {
    BusinessException() => error.message,
    NetworkException()  => error.message,
    FormatException()   => error.message,
    _                   => '操作失败，请重试',
  };
  await PromptAction.showError(msg);
}
```

禁止在页面层 catch `DioException`，错误已在 `requestDio` 内部处理完毕。

### 5. HTTP 路径 → `HttpPath`（`lib/constant/index.dart`）

```dart
HttpPath.announcement  // 'announcement'
HttpPath.sendCode      // 'code'   GET  发送验证码
HttpPath.login         // 'login'  POST 登录
```

新增接口时，先在 `HttpPath` 中添加路径常量，再在 `lib/api/` 对应文件中编写函数。

---

## 异步方法编写规范

所有页面内的异步操作方法（如提交表单、请求接口）必须遵守：

```dart
bool _isLoading = false; // 防重复提交标志

Future<void> _doSomething() async {
  // 1. 防重复提交
  if (_isLoading) return;

  // 2. 表单校验（失败则 showWarning + return）
  if (someInput.isEmpty) {
    await PromptAction.showWarning('请填写xxx');
    return;
  }

  setState(() => _isLoading = true);
  try {
    final result = await someApi(...);

    // 3. 异步后必须检查 mounted
    if (!mounted) return;

    await PromptAction.showSuccess('操作成功');
    if (!mounted) return;

    Navigator.maybePop(context); // 或其他导航
  } on Object catch (error) {
    final String msg = switch (error) {
      BusinessException() => error.message,
      NetworkException()  => error.message,
      FormatException()   => error.message,
      _                   => '操作失败，请重试',
    };
    await PromptAction.showError(msg);
  } finally {
    if (mounted) setState(() => _isLoading = false);
  }
}
```

---

## 项目文件结构速查

```
lib/
├── api/            # 接口函数（user.dart 含 loginApi、sendCodeApi）
├── constant/       # 常量（HttpPath、GlobalVariable）
├── pages/
│   ├── login/      # 登录页（已有 _login、_sendCode 方法，勿重写）
│   ├── home/
│   ├── mine/
│   └── ...
└── utils/
    ├── toast.dart          # PromptAction
    ├── app_exception.dart  # NetworkException + BusinessException
    ├── token_manager.dart  # TokenManager + tokenManager 单例
    └── request_dio.dart    # RequestDio + requestDio 单例
```

---

## 禁止事项速查

| ❌ 禁止 | ✅ 替代 |
|---|---|
| `Fluttertoast.showToast(...)` | `PromptAction.showXxx(...)` |
| `SharedPreferences` 操作 token | `tokenManager.setToken / getToken` |
| `new Dio()` 或 `http` 包 | `requestDio.get / post` |
| 页面层直接处理 `DioException` | `NetworkException / BusinessException` |
| 异步后直接用 `context` | 先 `if (!mounted) return` |
| 类名写 `HTTP_PATH` | `HttpPath` |
| 登录页重写 `_login()` | 在现有方法上扩展 |
