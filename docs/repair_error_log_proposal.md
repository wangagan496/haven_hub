# 失败响应日志：实现与安全边界

日期：2026-10-09。原 Claude 方案已落地，后续复审又补齐了按值泄漏的保护。本文同步到当前工作区。

## 原缺口

HTTP 500 走 Dio 的 onError，不经过成功响应的 onResponse。旧日志只输出 DioException.message，其中虽有状态码文本，却没有独立状态字段或失败响应体。

2026-10-08 的原响应体没有保存在已检查的本地证据中。新请求只能提供新证据，不能恢复旧响应；服务端当次日志或可信接口契约也可以帮助归因，并非只有重放一条路径。

## 当前实现

lib/utils/request_dio.dart 的错误日志记录 type、经自由文本脱敏的 message，以及有响应时通过 _buildResponseLog 记录的 status 和响应摘要。没有响应时不访问空的 response。privateResponse: true 的请求、成功响应和失败响应均不进入网络日志。

保护在日志副本上执行，不改变实际请求、响应或业务异常：

1. 按标准化键名屏蔽 token、密码、手机号、密钥等；顶层业务 code 保留，嵌套验证码字段仍脱敏。
2. String 叶子和错误说明屏蔽 Bearer/Basic 凭证、JWT 形态、敏感字段赋值与独立的大陆手机号。请求日志同样使用这套保护。
3. String 类型的响应体，包括纯文本、HTML 和 JSON 标量字符串，整体省略，仅记录省略标记与长度。
4. 结构化响应日志仍按 500 字符截断。

保留原有 NetworkException / BusinessException 和用户提示语。数据库报错用于 Debug 排查，不直接展示在页面。

## 复审发现及修复

原方案仅按键名脱敏。JSON message 里的凭证回显、含凭证的文本和 HTML 会进入错误日志。按值保护的局限原先已存在于成功路径，而补记失败体使失败路径也暴露了问题。

现在覆盖常见凭证回显并省略非结构化响应体，但不能承诺识别所有秘密。任意没有标签、没有可识别形态的字符串仍可能残留在结构化字段中；需要完全保密的响应应继续使用 privateResponse。

## 验证

test/request_logging_test.dart 当前 10 条测试，使用注入的 Dio 适配器，无真实网络请求。覆盖原有日志脱敏、失败响应状态与安全诊断信息、JSON message 凭证回显、纯文本/HTML 省略、私有失败响应、无响应超时，以及实际请求体不被日志保护改变。

新自由文本保护用例在生产修复前确实失败，修复后通过；原 Claude 的失败日志两条用例也已完成红绿验证。收尾时全量测试 160 条通过（包含后续新增的两条未知报修状态测试），严格静态分析无问题。收尾验证使用 .\tool\flutter_ohos.ps1 test --no-pub --reporter compact 和 .\tool\flutter_ohos.ps1 analyze --no-pub --fatal-infos --fatal-warnings。

日志默认仅 Debug 开启。Release 日志、服务端日志、原生存储故障与任意秘密识别均不属于这些测试的证明范围。

## 新取得的服务端证据

2026-10-09，测试账号完成完整列表核对后，仅做了一次诊断创建，返回 HTTP 500、业务码 500：

> ER_NO_DEFAULT_FOR_FIELD: Field 'attach' doesn't have a default value

这次响应提供了具体数据库字段线索。客户端补齐 attachment: [] 后的实际创建结果，见 docs/repair_device_validation.md 和 docs/repair_work_conclusion.md。不将新响应当作 2026-10-08 原响应的副本。
