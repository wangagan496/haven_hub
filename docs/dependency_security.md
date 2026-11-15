# 服务端依赖安全关卡

日期：2026-10-29。范围：`server/package-lock.json`锁定的npm依赖，包括开发依赖和可选平台依赖；本次验证环境为Windows x64、Node 24.16.0。扫描结果代表当时漏洞库已知的问题，不是整站安全认证。

## 已提供的入口

在`server`目录执行`npm run audit:security`，调用npm原生审计命令，阈值为high，最多20秒请求超时、不自动重试。高危或严重问题返回非零，漏洞库不可用、锁文件缺失或扫描出错也返回非零；不因离线把结果改成通过。中低危记录仍展示，但不会单独触发该阈值失败，没有配置忽略清单。

`tool/check_project.ps1`在依赖安装后、构建前运行相同命令；`-SkipRestore`只跳过安装，不跳过扫描。使用`-Scope flutter`只检查Flutter，该模式不能作为服务端发布检查的替代。完整检查命令：

```powershell
pwsh -File tool/check_project.ps1
```

现有GitHub工作流调用同一入口，并配置保留检查日志7天；上传范围仅为检查目录下的日志文件，不含隔离联调的数据库。尚未推送或执行远程工作流，本地入口通过不能替代远程首次运行与分支保护配置。检查实际提交到的npm registry的已知公告，企业私有镜像需要验证其审计服务可用；不要通过关闭审计或更换为没有审计能力的源来处理失败。

## 本轮发现与修复

原锁文件实际扫描结果为3个高危依赖条目、1个中危依赖条目；这是npm按依赖包归并的数量，不是CVE数量：

| 依赖 | 原版本 | 修复后锁定版本 | 公告与影响 |
| --- | --- | --- | --- |
| body-parser | 2.3.0 | 2.4.0 | [GHSA-27r3-jxmh-p828](https://github.com/advisories/GHSA-27r3-jxmh-p828)，压缩请求结束后的附加字节可能导致拒绝服务 |
| multer | 2.4.0 | 2.5.0 | [GHSA-q7qp-rjg7-q26m](https://github.com/advisories/GHSA-q7qp-rjg7-q26m)，请求中断时异步文件筛选相关拒绝服务；当前应用没有自定义异步fileFilter，不声称复现了该利用链 |
| sharp | 0.34.5 | 0.35.5 | [GHSA-f88m-g3jw-g9cj](https://github.com/advisories/GHSA-f88m-g3jw-g9cj)、[GHSA-rgj7-g3m4-5g8c](https://github.com/advisories/GHSA-rgj7-g3m4-5g8c)、[GHSA-wq5f-xc86-pv6w](https://github.com/advisories/GHSA-wq5f-xc86-pv6w)，所带原生图片库的已知问题 |
| qs | 6.16.0 | 6.17.1 | [GHSA-6pq8-jhm2-2vcw](https://github.com/advisories/GHSA-6pq8-jhm2-2vcw)，特定stringify输入导致拒绝服务；未认定现有业务路径可直接构造该调用 |

显式提高`multer`和`sharp`的最低版本，定向更新两者及`body-parser`、`qs`并更新锁文件；没有执行`npm audit fix --force`。锁版本差异共30个包，其中26个为sharp本体之外的平台适配/原生库包，另外4个是表中依赖；Express保持5.3.0，未引入新的业务依赖。sharp原生运行环境要求Node至少20.9.0，符合项目固定版本；在新的隔离目录按锁文件执行`npm ci`后，原生图片处理实跑成功，Windows使用libvips 8.18.7，其他OS构建未在本轮验收。

复扫报告没有已知漏洞。应用层另修正JSON解析边界：正常压缩JSON继续可用，畸形压缩流返回400，不支持的编码返回415，解压后超过128KiB仍返回413；响应只使用固定提示，不把解压库原始错误或请求正文回显给客户端，其他业务内部异常仍走原500处理。

## 回归与证据

- 新增真实HTTP测试覆盖压缩JSON更新、无效压缩流及末尾附加字节、解压后的大小限制、不支持编码、JPEG/PNG/WebP方向归一化及元数据清除、私图权限、超额文件、多文件和中断上传。
- 旧联调PNG样本的IDAT块CRC实际不匹配，新版原生库拒绝解码；通过Node标准库CRC计算独立确认后，更换为全部块CRC均通过的1x1 PNG，并为旧损坏样本保留服务端拒绝测试。没有降低图片解码检查或跳过联调。
- 在隔离目录使用旧锁文件运行当前统一入口，实际在`server-audit`失败且未进入构建；再对当前锁文件使用不可用的本地registry，确认扫描失败同样阻止后续步骤。没有改动日常数据库或远程CI。
- 本地证据目录：`C:\Users\23203\AppData\Local\Temp\haven-enterprise-dependency-audit-20261029`，包含旧锁文件与初始扫描、两种阻断演练、锁版本差异、干净安装与完整检查日志；PNG独立检查脚本为同级临时目录的`haven-png-probe-20261029.ps1`及`.mjs`。
- 最终统一入口`pwsh -File tool/check_project.ps1 -SkipRestore`在`final-checks-2`完整通过：后端548项、Flutter601项和显式启用的真实联调1项，共1150项零失败；扫描0项已知漏洞，构建、静态检查和网页语法通过。

后续更改依赖时定向选择修复版本，再执行审计、构建和真实图片/业务联调；审计失败时先保留公告与锁版本证据，不自动放宽阈值。扫描没有覆盖Flutter pub/Git依赖、HarmonyOS系统库、应用自身漏洞或所有原生构建的完整软件组成；客户端安全存储、独立安全测试、真实部署和G1其余验收仍保留。
