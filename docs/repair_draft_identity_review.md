# 报修草稿身份时序：只读复审结论

> ## ⚠️ 状态横幅：本文针对历史提交，其发现已被后续改动修复
>
> **本文写于**：提交 `a448149`（基线 `490331e`），复审对象即该提交。
>
> **当前状态**：该提交之后的修复（由 Codex 实施，见 `README.md`、`docs/repair_device_validation.md` 的对应更新）已解决本文提出的**全部三项发现**。提交与发布状态以 Git 记录为准：
>
> | 本文的发现 | 当前状态 |
> |---|---|
> | **§3 P1**：冷启动不访问「我的」标签时，提交被永久阻塞（无恢复手段） | **已修复**。报修页新增 `_ensureIdentity()`，在身份为空时主动调用 `getUserInfoApi` 补取，并提供页内与提交时的重试入口 |
> | **§4.1**：`_draftSaveFailed` 一名两用（读取失败与保存失败混用） | **已修复**。拆分为 `_draftReadFailed` 与 `_draftSaveFailed`，横幅分开显示 |
> | **§4.2**：凭证测试缺「token 已删、refreshToken 残留」的部分清除形态 | **已修复**。新增 `_PartialClearPreferences` 替身与对应用例 |
>
> **行号已过期。** 本文所有 `lib/pages/repair/repair_pages.dart:N` 引用的是 `a448149` 时的行号。后续改动使该文件整体下移约 53–70 行，且 `_restoreDraft` 被拆分为 `_restoreDraft` + `_readDraft`。对照表：
>
> | 本文引用 | 当前实际 | 内容 |
> |---|---|---|
> | `:501` | `:510` | `_currentUserKey()` |
> | `:514` | `:523` | `_sameOwner` |
> | `:535-538` | `:593` | `_scheduleDraftSave` 中 `_formEdited = true` 的置位 |
> | `:552` | `:608` | `_lastOwnedDraft?.record` 回写路径 |
> | `:561` / `:563` | `:617` / `:619` | `_draftSaveFailed` 赋值 |
> | `:567` | `:623`（读取体在 `:641` `_readDraft`） | `_restoreDraft` |
> | `:576` | `:646` | 恢复表单字段的 `setState` |
> | `:608` | `:678`（现为 `_draftReadFailed`） | 读取成功后清除失败标志 |
> | `:649` | `:719` | `_loadOptions` 的 `finally` 补调用 |
> | `:666` / `:685` | `:736` / `:759` | `_submit` 的两处防重复提交检查 |
> | `:671` | `:741` | `_submit` 的 `_draftLoaded` 门 |
> | `:781` | `:855` | `AbsorbPointer` |
> | `:809` | `:902` | 「本机草稿保存不可用」横幅 |
> | `:245` | `:248` | 列表页「新增报修」按钮 |
>
> **§5 的四项结论（跨账号隔离、晚到结果处理、监听释放、凭证测试边界）在后续改动后仍然成立**，且新增的并发用例进一步覆盖了它们。
>
> **阅读建议**：本文的价值在于**解释缺陷的成因链条与判别方法**，不代表当前代码状态。若需评估现有代码，请以工作区实际内容为准，并将本文 §6 的方案视为已被实现（实现细节见 `docs/repair_device_validation.md`）。

**阅读对象**：外部评审（无本仓库访问权限）。

**仓库**：`haven_hub`，Flutter 应用（鸿蒙 / OpenHarmony 为主要交付平台）。

**复审范围**：单个提交 `a448149`「fix(repair): bind drafts when current session identity arrives」，基线 `490331e`。共 6 个文件，`+586/-39`，其中两个新增测试文件占 456 行。

**复审方式**：静态只读复审。未修改任何代码，未独立重跑 `analyze` 与测试套件，未上设备。

---

## 1. 被审改动想解决什么

报修表单页会把用户未提交的填写内容作为「草稿」持久化到本机（`SharedPreferences`），按用户 ID 分键保存，用于离开页面或进程被杀后恢复。

改动前的实现里，草稿的用户键在 `initState` 中**一次性固定求值**：

```dart
// 改动前
late final String _draftUserKey;
...
_draftUserKey = _currentUserKey();
```

页面初始化时用户资料往往还没加载完成，此时 `_currentUserKey()` 返回 `''`，并且此后永不更新。等到用户资料在同一会话内到达、真实用户 ID 变为可用时，归属判断

```dart
// 改动前
bool get _sameOwner =>
    tokenManager.sessionId == _formSessionId &&
    _currentUserKey() == _draftUserKey;
```

就会因为 `'user-a' != ''` 而变成 `false`，导致草稿加载失败或提交时误报「登录账号已变化」。

本次改动把该键改为**可延迟绑定**（`late String`，初始 `''`，在身份到达后绑定一次），注册对 `UserInfoController` 的监听，并把草稿读取、恢复、保存、提交门槛重新梳理了一遍。

---

## 2. 五个复审问题的结论

| # | 问题 | 结论 |
|---|---|---|
| 1 | 空身份在同一会话内的一次性绑定，是否存在跨账号串用路径 | **未发现串用路径**，守卫充分（见 §5.1） |
| 2 | 资料、草稿读取结果晚到，是否会覆盖新输入或丢掉未确认状态 | **正确**：新输入受 `_formEdited` 保护，`resultUnconfirmed` 无条件合并（见 §5.2） |
| 3 | 新增「身份及草稿读取就绪后才能提交」，是否有无法恢复的等待或重复提交窗口 | **重复提交窗口已关闭；但存在一个无法自行恢复的提交阻塞（P1，见 §3）** |
| 4 | 监听注册、释放，以及离开页面后的保存与异步回调 | **正确**（见 §5.4） |
| 5 | 凭证测试的结论是否严格限定在已验证的清理路径内 | **基本严格，但测试模型缺一种清除失败形态**（见 §4.2） |

---

## 3. P1：冷启动路径下的提交被永久阻塞（本次唯一需要改代码的问题）

### 3.1 现象

用户重启应用（进程被杀后重新启动，本机已有持久化登录凭证），**不经过「我的」标签**，直接从首页的报修入口进入「我的报修」列表，再点「新增报修」：

- 页面顶部持续显示：「账号信息尚未就绪，草稿暂未保存；请保留当前页面，待账号信息加载后再提交」；
- 用户可以正常填写表单，但**任何输入都不会落盘**（草稿键为空）；
- 点击「提交报修」得到：「账号信息尚未就绪，请保留当前页面，稍后再提交」，**请求不会发出**；
- 继续等待不会改善——页面只监听身份变化，从不主动获取身份；
- 返回上一页会丢失全部已填内容。

### 3.2 根因链条

**第一步：身份键的求解要求 `UserInfoController` 已被填充。**

```dart
// lib/pages/repair/repair_pages.dart:501
String _currentUserKey() {
  final String Function()? resolver = widget.draftUserKey;
  if (resolver != null) return resolver().trim();
  if (tokenManager.getToken().isEmpty ||
      !Get.isRegistered<UserInfoController>()) {
    return '';
  }
  final UserInfoController controller = Get.find<UserInfoController>();
  return controller.currentUserSessionId == tokenManager.sessionId
      ? controller.currentUser.id.trim()
      : '';
}
```

**第二步：`currentUserSessionId` 只在 `updateUser` 里被赋值。**

```dart
// lib/controller/user_info_controller.dart:21
void updateUser(UserInfo user) {
  currentUser = user;
  _currentUserSessionId = user.id.isEmpty ? null : tokenManager.sessionId;
  update();
}
```

**第三步：`updateUser` 在生产代码中只有两个调用点。**

- `lib/pages/mine/index.dart:171`（「我的」标签拉取用户资料后）
- `lib/pages/profile/index.dart:217`（个人资料编辑页提交后）

**第四步：「我的」标签只在被激活时才拉取资料。**

```dart
// lib/pages/mine/index.dart:74
_isLoggedIn = tokenManager.getToken().isNotEmpty;
if (!_isLoggedIn) {
  _resetSessionState();
} else if (widget.activeIndex == 1) {   // ← 只在“我的”标签激活时
  unawaited(_loadUserInfo());
}
```

`_loadUserInfo()` 的其他触发点只有：登录成功事件（`:104`）、401 刷新事件（`:115`）、以及 `didUpdateWidget` 中标签切换到索引 1（`:137`）。

**第五步：冷启动不会触发上述任何一条。**

- `TabsPage` 初始 `_currentIndex = 0`（`lib/pages/tabs_page/index.dart:29`），`IndexedStack` 构建 `MinePage(activeIndex: 0)`；
- 冷启动**不会**产生 `LoginSuccessEvent`（该事件只在 `lib/pages/login/index.dart:168` 登录流程中触发）；
- `RefreshEvent` 只在某次请求 401 刷新成功时触发（`lib/utils/request_dio.dart:431`）；
- 因此 `MinePage._loadUserInfo()` 不执行，`UserInfoController.currentUser.id` 保持 `''`，`currentUserSessionId` 保持 `null`。

**第六步：`tokenManager.sessionId` 在冷启动时为 0，且 `init()` 不改变它。**

```dart
// lib/utils/token_manager.dart:18
int _sessionId = 0;
```

`init()` 只把凭证从存储读进内存。于是 `null != 0`，`_currentUserKey()` 恒为 `''`。

**第七步：空键导致草稿永远读不完，而提交被 `_draftLoaded` 拦住。**

```dart
// lib/pages/repair/repair_pages.dart:567
Future<void> _restoreDraft() async {
  if (_draftLoaded || _draftLoading || _submitted || !_sameOwner) return;
  if (_draftUserKey.isEmpty) _draftUserKey = _currentUserKey();
  if (_draftUserKey.isEmpty) return;          // ← 键仍为空，直接返回
  ...
}
```

```dart
// lib/pages/repair/repair_pages.dart:671
if (!_draftLoaded) {
  await _restoreDraft();
  ...
  if (!_draftLoaded) {
    await PromptAction.showWarning(_draftUserKey.isEmpty
        ? '账号信息尚未就绪，请保留当前页面，稍后再提交'
        : '草稿尚未读取完成，请保留当前页面，稍后再提交');
    return;                                    // ← 请求不发出
  }
  ...
}
```

`_draftLoaded` 只在草稿**读取成功**后才置 `true`；键为空时永不置 `true`，所以提交被无限期拦截。

### 3.3 这是一次行为回归

改动前的代码在同一状态下是**可以提交**的：

```dart
// 490331e（改动前）
Future<RepairDraft?> _loadDraft() async {
  if (_draftLoaded || _draftUserKey.isEmpty) return null;   // 空键直接返回 null
  ...
}
// _loadOptions 内无条件：_draftLoaded = true;
```

即旧实现中空身份时 `_loadDraft` 返回 `null`、`_draftLoaded` 被无条件置 `true`，`_submit` 也没有 `_draftLoaded` 门；且旧 `_sameOwner` 做的是 `'' == ''`，为 `true`。因此旧路径**提交成功、草稿静默不落盘**（`_saveDraft` 在键为空时自行返回）。

新实现用「读不到草稿就不许提交」来防止跳过磁盘上可能存在的 `resultUnconfirmed` 二次确认——**这个安全目标是对的**，但它把「身份永远不到达」这种状态从「可提交但不存草稿」变成了「完全不可提交且无恢复手段」。

### 3.4 触发条件与影响面

**必然触发**：持久化登录态下的冷启动，且用户在本次进程内未打开过「我的」标签。

**生产可达性**：报修表单的入口是首页 → 「我的报修」列表 → 右下角「新增报修」（`lib/pages/mine/index.dart:45`、`lib/pages/home/components/home_nav.dart:25`、`lib/pages/repair/repair_pages.dart:245`）。这条路径不经过「我的」标签，也不需要用户资料，因此完全可达。路由守卫 `_requireLogin`（`lib/router/index.dart:24`）只检查 token 非空，不会阻止进入。

**影响**：功能不可用 + 用户已填内容无法保存（因键为空）——即页面提示的那句话，用户照做（「保留当前页面」）也不会好转。

### 3.5 恢复路径存在，但不可依赖

只有两种情况能让身份到达：

1. 用户主动切换到「我的」标签——需要先返回，输入丢失；
2. 恰好有某个请求返回 401 并刷新成功——与应用当前行为无关，属偶然。

因此文案「稍后再提交」在当前实现下是**误导性**的：没有任何机制会让那个「稍后」到来。

---

## 4. 次要发现

### 4.1 `_draftSaveFailed` 一名两用（P2，状态语义）

同一标志被草稿**读取失败**（`lib/pages/repair/repair_pages.dart:617`）和**保存失败**（`:561`、`:563`）共用，而界面文案是「本机草稿保存不可用」（`:809`）。读取失败时显示的是保存失败的说明；反过来，一次成功的读取又会把标志清成 `false`（`:608`），可能盖掉此前真实的保存失败。安全方向不受影响（提交仍被 `_draftLoaded` 拦住），属提示准确性问题。

### 4.2 凭证测试的失败模型缺一种形态（P2，测试覆盖）

`test/token_persistence_race_test.dart` 用真实 `SharedPreferencesTokenStorage` + mock 偏好设置后端，断言与实现一致（迟到写入返回 `false`、`sessionVersion` 只在落盘成功后推进、重载后状态符合预期）。文档也明确排除了断电与原生存储故障，结论限定是诚实的。

缺口在于：测试替身 `_DelayedTokenStorage.clear()` 的失败分支是「完全不清除」（`invalidate(); return false;`），而真实实现返回的是**两次删除的与**：

```dart
// lib/utils/token_storage.dart（clear 内）
final bool tokenRemoved = await preferences.remove(GlobalVariable.tokenKey);
final bool refreshTokenRemoved =
    await preferences.remove(GlobalVariable.refreshTokenKey);
return tokenRemoved && refreshTokenRemoved;
```

也就是说真实实现可能出现 **token 已删、refreshToken 残留** 的部分清除状态；该状态下的重启行为（`getToken()` 为空但 `getRefreshToken()` 非空）没有用例覆盖。这不影响现有 4 条结论的正确性，但「已验证清理路径」的边界应再写窄一格。

---

## 5. 已核对为正确的部分

### 5.1 跨账号串用（问题 1）

绑定只发生在 `lib/pages/repair/repair_pages.dart:570`，前置守卫是 `_sameOwner`，其要求 `tokenManager.sessionId == _formSessionId`。`sessionId` 只在登录、`deleteToken`、`invalidateLocalSession` 三处自增（`lib/utils/token_manager.dart:97`、`:132`、`:151`），永不回退，所以同一页面实例的会话窗口内不可能换账号再换回来。

- 空身份时 `_sameOwner` 走 `_draftUserKey.isEmpty` 分支为 `true`，是刻意的「信任当前会话」态；一旦绑定成非空，迟到的不同 ID 会让 `_sameOwner` 变成 `false`，`_restoreDraft` 与 `_scheduleDraftSave` 都直接返回——方向保守。
- 换账号后 `_saveDraft` 走 `_lastOwnedDraft?.record` 写回**旧**键（`:552`），既不会把新账号内容写到旧键，也不会反向污染。
- 未采用 `'u$sessionId'` 作为持久化键是正确的：该值在进程重启后归零，不能代表稳定身份。

### 5.2 晚到结果不覆盖新输入、不丢未确认状态（问题 2）

```dart
// lib/pages/repair/repair_pages.dart:576
setState(() {
  if (draft != null) {
    // 即使已有新输入，也不能丢掉旧草稿的未确认提交记录。
    _resultUnconfirmed = _resultUnconfirmed || draft.resultUnconfirmed;
    if (!_formEdited) {           // ← 仅未编辑时才恢复表单字段
      _restoringDraft = true;
      try { /* 恢复下拉、手机号、描述、日期 */ }
      finally { _restoringDraft = false; }
    }
  }
  _draftLoaded = true;
  ...
});
if (_formEdited) await _saveDraft();   // 保留当前输入，并把合并后的未确认状态写回
```

- `_formEdited` 的置位点在 `_scheduleDraftSave`，且位于 `!_draftLoaded` 早返回**之前**（`:535-538`），所以身份未就绪期间用户打的字会被记住，迟到的草稿不会覆盖它。
- 恢复期间的**程序化赋值**被 `_restoringDraft` 包住（`:536` 的守卫会拦截文本控制器 listener），不会误置 `_formEdited`——这一点处理得正确。
- `_resultUnconfirmed` 是无条件合并的，且只在**读取成功**时执行；读取失败时 `_draftLoaded` 保持 `false`，提交被拦住而不是跳过二次确认。
- `_draftLoaded` 从不在键为空或抛错时被置 `true`——这正是相对于旧实现的核心修正。

### 5.3 重复提交窗口（问题 3 的第二半）

`_submit` 入口查 `_submitting || _submitted`（`:666`），`await _restoreDraft()` 之后又查一次（`:685`）。第二次点击会因 `_draftLoading` 在 `_restoreDraft` 内早返回而只得到一条提示，不会发出第二个请求；`_draftLoaded` 已为 `true` 时，从入口到 `setState(() => _submitting = true)` 之间没有 `await`。`AbsorbPointer(absorbing: _submitting || _submitted)`（`:781`）另有一层拦截。**结论：无重复提交窗口。** 副作用是读取进行中点击提交会得到一条「草稿尚未读取完成」的提示，属体验噪音。

### 5.4 监听与销毁（问题 4）

- GetX 4.7.3 中 `GetxController` 混入 `ListNotifierMixin`，`addListener` 返回 `Disposer = void Function()`，赋给 `VoidCallback?` 类型成立；`listeners` getter 返回 `int`（测试 `expect(users.listeners, 0)` 因此有效）。
- `dispose()` 在 `_saveDraft` **之前**调用释放函数（`:483`）。
- `_onUserInfoChanged` 用 `scheduleMicrotask` 避开构建期，回调内检查 `mounted`（`:520`）。
- `_restoreDraft` 的 `if (!mounted || !_sameOwner) return` 与 `finally { if (mounted) setState(...) }` 覆盖了离开页面后的迟到读写。
- `dispose` 中 `unawaited(_saveDraft())` 先同步取 `_formRecord()` 快照，再 `_mobile.dispose()`，顺序正确；`RepairDraftStore.save` 在首个 `await` 之前就完成 `jsonEncode`，控制器销毁不影响该次写入。
- `_draftTimer` 在 `dispose` 中取消，`_loadOptions` 的 `finally` 里有「覆盖资料恰好到达」的补调用（`:649`）。

---

## 6. 修复方案

### 6.1 方案对比

| 方案 | 取舍 |
|---|---|
| **A. 表单自己按需拉取用户资料**（推荐） | 拦截逻辑保留，阻塞变为可恢复；改动收敛在报修页，不改变全局启动行为 |
| B. 借道 `eventBus.fire(RefreshEvent())` 触发 `MinePage._loadUserInfo` | 改动约 2 行，但把「凭证已刷新」事件当作「请加载身份」使用，且依赖 MinePage 恰好挂载，语义会被后续维护者误读 |
| C. 提交时不拦截，改为一次性确认 | 会绕过磁盘草稿中可能存在的 `resultUnconfirmed` 二次确认，等于退回上一轮修掉的问题 |
| D. `AppInitializer` 启动即拉资料 | 每次冷启动都增加一次网络请求，波及全应用启动路径，超出本次修复范围 |

推荐 A。

### 6.2 推荐方案实现（`lib/pages/repair/repair_pages.dart`）

**（1）新增依赖注入点。** 复用既有 `UserInfoLoader` typedef（`lib/api/user.dart:12`）：

```dart
// 顶部新增 import
import '../../api/user.dart';
import '../../models/user_info.dart';

// RepairFormPage 构造参数新增
final UserInfoLoader userInfoLoader;   // 默认 getUserInfoApi

// state 新增
bool _identityLoading = false;
bool _identityFailed = false;
```

**（2）新增按需取身份方法**（遵循项目异步约定：防重、`mounted`、错误收敛）：

```dart
/// 生产身份由登录会话与用户资料共同决定，而 [UserInfoController] 只在“我的”
/// 标签被激活时才被填充。冷启动直接进入报修页时资料可能始终不到达，草稿键会
/// 一直为空并永久阻塞提交。这里由页面自己补一次加载，让身份能够到达。
Future<void> _ensureIdentity() async {
  if (widget.draftUserKey != null || _identityLoading) return;
  if (_currentUserKey().isNotEmpty) return;
  if (tokenManager.getToken().isEmpty) return;

  final int sessionId = tokenManager.sessionId;
  final UserInfoController users = Get.isRegistered<UserInfoController>()
      ? Get.find<UserInfoController>()
      : Get.put(UserInfoController(), permanent: true);
  setState(() {
    _identityLoading = true;
    _identityFailed = false;
  });
  try {
    final UserInfo info = await widget.userInfoLoader();
    if (!mounted) return;
    // 资料在途中换了账号：旧账号的 ID 不能落到新会话上。
    if (sessionId != tokenManager.sessionId) return;
    if (tokenManager.getToken().isEmpty) return;
    users.updateUser(info); // 触发 _onUserInfoChanged → _restoreDraft
  } on Object {
    if (mounted) setState(() => _identityFailed = true);
  } finally {
    if (mounted) setState(() => _identityLoading = false);
  }
}
```

> `if (sessionId != tokenManager.sessionId) return;` 是本次新增跨 `await` 状态写入的**必备护栏**：`updateUser` 会把 `_currentUserSessionId` 记成当时的 `sessionId`，若不加检查，换账号后到达的旧资料会被绑到新会话上。

**（3）接入两条路径。**

```dart
// _loadOptions 内，选项就绪之后、_restoreDraft 之前
setState(() {
  _houses = values[0] as List<House>;
  _items = values[1] as List<RepairItem>;
  _optionsLoaded = true;
});
if (_draftUserKey.isEmpty) await _ensureIdentity();
await _restoreDraft();
```

```dart
// _submit 内，把硬失败换成可重试
if (!_draftLoaded) {
  if (_draftUserKey.isEmpty) await _ensureIdentity();
  await _restoreDraft();
  if (!mounted) return;
  if (!_sameOwner) {
    await PromptAction.showWarning('登录账号已变化，请返回后重新打开报修页面');
    return;
  }
  if (!_draftLoaded) {
    await PromptAction.showWarning(_identityFailed
        ? '无法获取账号信息，请检查网络后重试'
        : '无法确认当前账号，请返回后重新打开报修页面');
    return;
  }
  // 读取草稿期间其他点击可能已经开始提交。
  if (_submitting || _submitted) return;
}
```

> 两个分支文案是必要的：`getUserInfoApi`（`lib/api/user.dart:41`）**不校验返回的 id**（对比 `updateUserInfoApi` 会显式抛 `FormatException`）。资料请求成功但 `id` 为空时，`updateUser` 会把 `currentUserSessionId` 置为 `null`，键仍为空——此时提示「检查网络」是错的。

**（4）横幅加可重试入口。**

```dart
if (_draftUserKey.isEmpty)
  Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: _identityFailed
        ? Row(children: <Widget>[
            const Expanded(child: Text('无法获取账号信息，草稿暂未保存')),
            TextButton(onPressed: _ensureIdentity, child: const Text('重试')),
          ])
        : const Text('账号信息尚未就绪，草稿暂未保存；请保留当前页面，待账号信息加载后再提交'),
  ),
```

### 6.3 测试计划

**红-绿顺序很重要**：先只加注入字段（不接线）→ 写测试并观察到失败 → 再实现接线。否则无法证明测试真的覆盖了缺陷。

`test/repair_identity_test.dart` 新增 5 条（该文件已有 11 条，均不注入 `draftUserKey`，走生产身份解析分支）：

1. **冷启动按需取身份并恢复草稿**：注入返回 `UserInfo(id: 'user-a')` 的 loader；断言 loader 被调用 1 次、`saved A draft` 被恢复、「账号信息尚未就绪」横幅消失、提交发出 1 个请求。**接线前该用例必然失败于「loader 调用次数为 0」。**
2. **取身份失败可重试**：首次 `throw const NetworkException(...)`；断言不发出请求且文案为「无法获取账号信息，请检查网络后重试」；随后置为成功再点提交，断言请求发出。证明不存在永久阻塞。
3. **迟到的身份不能绑定已换账号**：用 `Completer<UserInfo>` 卡住请求，期间 `tokenManager.setToken('account-b')`，再放行；断言 `users.currentUser.id` 仍为空、无请求发出、`store.load('user-a')` 为 `null`。这是新增异步护栏的针对性测试。
4. **无 token 时不发起请求**：断言 loader 调用 0 次。
5. **按需取到身份后仍保留未确认状态**：磁盘草稿 `resultUnconfirmed: true`；断言提交时仍弹出「上次提交结果未确认」对话框。证明本次改动没有绕过既有的重复创建确认。

**既有用例的迁移**：`test/repair_flow_test.dart` 的 `form()` 辅助函数需新增 `userInfoLoader` 透传参数。多数用例注入 `draftUserKey: () => 'test-user'`，因 `widget.draftUserKey != null` 会整体跳过新路径，不受影响。

**必须处理的一处**：`test/repair_flow_test.dart:464` 的 `'stale profile id from previous login cannot restore its draft'` 走 `productionIdentity: true` 且已设置 token，接线后会真的发起 HTTP 请求。需给该用例注入 `userInfoLoader: () async => const UserInfo.empty()`——`updateUser(empty)` 会把 `currentUserSessionId` 置 `null`、键保持为空，断言与现在一致。

### 6.4 文档同步

- `README.md:130` 当前表述为「等待账号信息就绪后再提交」，需改为「页面主动获取账号信息，失败可重试」。
- `docs/repair_device_validation.md` 的边界段落同步补充。

### 6.5 验证与验收标准

```powershell
.\tool\flutter_ohos.ps1 test --no-pub --reporter expanded test/repair_identity_test.dart
```

```powershell
.\tool\flutter_ohos.ps1 analyze --no-pub --fatal-infos
```

验收标准：新增 5 条先红后绿；全量测试 131 + 5 条通过；`analyze` 无告警。

---

## 7. 证据边界（重要）

1. **本复审是静态只读的。** 提交作者报告「`analyze` 无问题、131 条测试通过」，该结果未被本次复审独立复现。
2. **未上设备。** 修复方案会**新增一个网络依赖**（表单自己拉取用户资料）。真实设备上的时序（断网、慢网、401 刷新窗口内到达、鸿蒙 `SharedPreferences` 行为）只有用真实账号在模拟器上才能确认。
3. **现有设备烟测覆盖不到这条分支。** `tool/repair_lifecycle_smoke.dart` 注入了 `draftUserKey`，绕过了基于 `UserInfoController` 与登录会话派生用户 ID 的生产分支。`docs/repair_device_validation.md` 已如实记录该边界。
4. **凭证测试结论仅限于已验证的清理路径**（见 §4.2 的缺口）。
5. 本次复审未涉及「GET 刷新后不自动重放」的既定行为，该行为本次未改动。

---

## 8. 请外部评审判断的问题

1. 是否认同「表单主动补拉用户资料」（方案 A）优于借用 `RefreshEvent` 触发 `MinePage` 加载（方案 B）？是否存在改动更小且语义更干净的第三种做法（例如把 `_loadUserInfo` 从 `MinePage` 上移到应用级、由「已登录」而非「标签激活」驱动）？
2. 提交前的**硬拦截**是否应该完全移除，改为「身份未就绪时提示风险 + 用户明确确认后允许提交」？硬拦截的安全收益（保证不跳过磁盘上的 `resultUnconfirmed` 确认）是否值得其可用性代价？
3. §6.2 中的 `sessionId` 护栏是否足够覆盖换账号竞态？是否还需要同时检查 token 内容变化，或复用一个统一的会话快照对象？
4. 「身份到达前用户输入不落盘」是既有约束，本方案未改变。是否应接受用一个本机匿名键暂存未绑定输入？其风险（把草稿归属问题从内存搬到磁盘）是否大于收益？
5. 是否认同 §4.2 指出的「部分清除」状态需要补充测试用例？
