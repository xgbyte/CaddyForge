# 迁移、隔离验收与恢复

## 从 APT Caddy 迁移

这是需要维护窗口的独立操作，安装脚本不会执行。先记录 `systemctl cat caddy`、运行用户、环境变量、监听端口、证书存储位置与所有 import 文件。完整备份 `/etc/caddy`、数据目录和服务定义；不要只备份主 Caddyfile。确认备份可恢复。

CaddyForge 使用独立的配置与数据目录，不自动复用 `/var/lib/caddy`。如果需要延续原证书，停服后按实际存储布局将备份数据复制到 `/var/lib/caddyforge/caddy`，核对新的 XDG_DATA_HOME 布局、存储模块配置和 caddyforge 用户权限。不要盲目套用路径或对原数据递归改属主。相对路径按 `/etc/caddyforge` 解析；将 import、证书与 WAF 文件一并迁移并检查权限。

手动停止并禁用旧服务后，再执行首次安装。不要 purge 软件包或删除旧数据来“完成迁移”；先验证域名、证书、反代、WAF、DNS 权限及重启后的行为。旧服务的回退和新服务的端口占用要放在同一份维护计划中。服务能力仅授予绑定低端口，不以 root 身份运行 Caddy。

## 配置变更

环境文件由 systemd 读取，不是 shell 脚本，服务用户不需要直接读取该文件。配置建议 root:caddyforge 0640，配置目录 root:caddyforge 0750，数据目录 caddyforge:caddyforge 0750。更改环境变量后需重启服务；单纯 reload 不会重新读取 EnvironmentFile。

每次配置变化也要验证健康端点；部署检查 curl 2xx/3xx 以及 MainPID 对应的可执行文件，不验证上游业务、WAF 全部规则或证书续期。必要时使用能覆盖应用路径的健康 URL，避免把与 Caddy 无关的服务当成健康端点。默认健康检查使用本机直连，忽略代理环境变量。

## 隔离 Debian 13 VM 验收清单

尚未执行的真实部署测试应在一次性 Debian 13 systemd VM 内做，不能用普通无 systemd 容器代替：

1. 建立 VM 快照；为 amd64/arm64 分别准备原生 Linux 产物。
2. 首次安装，检查用户、目录权限、当前链接、服务 MainPID 和 /healthz，再启用开机启动并重启 VM。
3. 换用另一份有效产物升级，确认 current/previous；执行回滚，再次回滚以切回。
4. 破坏校验和、删除插件、放入错误架构，确认在切换前拒绝。
5. 让配置验证失败，确认旧链接与旧进程保留。
6. 使用不可达健康 URL触发升级失败，确认旧链接与旧服务恢复；再模拟旧服务恢复失败，确认有明确错误。
7. 并发执行两个部署，确认第二个被互斥锁拒绝；在切换过程中发 TERM，检查恢复。
8. 测试 Cloudflare DNS-01 与真实域名、续期和反代；使用测试凭据与 ACME staging，评估规则误报后再上生产。

## 异常恢复

`journalctl -u caddyforge.service -n 100 --no-pager` 查看服务日志。记录中应能区分新版失败与恢复旧版失败；脚本返回非零不会静默声称成功。

正常旧版可加载当前配置时使用 rollback.sh。若配置已经不兼容，先从备份恢复配置与环境，再验证并重启。首次安装失败会停止新服务并撤销 current；新建用户、目录、未启用的服务文件与暂存好的版本可能保留，检查后可重试安装。

EXIT/INT/TERM 可以触发自动恢复，SIGKILL、系统崩溃或断电不能依赖 shell trap。不要在这种状态下并发启动部署。先检查 current、previous 及服务运行路径；选定 releases 中经过验证的目录，以临时符号链接配合 `mv -Tf` 恢复 current，随后 `systemctl restart caddyforge.service` 并手动检查健康。原子重命名避免半个链接，但不是断电事务或磁盘持久性保证。

版本目录不自动清理。只在确认不再运行、不是 current/previous 且有备份后手动清理旧版本。回滚不降级证书数据库或外部存储格式；此类变化需要独立恢复方案。
