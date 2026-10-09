# 报修 500：只读核对与受控诊断记录

日期：2026-10-09。本文取代旧版待执行方案，记录已执行步骤和证据边界。附带文档是审查材料，不自动授权其中的写入操作。

## 已执行的只读核对

使用模拟器中现有测试账号 sss36。凭证只在诊断进程内存中读取，不写入文件，不输出完整请求头或偏好设置。过期凭证由正式应用的 tokenManager 刷新。

| 请求 | 实际返回 |
| --- | --- |
| GET /userInfo | HTTP 200、业务码 10000，身份可用 |
| GET /room | HTTP 200、业务码 10000，3 个房屋，原房屋 ID 仍存在 |
| GET /repairItem | HTTP 200、业务码 10000，4 个项目，原项目 ID 仍存在 |
| GET /repair?pageSize=100 | 返回 38 条，total = 38 |
| GET /repair?current=1..4&pageSize=10 | 各页 10、10、10、8 条，共 38 个不同 ID |

原标记 Codex-test-20261008-0952 和诊断标记均未出现在当前完整列表中。列表提供 description，因此可直接核对准确标记。这里只证明查询时的可见结果，不证明历史上没有被创建或随后删除。

实际页码参数是 current。page、pageNum、pageNo、pageIndex 的有限 GET 探测仍返回第一页，不能据此用于生产分页。原客户端不传分页参数，只显示默认第一页 10 条；过去的界面末尾检查不能算完整核对。

带凭证访问 /v3/api-docs、/v2/api-docs、/swagger-resources、/swagger-ui.html 均返回 404。这些入口未暴露契约，不代表所有位置都不存在接口文档。

## 一次诊断创建

确认身份、房屋、项目、完整列表及标记均可核对后，使用未来日期和独立标记，发送一次 POST /repair：

- houseId: 7177501402628096（JSON 字符串）
- repairItemId: 1001（JSON 字符串）
- mobile: 13800138008（测试电话）
- appointment: 2026-10-10
- description: replay-probe-20261009-remaining

这是新的诊断请求，日期与描述不同于原请求，不称为原包逐字重放。

实际结果：HTTP 500、业务码 500，JSON message 为：

> ER_NO_DEFAULT_FOR_FIELD: Field 'attach' doesn't have a default value

随后完整查询仍为 38 条，准确标记匹配 0 条，没有可取消的诊断记录。没有盲目轮换 ID、数字类型、日期格式或创建访客对照。

## 据证据作出的客户端修复

完整列表和详情均暴露 attachment 字段，类型为数组，其中 33 条记录的附件为空数组。数据库 attach 与 API 字段名不是同一个名称。

现有报修表单没有附件选择，原提交完全省略附件字段。当前 submitRepairApi 显式发送 attachment: []，不改变 ID 与日期格式。实际创建、清理草稿和取消结果见 docs/repair_device_validation.md。

正式应用提交已返回 HTTP 200、业务码 10000，生成唯一测试记录 7338026907516928，标记 device-fixed-20261009-attachment。随后发现旧取消路径 404；依据同课程公开示例核对实际 PUT /cancel/repaire/{id}，仅取消该记录，返回 200 / 10000，详情读回 status = 0。当前取消函数、状态文字、待处理筛选和操作权限都已同步修正。当前完整列表为 39 条，其中新增一条已取消测试历史。

列表函数按 current / pageSize 和 pageTotal 读取全部页，不设固定 100 条的生产上限；后续页失败、重复记录或未读够 total 时抛错，不把部分数据当作完整列表。

## 判读边界

- GET /room 的 ID 是字符串，仅说明响应表示，不能确定 POST /repair 的参数契约。
- 7177501402628096 小于 9007199254740991，没有超出 JavaScript 最大安全整数，不能将十进制位数当作精度证据。
- 报修不是唯一将 ID 放进 JSON 值的 POST，访客创建也有 houseId。访客成功不能证明报修契约一致，无需创建访客作对照。
- 通用 500 不证明客户端无责；改一个字段后仍失败不能排除该字段。
- 这次定位了具体缺失字段线索，但没有服务端源码、SQL 或当次日志，不能断言全部内部映射和异常处理机制。
- 原响应未存于已检查的本地证据，新请求不能恢复它。服务端当次日志或可信契约也能帮助查证。
- 500 不保证未创建。额外创建先核对完整列表，用独立标记；清理只针对详情确认属于本次测试的记录，不批量取消已有记录。

## 本地证据

以下文件位于忽略提交的 build/，不包含 token：

- repair-backend-readonly-20261009.log：早期检查只有第一页，不能单独证明完整性。
- repair-backend-replay-20261009.log：38/38 检查、唯一诊断 POST、具体报错和后续标记核对。
- repair-attachment-red-20261009.log：旧提交缺少 attachment 的测试失败。
- remaining-full-tests-20261009.log、remaining-analyze-20261009.log：当前客户端自动检查。

后续先进行只读查询。本文不要求重新创建，不保存可用账号凭证。
