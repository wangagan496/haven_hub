# 失败响应日志：实现与安全边界

更新日期：2026-10-28；下方保留 2026-10-09 的历史实现与验证证据。

## 当前实现：固定摘要，不遍历业务数据

为避免先遍历、复制完整响应再截短的开销，网络日志默认只记录请求方法、短路径、HTTP 状态、外层数字业务码、成功响应耗时和错误类型；请求头、查询参数、请求体、响应业务正文和原始错误说明默认省略。

路径超过 512 个字符时整体省略，短路径中的可识别手机号和凭证继续脱敏；privateResponse 请求仍不记日志，实际请求、响应和业务异常不变。

需要排错时，给该次请求传入 `RequestDio.logDetails`，仅选择确认可记录的字段，例如：

```dart
await requestDio.post(
  'repair',
  data: repairData,
  options: RequestDio.logDetails(
    requestLogFields: ['houseId', 'revision'],
    responseLogFields: ['message'],
  ),
);
```

该设置只作用于使用这份 Options 的请求，不开启全局详细模式，也不越过 Logger.enabled 或 privateResponse。请求字段从第一层请求体读取，非 Map 请求体则从查询参数读取；响应字段只从第一层响应体读取。不支持嵌套路径，不扫描整个对象，请求和响应各最多检查所选的前 5 个字段，字段名最多 40 字符，文字值超过 200 字符时整体省略；对象、列表等嵌套值跳过。

常见敏感字段名会被拦截，短文字中能识别的凭证和手机号继续脱敏；调用方仍需选择确认可记录的字段，任意无标签秘密无法可靠自动识别。未传入诊断选项的其他请求仍使用摘要，完整调查可结合服务端证据。

当前回归用例位于 test/shared/request_logging_test.dart，覆盖成功、失败、无响应超时、私有响应、实际数据不变、长路径、大型嵌套响应、单次诊断的范围以及字段数量和长度限制。

新增单次诊断后，使用 tool/flutter_ohos.ps1 运行该测试文件，16 项通过；测试证明默认日志及诊断日志均不遍历嵌套业务数据，未进行真机内存或吞吐基准测试。

## 原缺口

HTTP 500 走 Dio 的 onError，不经过成功响应的 onResponse。旧日志只输出 DioException.message，其中虽有状态码文本，却没有独立状态字段或失败响应体。

2026-10-08 的原响应体没有保存在已检查的本地证据中。新请求只能提供新证据，不能恢复旧响应；服务端当次日志或可信接口契约也可以帮助归因，并非只有重放一条路径。

## 2026-10-09 实现（已替换）

lib/utils/request_dio.dart 的错误日志记录 type、经自由文本脱敏的 message，以及有响应时通过 _buildResponseLog 记录的 status 和响应摘要。没有响应时不访问空的 response。privateResponse: true 的请求、成功响应和失败响应均不进入网络日志。

保护在日志副本上执行，不改变实际请求、响应或业务异常：

1. 按标准化键名屏蔽 token、密码、手机号、密钥等；顶层业务 code 保留，嵌套验证码字段仍脱敏。
2. String 叶子和错误说明屏蔽 Bearer/Basic 凭证、JWT 形态、敏感字段赋值与独立的大陆手机号。请求日志同样使用这套保护。
3. String 类型的响应体，包括纯文本、HTML 和 JSON 标量字符串，整体省略，仅记录省略标记与长度。
4. 结构化响应日志仍按 500 字符截断。

保留原有 NetworkException / BusinessException 和用户提示语。数据库报错用于 Debug 排查，不直接展示在页面。

## 2026-10-09 复审发现及修复

原方案仅按键名脱敏。JSON message 里的凭证回显、含凭证的文本和 HTML 会进入错误日志。按值保护的局限原先已存在于成功路径，而补记失败体使失败路径也暴露了问题。

现在覆盖常见凭证回显并省略非结构化响应体，但不能承诺识别所有秘密。任意没有标签、没有可识别形态的字符串仍可能残留在结构化字段中；需要完全保密的响应应继续使用 privateResponse。

## 历史验证

test/shared/request_logging_test.dart 当前 10 条测试，使用注入的 Dio 适配器，无真实网络请求。覆盖原有日志脱敏、失败响应状态与安全诊断信息、JSON message 凭证回显、纯文本/HTML 省略、私有失败响应、无响应超时，以及实际请求体不被日志保护改变。

新自由文本保护用例在生产修复前确实失败，修复后通过；原 Claude 的失败日志两条用例也已完成红绿验证。收尾时全量测试 160 条通过（包含后续新增的两条未知报修状态测试），严格静态分析无问题。收尾验证使用 .\tool\flutter_ohos.ps1 test --no-pub --reporter compact 和 .\tool\flutter_ohos.ps1 analyze --no-pub --fatal-infos --fatal-warnings。

日志默认仅 Debug 开启。Release 日志、服务端日志、原生存储故障与任意秘密识别均不属于这些测试的证明范围。

## 新取得的服务端证据

2026-10-09，测试账号完成完整列表核对后，仅做了一次诊断创建，返回 HTTP 500、业务码 500：

> ER_NO_DEFAULT_FOR_FIELD: Field 'attach' doesn't have a default value

这次响应提供了具体数据库字段线索。客户端补齐 attachment: [] 后的实际创建结果，见 docs/repair_device_validation.md 和 docs/repair_work_conclusion.md。不将新响应当作 2026-10-08 原响应的副本。
