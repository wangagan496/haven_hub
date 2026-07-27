# haven_hub

享家社区 Flutter 项目。

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

项目使用电脑已有的 `C:\flutter_flutter` Flutter OH SDK。请通过包装脚本
执行鸿蒙命令，脚本会自动使用项目所在 D 盘的依赖缓存，避免 Hvigor
因跨盘插件路径构建失败：

```powershell
.\tool\flutter_ohos.ps1 doctor -v
.\tool\flutter_ohos.ps1 pub get
.\tool\flutter_ohos.ps1 build hap --debug
```

Debug HAP 输出位置：

```text
build\ohos\hap\entry-default-signed.hap
```
