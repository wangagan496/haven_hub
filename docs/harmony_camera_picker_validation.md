# 鸿蒙系统相机调用复核（2026-11-12）

本文前几节保留故障排查时的历史结论；2026-11-13 已实现并验证应用内 Camera Kit 备用拍照，当前结果见末节，系统相机组件本身仍未补装。

## 已确认的故障

本次获准临时用于享家社区验收的现有 QijuGuanjia API24 模拟器，在调用系统拍照选择器时缺少目标系统应用 `com.huawei.hmos.camera`，因此无法启动其 `PickerAbility`，原生接口返回 `undefined`。

该结论限定于本次实例及当前系统镜像，不据此断言所有鸿蒙模拟器均不支持拍照，也不代表真机拍照已经通过验收。

## 实测证据

在业务 HAP 的 EntryAbility 中临时增加诊断，直接使用 UIAbilityContext 调用系统接口，绕过 Flutter 和 image_picker 插件；分别从 `@kit.CameraKit` 和 `@ohos.multimedia.cameraPicker` 导入调用，两者均返回 `undefined`。

2026-11-12 22:30:21 的同一调用链日志：

```text
model=emulator sdk=24 syscap=true
cameras=2
GetAbilityContext type is ABILITY
StartAbility ability:com.huawei.hmos.camera/PickerAbility
bundle not exist -n com.huawei.hmos.camera -u 100
ExplicitQueryAbility no match -n com.huawei.hmos.camera -a PickerAbility
generate ability request local error:2097152
StartCameraAbility failed
kitReturn=undefined
directReturn=undefined
```

系统能枚举摄像头、声明 Camera.Core 能力，不等于系统拍照选择器所依赖的相机应用已经安装；本次失败发生在启动该应用阶段。

SDK 声明 `cameraPicker.pick(...)` 应返回 `Promise<PickerResult>`；当前镜像在启动相机应用失败后返回空值，解释了插件层直接调用 `.then()` 时的异常。无 saveUri 的最小原生调用仍失败，因此调整保存路径不能解决本次缺失组件的问题。

原始日志保存在本次任务产物目录 `C:/Users/23203/.codex/visualizations/2026/11/07/01a1b42a-9fd1-7930-87ba-c5212d0cff55/native-camera-hilog.txt`，关键片段位于第 3086–3177 行。

## 验收边界

应用已有 `camera_unavailable` 空值保护与相册替代提示；该保护避免把接口空值当作 Promise，但无法补齐系统相机组件。本次未修改系统镜像、安装来源不明的系统应用、清除模拟器数据或新建模拟器。

本轮临时原生诊断已从 EntryAbility 源码移除，诊断标记检索无匹配，业务 HAP 重新构建、覆盖安装并启动成功，UI 转储确认恢复至包含“我的房屋”“我的报修”“访客登记”的业务首页；拍照成功仍需在具备目标系统相机组件的环境单独实测。

## 系统相机补装来源核查（2026-11-13）

用户同意继续核查补装方式后，检查了本机 SDK、模拟器工具目录、下载目录，并以只读方式检查当前实例引用的 API24 原始镜像；未找到可直接补装的相机 HAP。

当前镜像元数据为 HarmonyOS 6.1.1 / API24 / x86，软件版本 6.1.0.126，guestVersion 为 HarmonyOS 6.1.0.126(SP1)。通过 WSL 已有的 debugfs 只读打开原始 system.img 和 sys_prod.img，没有挂载、修改镜像或操作实例数据分区；检查 /system/app、/preload、/system/variant/phone/base、/system/variant/phone/china 和 sys_prod 的 /app，未发现相机应用目录。该结论仅覆盖实际列出的预装目录，不把未发现包等同于证明任何来源都无法提供该组件。

复核脚本为任务产物目录中的 check-camera-package.ps1，设备应用清单与上述目录结果记录在 camera-package-inventory.txt。

同时核对当前华为官方文档正文：

- [CameraPicker 开发指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/camera-picker)：界面由系统提供，无需申请相机权限。
- [Camera Kit 简介](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/camera-overview)：模拟器仅支持 1280×720 分辨率下的预览与拍照能力。
- [模拟器扩展能力](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-emulator-more-features)：支持使用电脑摄像头；26.0.0 起提供虚拟相机输入功能。
- [创建模拟器](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-emulator-create)：介绍镜像下载与更新，没有提供本次缺失系统相机组件的独立安装入口。

官方文档中的摄像头预览/拍照能力，不足以证明本次镜像包含 CameraPicker 依赖的系统应用；打开虚拟相机输入也不能据此视为已经补齐该应用。公开检索未找到经过来源及 API24/x86 匹配核实的官方独立安装包，因此本轮没有安装系统相机，拍照仍未恢复。未更换或重装镜像，未新建、重启、清空模拟器，也未从其他项目设备提取系统应用。

后续技术路径需区分：取得与当前镜像匹配的官方系统组件，或在应用内使用 Camera Kit 自建拍照界面以绕过系统应用依赖；后者是代码实现变更，本轮没有实现，也没有将其描述为已验证的修复。

## 官方故障指引与应用侧交叉核验（2026-11-13）

本轮按用户要求补查官方常见问题，并检查是否可能是应用或 Flutter 插件导致；不能将当前结论概括为“鸿蒙系统本身有缺陷”。

### 不经过业务应用的复核

核对设备所属实例后，直接向当前模拟器执行 `aa start -b com.huawei.hmos.camera -a PickerAbility`，结果为：

```text
error: failed to start ability.
Error Code:10104001  Error Message:The specified ability does not exist
Error cause: The specified Ability is not installed
```

此命令不经过享家社区表单、Dart 代码或 image_picker 插件；参数取自此前系统 CameraPicker 自己发出的启动请求，不是自行猜测的相机包名。结合此前 `bm dump -a` 未列出该包、原生 API 同样失败的证据，可排除“仅由 Flutter 插件造成这次目标组件不存在”的解释；不能据此宣布应用所有相机相关实现都正确，也不能证明补齐组件后就必然能拍照。

Windows 当前识别到 `USB2.0 HD UVC WebCam`，设备状态为 `OK`，仅说明主机检测到摄像头，未实际打开摄像头采集图像，不能证明模拟器透传、权限、分辨率或采集链路全部正常。

### 官方内容与适用范围

1. [aa 工具：10104001](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/aa-tool)明确将该错误解释为指定 Ability 不存在，要求核对 `-a` / `-b` 参数，再通过 `bm dump -a` 和 `bm dump -n` 检查应用及所属 HAP 是否安装；本轮实测与该分类一致，文档没有给出系统相机 HAP 的独立下载地址。
2. [CameraPicker API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-camerapicker)要求在 UIAbility 中调用；原生复核日志已显示 `GetAbilityContext type is ABILITY`，且已进入目标组件查询阶段；[CameraPicker 指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/camera-picker)说明无需相机权限、saveUri 可省略，之前省略 saveUri 的原生试验仍复现失败。
3. [相机 API 调用时序问题](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/camera-api-faq)、[相机预览流启动问题](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/camera-previewoutput-faq)、[会话配置问题](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/camera-sessionconfig-faq)给出的措施包括按顺序创建输入输出流、校对 profile/SurfaceId、配置 session；这些针对应用直接管理 Camera Kit 会话，不能直接修复本次系统拍照组件在启动前即不存在的错误。
4. [模拟器真机预览器调试差异常见问题](https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs/simulator-faq-0001)提供无真机或模拟器能力受限时使用云调试的路径，这是进一步区分环境与应用问题的验证途径，不是已经执行的修复；本轮没有登录云调试、预订设备或上传 HAP。
5. [图片获取与保存实践](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/images-get-preservation-practice)明确区分系统相机与自定义相机，并提供 Camera Kit 自定义拍照路线；这为应用内拍照提供官方依据，但仍需实现并实测，不等于这台模拟器的拍照已经恢复。

补查结果：已找到与独立复现一致的官方错误分类及排查步骤，未找到适用于本次镜像缺失组件的官方补装/参数修复步骤；目前可确认的阻塞是当前实例的目标组件缺失，不能将其升级为对整个 HarmonyOS 平台的结论。

## 应用内备用拍照实现与设备验收（2026-11-13）

本轮实现了应用内 Camera Kit 拍照页，绕过当前镜像缺失的系统相机应用：默认仍调用 image_picker，仅在相机来源返回 `camera_unavailable` 时进入备用桥接；原生桥接目前限定 emulator，图库、拒绝权限以及其他错误不会触发备用路径。房屋照片、头像与共用头像选择器的报修照片接入同一 Dart 封装，真机备用路径未开放、未验收。

原生页面申请相机权限，使用模拟器支持的 1280×720 profile；照片回调验证 JPEG 和实际尺寸，按调用方质量重新编码，在应用缓存保存，用户选择“使用照片”后才返回 Flutter。提供重拍、取消、返回键取消与后台取消，释放采集资源并清理未接受照片；已接受缓存保留供 Flutter 读取，后续拍摄清理本模块超过 24 小时的旧缓存。当前调用方的 1600 像素上限高于备用输出的 1280 像素，备用界面固定使用该 profile。

本轮设备实证（现有 QijuGuanjia API24，经用户明确授权临时使用）：

- 独立 Camera Kit 采集实际成功：`CAPTURE_VERIFIED width=720 height=1280 bytes=101795`，JPEG 可解码，已超过此前仅能枚举摄像头的证据范围。
- 正式业务房屋编辑页进入预览、拍照、重拍、再次拍照、使用照片返回表单成功；本机隔离 SQLite 后端新增照片记录，编码为 PNG 后大小 573524 字节。
- 返回键取消后回到表单并恢复上传按钮，再次打开预览成功；按 Home 进入后台后回到应用，备用拍照已取消，表单可继续操作。
- 早期 UI 转储捕捉到保存中的按钮禁用状态；增加保存状态响应，并先释放 photo 再关闭相机会话，日志证实资源释放完成，实际点击重拍与使用照片成功。不能把中间状态转储直接当作永久卡死证据。
- 19 项相关 Flutter 测试通过，4 个直接相关 Dart 文件静态检查无问题，业务 HAP 构建及覆盖安装成功。

设备验收使用本机隔离后端，照片未发送远端，未提交房屋资料修改；未重启、清空或新建模拟器。证据 UI 转储位于任务产物目录 `camera-state-retake.json`、`camera-state-second-capture.json`、`camera-state-used.json`、`camera-cancel-back.json`、`camera-reopen-after-back.json` 与 `camera-background-return.json`。摄像头内容未导出展示。

限制：此结果确认当前实例的应用内备用拍照及房屋照片回填上传，不代表系统 CameraPicker 已修复，也不替代真机、其他镜像、所有业务页面的逐项设备验收。预览保持此前实测成功的 Surface 布局；尝试附加比例/底层交互调整后出现采集超时，已撤回这两处附加调整，不能据此声称预览比例已经做过视觉验收。

最终源码移除临时诊断标记后重新构建、覆盖安装，房屋入口再次完成拍照、使用照片、回填及上传；隔离后端新增 PNG 为 1006770 字节，证据为 `camera-release-preview.json`、`camera-release-confirm.json`、`camera-release-used.json`。退出编辑返回原房屋详情，未提交修改，最后回到业务首页（`camera-release-home.json`）。源码检索 `DEBUG-camera` / `NativeCameraProbe` / `havenCameraProbe` 无残留；直接相关已跟踪文件的 `git diff --check` 通过。
