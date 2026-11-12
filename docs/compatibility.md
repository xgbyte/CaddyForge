# 兼容性与验证记录

核对日期：2026-11-12。以下固定版本通过 Go 官方模块代理查询精确版本与 go.mod，另查阅对应上游源码。它们是本项目的初始输入组合，不是对所有环境的兼容或安全保证。

| 组件 | 固定版本 | go.mod 声明 |
| --- | --- | --- |
| Caddy | v2.11.9 | Go 1.26.0 |
| xcaddy | v0.4.7 | Go 1.21，toolchain go1.23.0 |
| Coraza Caddy | v2.6.2 | Go 1.26.0，要求 Caddy v2.11.4 |
| Cloudflare DNS | v0.2.4 | Go 1.23.0，toolchain go1.24.2 |
| mholt Rate Limit（可选） | v0.1.0 | Go 1.21.0，要求 Caddy v2.8.0 |

Go 的依赖版本选择会合并这些要求，插件 go.mod 中较旧的 Caddy 要求不是“只支持该 Caddy 版本”的证据。单独看 go.mod 也不能证明 API、运行期或系统部署兼容。项目因此同时检查编译、实际嵌入版本、模块注册与配置加载。

Debian 13 trixie 的 `golang-go` 页面列出 1.24 系列默认依赖，不满足此组合的 Go 1.26.0 要求。请核对实际工具链，不要从发行版名称推断 Go 版本。GO_MIN_VERSION 只是预检门槛；传递依赖如果要求更高版本，GOTOOLCHAIN=local 会明确失败，维护者应调查并更新记录。

## 来源

- [Caddy 固定版本 go.mod](https://github.com/caddyserver/caddy/blob/v2.11.9/go.mod)
- [xcaddy 固定版本 go.mod](https://github.com/caddyserver/xcaddy/blob/v0.4.7/go.mod)
- [Coraza 固定版本 go.mod](https://github.com/corazawaf/coraza-caddy/blob/v2.6.2/go.mod)
- [Coraza 模块注册源码](https://github.com/corazawaf/coraza-caddy/blob/v2.6.2/coraza.go)
- [Cloudflare 固定版本 go.mod](https://github.com/caddy-dns/cloudflare/blob/v0.2.4/go.mod)
- [Rate Limit 固定版本 go.mod](https://github.com/mholt/caddy-ratelimit/blob/v0.1.0/go.mod)
- [Debian trixie golang-go](https://packages.debian.org/trixie/golang-go)
- [Caddy 构建文档](https://caddyserver.com/docs/build)
- [Go 工具链选择说明](https://go.dev/doc/toolchain)

## 已执行与待执行

2026-11-12 本地已执行：

| 平台与工具链 | 默认插件组合 | 加入 Rate Limit |
| --- | --- | --- |
| macOS / darwin arm64，Go 1.27.3 | 编译、实际嵌入版本/模块、配置加载、HTTP 通过 | 同左，限流 429 通过 |
| macOS / darwin arm64，Go 1.26.11 | 编译、实际嵌入版本/模块、配置加载、HTTP 通过 | 同左，限流 429 通过 |

HTTP 测试检查本地健康端点、正常 WAF 请求、XSS 测试请求返回 403；可选限流测试返回 429。测试临时调整监听端口和限流阈值，使用本机回环地址；不申请证书、不调用真实 DNS API。

- Bash 语法检查通过，使用本机 Bash 3.2 执行 15 项基础/隔离事务测试通过。
- ShellCheck v0.11.0 检查全部 Bash 脚本与测试通过。
- actionlint v1.7.10 检查 GitHub Actions 工作流通过。
- 部署事务测试使用临时目录、原子重命名与服务替身，覆盖成功、预检失败、重启失败、健康失败、首次激活失败、TERM 中断、恢复失败报告。它们不等于 systemd 集成测试。

**尚未执行**：Linux amd64/arm64 原生构建矩阵、GitHub 托管 CI、Debian 13 真实 systemd 安装/升级/回滚、重启后验收、真实 Cloudflare DNS-01/证书续期、生产流量与第三方安全审计。对应工作流与隔离 VM 验收步骤已经提供。不能据本地结果宣称这些范围兼容或已通过。

## 版本更新流程

1. 查询显式 tag 的 go.mod、变更记录及维护状态，避免使用 latest/master。
2. 更新 versions.conf 与 plugins.conf；为可选插件也保留精确版本。
3. 用全新目录构建默认和可选组合，运行 verify.sh 与 HTTP 冒烟测试。
4. 检查 build-info.txt 中的真实依赖，拒绝无意升级 Caddy/插件的组合。
5. 在 Debian 13 VM 执行安装、升级、回滚、失败恢复测试，记录架构与 Go 版本。
6. 审查第三方许可证、已知漏洞与运行配置后再发布。项目提供标签触发的自动发布任务，详见 README；自动构建与发布不替代这些审查。
