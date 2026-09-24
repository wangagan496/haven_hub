# 鸿蒙通行码分享与报修稳定性

本轮范围：鸿蒙系统分享现有通行码图片，以及报修流程的可靠性与测试。不新建正式后端，不改课程服务端接口。

## 1. 从按钮到鸿蒙原生的真实调用链

```text
VisitorDetailPage._share
  → loadVisitorPassImage(record.url)
  → requestDio.getExternal（字节流，不带登录 Token）
  → 页面仍 mounted 才继续
  → shareVisitorPassImage(bytes)
  → MethodChannel('haven_hub/visitor_pass_share').invokeMethod('shareImage')
  → VisitorPassSharePlugin.onMethodCall（ArkTS）
  → 校验图片、写入应用私有缓存、生成文件 URI
  → systemShare.SharedData → ShareController.show
  → dismiss 回调 → MethodResult.success(null) → Dart Future 完成
```

主要代码：`lib/platform/visitor_pass_share.dart`、`lib/pages/visitor/visitor_pages.dart`、`ohos/entry/src/main/ets/VisitorPassSharePlugin.ets`。
`EntryAbility.configureFlutterEngine` 在已有插件注册之后注册本地分享插件；没有修改自动生成的插件注册文件。

### 关键设计与限制

- 复用 `requestDio`，不创建页面专用 Dio。图片 GET 不带业务 Token、不自动跟随重定向，且不记录图片地址、内容或请求详情。
- 修复外部资源返回 HTTP 401 时误触发业务 Token 刷新/登出的行为；业务接口原有刷新逻辑保持。
- 支持 PNG/JPEG，最大 5 MiB；流式读取时检查大小，读取间隔超时 15 秒；原生再次检查字节、格式及图片尺寸（最多 1600 万像素）。其他格式或重定向地址返回错误，不伪造成功。
- 页面忙碌标记阻止重复下载与分享。下载后同时检查 mounted、前台状态、是否顶层路由；下载期间进入后台，即使回来也不会自动弹出面板。原生准备期间失焦会结束本次请求，已打开系统面板造成的失焦不当作失败。
- 将分享按钮在 Flutter 窗口内的位置、尺寸乘以 devicePixelRatio，经通道传入 ShareControllerAnchor（像素），为平板/PC 等设备提供 Popup 锚点。
- 原生用 `AbilityAware` 管理 UIAbility 上下文，解绑时移除回调、完成挂起请求；同时最多一个面板请求。
- 只传图片字节，不额外发送姓名、手机号、住址或 encryptedData。图片自身包含的信息保持原样，仍由用户选择是否分享及接收目标。
- 分享文件保存在应用缓存子目录。下次分享时清理本功能超过 24 小时的旧文件；不在面板关闭时立即删除，避免接收应用还未读取。
- `show` 成功、面板关闭、对方收到图片是不同事件。当前 API 对外只等待面板关闭，不把关闭视为发送成功，也不把所有关闭都称作“取消”。
- 用服务端 `status` 和图片是否存在决定按钮可用性。`validTime` 是有效时长，不是明确的到期时间戳，不据此编造本地过期时刻。真实通行权限仍由服务端/门禁校验。
- 非鸿蒙端禁用分享并显示说明，既有详情内容仍能查看。

## 2. 已复现并修复的可靠性问题

| 问题 | 根因 | 改法与回归证据 |
|---|---|---|
| 连点取消报修会叠加确认框 | 原锁只覆盖请求阶段，没有覆盖确认阶段 | 增加确认阶段标记；同帧调用两次只出现一个弹窗 |
| 退出后出现迟到的取消错误提示 | catch 中缺少 mounted 检查 | 提交和取消失败都先检查 mounted；退出后成功/失败均不影响新页面 |
| 请求 bool 返回值的路由类型不匹配 | 应用创建 `MaterialPageRoute<void>`，报修/访客使用 `pushNamed<bool>` | 统一当前页面 bool/null 返回约定；生产路由工厂与提交/取消返回刷新均有回归测试 |
| 同帧连续提示导致 OverlayEntry 销毁断言 | 已 insert 但尚未首帧 mounted 时，跳过 remove 而直接 dispose | 已保存的 entry 一律先 remove 再 dispose；连续两条提示只保留最后一条 |
| 外部图片 401 影响业务登录 | 原拦截器对所有 401 执行刷新/登出 | 排除 skipAuthorization 请求；验证不刷新、不发登出事件、Token 保留 |

正常提交后列表重新取数；取消后保留记录并显示服务端返回的“已取消”，不自行隐藏历史记录。首次失败可重新加载，已有列表刷新失败时保留原内容。网络写请求不做自动重试，避免结果不明时重复创建记录。客户端防连点不等于服务端幂等保证。

## 3. 验证方法与实际边界

本轮 2026-09-20 验证：

- 第一轮自动化测试 29 项通过；官方文档复核后补充前后台/路由覆盖、锚点传输和坐标转换场景，总计 32 项（原有 7 项，新增 25 项）。
- `./tool/flutter_ohos.ps1 analyze --no-pub`：无问题。
- 鸿蒙 ARM64 正常入口与 x64 测试入口分别构建；构建成功不代表真实接口验收。
- 本机 Pura 90 API24 鸿蒙模拟器：安装本地测试入口，显示测试图片，打开系统分享并预览，关闭后恢复按钮，再次打开成功。
- Widget 渲染：360×800、1024×768，文字倍率 1×/2×；检查截图、溢出和按钮可点击区域。
- 未创建、修改、取消真实报修或访客；未向联系人发送图片；未验收实体真机、多设备差异、真实通行码地址或接收方实际收图。

### 重跑自动化测试

```powershell
.\tool\flutter_ohos.ps1 analyze --no-pub
.\tool\flutter_ohos.ps1 test --no-pub
```

页面接口与图片预览可替换，测试不请求课程后端，不依赖设备登录。`test/share_download_test.dart` 验证请求边界；`test/visitor_share_test.dart` 的通道替身只证明 Dart 调用契约，原生面板另外通过模拟器检查。

Windows 可选截图输出（使用本机微软雅黑与 Material 图标字体）：

```powershell
$env:HAVEN_VISUAL_QA = '1'
.\tool\flutter_ohos.ps1 test --no-pub test/visitor_share_layout_test.dart
Remove-Item Env:HAVEN_VISUAL_QA
```

截图位于忽略提交的 `build/verification/`。正常测试不要求安装本机字体。

### 无真实账号的原生分享演示

```powershell
.\tool\flutter_ohos.ps1 run -t tool/visitor_share_smoke.dart -DeviceId <设备ID>
```

该入口直接加载标记 `TEST IMAGE / NOT A PASS` 的本地测试图，不访问业务接口，不初始化账号。页面明确说明“本地测试数据 · 无通行权限”。默认 `lib/main.dart` 不导入它。仍使用原应用包名，仅用于开发模拟器，不能把此入口构建当成正式应用交付。

正常入口构建：

```powershell
.\tool\flutter_ohos.ps1 build hap --debug --no-pub -t lib/main.dart --target-platform ohos-arm64
```

### 后续真实设备验收

使用本人授权的测试访客记录：确认图片 URL 为可读取的 PNG/JPEG；进入详情、打开面板、取消、重复打开。实体设备测试下载失败和返回页面。只有在用户确认接收目标后才测试实际发送，并让接收方验证图片可读。过期、已访问、无图片记录应禁止分享。

## 4. 面试讲解：先理解，再使用自己的表述

可以围绕已经验证的内容解释：

> 我在 Flutter 社区应用中加入了鸿蒙原生图片分享，通过 MethodChannel 把图片字节传给 ArkTS，再调用系统分享。实现时处理了 UIAbility 生命周期、重复操作、页面退出、临时文件和错误映射。原生面板在鸿蒙模拟器上验证过，真实业务接口和接收方收图是另外的验收项。

> 报修模块除了正常业务流程，我还用可控接口函数测试延迟响应、失败重试和页面退出。测试复现了取消确认框叠加、迟到提示，以及路由返回类型问题，修复后新增提交与取消都能刷新列表。

理解检查：为什么不把 Token 发给图片服务器？为什么下载后再检查 mounted？为什么 Flutter 测试中的通道替身不能证明原生面板可用？为什么关闭分享面板不能提示“发送成功”？为什么已取消报修仍保留在列表？

项目采用现成课程后端。测试替身、客户端能力与个人实际掌握程度应分开描述，不声称独立开发了正式后端、完成了生产级验收或已经掌握尚未理解的代码。

## 5. 官方文档与本地技能专项复核

复核依据是已加载的华为官方正文、本地 SDK 声明和实际框架源码，不能以“打开过网页”或“读过技能入口”代替逐项检查。华为正文通过浏览器实际加载读取，文档显示更新时间为 2026-09-09。

| 核对项 | 官方依据 | 本项目结论 |
|---|---|---|
| 图片记录与类型 | [分享图片](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/share-utd-image) | 精确 PNG/JPEG UTD、沙箱文件 URI、DETAIL 预览符合示例；不把整张图片放进分享服务的元数据 |
| 文件 URI | [应用文件分享](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/share-app-file) | 使用 fileUri.getUriFromPath，不手工拼接；自有沙箱缓存不需要申请图库读取权限。startAbility 直接分享的 Want flags 不能机械套用到 ShareController |
| 面板位置 | [通过分享面板发起分享](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/share-mobilephone-app-share) | 补充按钮像素坐标锚点；官方针对 2in1 示例明确演示锚点配置 |
| 回调含义 | [systemShare](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/share-system-share)、[获取分享结果](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/share-share-completed) | show 是显示，dismiss 是关闭；shareCompleted 返回分享渠道并且从 API 18 起提供，不等同于接收方确认。当前不依赖它，维持 API 12 兼容基线 |
| Flutter 生命周期 | [mounted](https://api.flutter.dev/flutter/widgets/State/mounted.html)、[didChangeAppLifecycleState](https://api.flutter.dev/flutter/widgets/WidgetsBindingObserver/didChangeAppLifecycleState.html) | mounted 只表示 State 仍在树中；新增前台与顶层路由检查，并以测试复现原检查不足 |
| 通道机制 | [Flutter 平台通道](https://docs.flutter.dev/platform-integration/platform-channels) | 通道名称、异步调用、错误映射符合机制；鸿蒙端 Uint8Array 和 AbilityAware 契约另核对当前 flutter_ohos 源码，没有把 Android/iOS 示例当作鸿蒙实现 |

技能复核范围：`harmonyos-suite` 分流入口，以及 `harmonyos-development` 的 ArkTS 规则、平台基线、分享专题、Stage 生命周期和文件管理专题。按其要求将本地桥接改用 `@kit.*` 导入，未升级 SDK，也没有照搬快照中的版本默认值。

本节记录的上次复核配置为 compatible API 12、target API 23，不代表后续升级后的当前配置。实际已用的 ShareController/show/dismiss 在本地声明中从 API 11 提供；跨设备能力还需按设备类型核验。手机 API 24 或平板 API 23 验证，不等于完成全部 API 12 设备兼容性验收。后续 API 24 升级结果另见 [API 24 验证与清理](api24_validation_and_cleanup.md)，不将本节历史证据算作升级后的验证。

复核后的设备证据：手机 Pura 90 API24 模拟器再次验证了原生面板打开、关闭恢复及重新打开。尝试启动本机 MatePad Pro 13 API23 模拟器失败，其日志报告 `can not read uuid file`，因此平板 Popup 的实际效果仍待验证；锚点数据与坐标换算已有自动化测试，不能把这两者混为一项验收。未修改或下载平板镜像。
