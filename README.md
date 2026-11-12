# CaddyForge

Build, verify, deploy, upgrade and roll back custom Caddy binaries with xcaddy.

面向 **Debian 13 + systemd** 的 Bash 脚手架。默认包含 Coraza WAF 与 Cloudflare DNS，可选 mholt Rate Limit。构建完全独立于部署：编译不会写入 `/opt`、`/etc`，不会操作服务或覆盖运行中的二进制。

当前是可审阅的初始版本。已执行的检查与尚未验证的范围见 [兼容性记录](docs/compatibility.md)。CaddyForge 不是 Caddy 官方项目。

## 目录

```text
config/       精确版本、插件清单、systemd 单元、环境文件示例
scripts/      bootstrap / build / verify / install / upgrade / rollback
examples/     本地健康检查、Coraza CRS、Cloudflare、可选限流配置
tests/        Bash 基础测试、隔离部署事务测试、本地 HTTP 冒烟测试
docs/         兼容性证据、迁移与故障恢复说明
.github/      GitHub Actions 与依赖更新配置
```

## 1. 准备构建环境

需要 Bash、Go、git、curl、tar、awk，以及 `sha256sum` 或 `shasum`。部署脚本仅支持 Debian 13；构建与基础测试也可以在 macOS 本地执行，生成的 macOS 二进制不能部署到 Linux。

先查看 `config/versions.conf`。Go 最低版本来自被固定依赖的要求，不代表所有未来依赖组合都兼容。Debian 的 `golang-go` 包版本未必足够；按 [Go 官方安装说明](https://go.dev/doc/install) 安装合适的工具链并核对下载校验和。脚本不自动安装或替换系统 Go，也不允许 Go 隐式下载另一套工具链。

```bash
go version
./scripts/bootstrap.sh --install-xcaddy
./scripts/bootstrap.sh
```

xcaddy 安装到仓库内 `.tools/`，无需 root。首次构建需要网络访问 Go 模块服务；保留默认 Go 校验数据库验证，不设置 `GOSUMDB=off`。

## 2. 选择插件并构建

`config/plugins.conf` 是四列数据：`enabled module-path exact-version registered-module`。只接受显式版本，不执行清单中的 shell 内容。`coraza_waf` 指令对应的模块名为 `http.handlers.waf`。

```bash
./scripts/build.sh dist/my-first-build
./scripts/verify.sh dist/my-first-build
python3 tests/http_smoke.py dist/my-first-build
```

启用可选限流插件：将清单对应行的 `0` 改成 `1`，或者使用单独清单：

```bash
sed 's/^0 github.com\/mholt\//1 github.com\/mholt\//' config/plugins.conf > /tmp/caddyforge-all.conf
./scripts/build.sh dist/with-ratelimit /tmp/caddyforge-all.conf
```

每次构建必须使用新的产物目录。构建不支持交叉编译：二进制必须在本机执行检查。CI 使用 Linux amd64/arm64 原生 runner。

产物包含 `caddy`、输入清单、Go 构建信息、模块列表及 `SHA256SUMS`。脚本检查实际 Caddy 版本、插件注册模块和实际嵌入依赖版本，发现 Go 最小版本选择造成的版本变化会失败；不会以“构建成功”代替版本检查。完整传递依赖记录在 `build-info.txt`，不承诺跨工具链字节级复现。

验证 Caddyfile 会初始化模块；真实 DNS 配置可能访问外部服务。默认构建只验证本地基础、Coraza 与启用时的限流示例，不发起真实 Cloudflare/ACME 测试。Cloudflare 示例必须替换域名并提供令牌后另行验证。

## 3. 首次部署（只在目标 Debian 13 上手动执行）

将**可信来源**的完整 Linux 产物和此仓库传到目标主机，先审阅脚本。SHA256 仅验证文件完整性，不能证明来源；不要对陌生产物执行部署，因为验证本身会执行二进制。

```bash
sudo ./scripts/install.sh /absolute/path/to/artifact
sudo systemctl enable caddyforge.service
sudo systemctl status caddyforge.service
```

安装会创建独立 `caddyforge` 用户、服务和目录：

| 路径 | 用途 |
| --- | --- |
| `/opt/caddyforge/releases/<manifest-sha256>/` | 版本目录；二进制安装后不原地覆盖 |
| `/opt/caddyforge/current` | 当前版本符号链接，原子替换 |
| `/opt/caddyforge/previous` | 上次成功运行的版本 |
| `/etc/caddyforge/Caddyfile` | 配置；仅首次缺失时放入安全示例 |
| `/etc/caddyforge/caddy.env` | root:root 0600 的 systemd 环境文件 |
| `/var/lib/caddyforge` | caddyforge 用户的证书和运行数据 |

首次启动只监听 `127.0.0.1:8080`，提供 `/healthz`。安装成功后启动服务，但**开机启用需单独执行**。如果已有 `caddy.service` 或 `caddy-api.service` 正在运行或已启用，安装会拒绝继续。它不卸载 APT 包，不停止现有 Caddy，不迁移已有证书。见 [迁移与恢复](docs/operations.md)。

生产配置由你审阅后放入 `/etc/caddyforge/Caddyfile`，保留本地健康检查监听或为每次部署传入自己的健康 URL。将 Cloudflare 令牌写入 `/etc/caddyforge/caddy.env`，使用 EnvironmentFile 语法，不写 `export`。不要提交真实令牌。Cloudflare 权限应限定到所需 DNS 区域，参考 [插件说明](https://github.com/caddy-dns/cloudflare)。

## 4. 升级和回滚

先以普通用户独立构建新产物，再在服务器部署。部署端不需要 Go 或 xcaddy。

```bash
sudo ./scripts/upgrade.sh /absolute/path/to/new-artifact
sudo ./scripts/rollback.sh
# 自定义健康检查（升级和回滚使用同一个 URL）
sudo ./scripts/upgrade.sh /absolute/path/to/new-artifact http://127.0.0.1:8080/healthz
sudo ./scripts/rollback.sh http://127.0.0.1:8080/healthz
```

部署过程使用互斥锁，复制到新版本目录，检查校验和及模块，以服务用户和环境预检当前配置，然后切换链接、重启并检查进程二进制及 HTTP 健康端点。失败时恢复原链接并重启旧版；恢复失败会明确报错。成功后才更新 `previous`。回滚也先验证旧版能否加载**当前配置**，成功后可以再次回滚以切回新版。

升级涉及服务重启，存在短暂中断，不承诺零停机。回滚只切换二进制，不还原配置、令牌、证书或外部状态。服务文件及 drop-in 有差异时拒绝自动部署，以免错误地假定运行环境。不要使用 `caddy upgrade` 或 `caddy add-package` 改写版本目录。

## 测试和 CI

```bash
bash tests/run.sh
shellcheck -x scripts/*.sh tests/*.sh
python3 tests/http_smoke.py dist/my-first-build
```

基础测试使用临时目录与服务替身，覆盖输入拒绝、文件篡改、版本漂移、模块缺失、成功切换、配置失败、启动失败、健康检查失败、首次安装失败、信号中断及恢复失败报告。不会操作真实 systemd。

GitHub Actions 在 PR/push/手动触发时检查 Bash 和 ShellCheck，在 Go 1.26/1.27 与 Linux amd64/arm64 上构建默认、限流组合并做本地 HTTP 检查，然后上传 CI 产物。工作流没有部署、推送和创建 Release 的权限。GitHub Actions 的执行结果只有推送后才会产生，当前本地结果见兼容性文档。

## 维护与贡献

修改版本时一起更新输入清单和兼容性记录，重新执行两种组合的构建及 HTTP 测试，再在隔离 Debian 13 VM 验证部署。第三方插件各自有许可证及维护状态；集成并不代表 Caddy 官方支持。安全问题处理见 [SECURITY.md](SECURITY.md)。

CaddyForge 自有脚手架采用 [MIT License](LICENSE)。构建出的 Caddy、插件和传递依赖保留各自许可证；MIT 不会替代它们的许可证，发布二进制前应整理对应版本的许可与声明。
