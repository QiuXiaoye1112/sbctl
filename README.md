# sbctl

`sbctl` 是面向 Linux 的 sing-box 终端管理器。交互思路参考 `xrayctl`，但配置、服务和协议实现均针对 sing-box。

当前版本：`0.4.2`

## 支持环境

- systemd Linux：Debian、Ubuntu、RHEL 系、Arch、openSUSE 等
- Alpine Linux / OpenRC
- sing-box `1.12.0+`

### 与 xrayctl 共存

sbctl 可以与 xrayctl/Xray 同时安装。两者使用独立的命令、服务、配置、metadata、备份和 Certbot 环境。创建或修改 sing-box 入站时，sbctl 会读取现有 Xray 入站端口；创建 Hysteria2 端口跳跃范围时，也会拒绝覆盖任何 Xray 入站端口。

BBR 是主机全局开关，sbctl 与 xrayctl 都读取内核当前状态，也都可以开启或关闭。关闭时会清理两者的已知持久化文件，避免重启后被另一份配置重新开启；第三方 sysctl 配置不会被修改。两套证书环境保持隔离，但 Certbot 操作会通过 `/run/lock/xrayctl-sbctl-certbot.lock` 串行执行，避免同时操作 80 端口/nginx；同一个域名仍建议只交给一个工具自动签发和续期，避免重复申请。

## 主要能力

- AnyTLS、VLESS、Hysteria2、Trojan、SOCKS5、HTTP 入站
- REALITY 与证书 TLS
- 用户新增、重命名、删除和凭据轮换
- SOCKS5 / HTTP / 本地地址出站与入站绑定
- 配置候选校验、事务应用和失败回滚
- Let's Encrypt 域名证书、公网 IP 证书、证书导入
- Cloudflare DNS 自动验证/续期（账号邮箱 + Global API Key）
- HTTP 自动验证/续期与 DNS 手动 TXT 验证
- 独立 Certbot 环境和多 Certbot 账户选择
- 托管证书 metadata、证书/私钥匹配校验、原子替换和安全删除
- config / metadata / certs 整体备份与事务恢复
- systemd / OpenRC 服务管理和运行时硬化
- BBR 能力检测和受限容器保护
- 三级卸载：仅核心、完全卸载、彻底删除
- 系统诊断、残留扫描和资源归属保护

## 安装

### systemd Linux

```bash
curl -fsSL https://github.com/QiuXiaoye1112/sbctl/raw/refs/heads/main/install.sh | sudo bash
```

指定 sing-box 版本：

```bash
curl -fsSL https://github.com/QiuXiaoye1112/sbctl/raw/refs/heads/main/install.sh | sudo bash -s -- 1.13.16
```

### Alpine Linux

```sh
wget -qO- https://github.com/QiuXiaoye1112/sbctl/raw/refs/heads/main/alpine/install.sh | sh
```

安装器只下载构建好的单文件 `dist/sbctl`，完成内容识别与 Bash 语法校验后才原子安装到 `/usr/local/sbin/sbctl`。服务器运行时不再依赖 `/usr/local/lib/sbctl/*.sh`，因此不会出现入口与模块版本不一致。

安装完成后：

```bash
sbctl
```

## 常用命令

```bash
sbctl status
sbctl update
sbctl restart
sbctl logs 100
sbctl diagnose

sbctl inbound list
sbctl inbound add
sbctl inbound show TAG
sbctl inbound rename OLD NEW
sbctl inbound modify TAG
sbctl inbound security TAG
sbctl inbound delete TAG

sbctl outbound list
sbctl outbound add
sbctl outbound assign TAG OUTBOUND
sbctl outbound delete OUTBOUND

sbctl client list TAG
sbctl client add TAG
sbctl client rename TAG OLD NEW
sbctl client rotate TAG USER
sbctl client delete TAG USER

sbctl link TAG
sbctl config check

sbctl cert list
sbctl cert issue example.com you@example.com
sbctl cert cloudflare
sbctl cert import example.com /path/fullchain.pem /path/privkey.pem
sbctl cert renew example.com
sbctl cert renew-auto
sbctl cert delete example.com

sbctl backup
sbctl restore /path/to/backup.tar.gz

sbctl uninstall
sbctl uninstall --purge
sbctl uninstall --erase
```

## v0.4 可靠性与成熟度设计

### 安装与网络

- APT 使用连接超时、重试和总时限；`apt-get update` 失败时会尝试现有索引，不会无限卡在 `Waiting for headers`。
- 仅在主机确实存在 IPv4 路由时给 APT 自动加 `Acquire::ForceIPv4=true`，不会破坏 IPv6-only 主机。
- apk、dnf、yum、pacman、zypper 和官方 sing-box 安装流程均有执行上限。
- 公网 IPv4 探测依次使用 ipify、AWS CheckIP、Cloudflare Trace；IPv6 使用 ipify 和 Cloudflare Trace fallback。
- bootstrap 下载带连接超时、总时限和重试，并固定到同一个 Git commit。

### 配置与 metadata 事务

所有托管配置先生成候选文件并执行：

```bash
sing-box check -c <candidate>
```

涉及入站状态的操作同时生成 config 和 metadata 候选；两者作为一个事务提交。若文件替换失败或原本运行中的 sing-box 重启失败，会同时恢复旧 config 和旧 metadata。

事务覆盖：

- 新增入站
- 修改监听地址/端口
- 修改 TLS / REALITY
- 入站重命名
- 入站删除

删除入站时会清理 route 中所有对该 tag 的引用；共享规则会只移除被删 tag，仍有其他 inbound 的规则继续保留。

### 服务硬化

systemd 由 sbctl 创建的 unit 使用 root 运行以保持 sing-box 网络能力和现有配置兼容，但增加运行时隔离：

- `UMask=0077`
- `NoNewPrivileges=true`
- `PrivateTmp=true`
- `ProtectSystem=strict`
- `ProtectHome=read-only`
- `ProtectKernelTunables=true`
- `ProtectKernelModules=true`
- `ProtectKernelLogs=true`
- `ProtectControlGroups=true`
- `ProtectHostname=true`
- `RestrictSUIDSGID=true`
- `LockPersonality=true`
- `RestrictRealtime=true`
- 仅放行 sing-box 数据目录写入

OpenRC 使用 `supervise-daemon`、自动 respawn 和 `umask 077`，避免旧的简单后台进程模式。

### Certbot 多账户

sbctl 的 Certbot 数据独立保存于 `/var/lib/sbctl/letsencrypt/`。当存在多个 Let's Encrypt / Certbot account 时：

1. 已有证书续签/重签优先使用其 lineage 中记录的 account；
2. 只有一个 account 时自动使用；
3. 多个 account 且交互运行时要求选择；
4. 非交互模式可指定：

```bash
SBCTL_CERTBOT_ACCOUNT=ACCOUNT_ID sbctl cert issue example.com you@example.com
```

不会因为 Certbot 存在多个账户就把失败误判成 80 端口问题。独立环境同时检查 Certbot 主程序和 `certbot-nginx` 插件完整性，插件损坏或缺失时会修复/明确报错。

### BBR 安全边界

- 先确认内核实际提供 BBR 和 `/proc` 参数可写。
- NAT/LXC/OpenVZ 等受限环境无法写 sysctl 时仅提示，不让整个菜单异常退出。
- sbctl 写入的 BBR 配置带 `# managed by sbctl` 标记并登记 metadata。
- 如果 `/etc/sysctl.d/99-sbctl-bbr.conf` 已存在但不属于 sbctl，启用 BBR 会拒绝覆盖。
- `sbctl uninstall --erase` 只有确认该配置确实属于 sbctl 时才会回退运行时拥塞控制并删除文件；不会因为系统当前恰好使用 BBR 就修改其他工具或管理员配置的状态。

## TLS 证书

### 域名签发

```bash
sbctl cert issue example.com you@example.com
```

支持三种验证：

- **Cloudflare DNS**：自动验证、自动续期，无需开放 80/TCP。
- **HTTP**：自动续期，需要公网 80/TCP 可达；可识别 nginx、sing-box 和其他 80 端口占用情况。
- **DNS 手动 TXT**：通用 DNS 服务商可用，但不会登记为自动续期。

### Cloudflare DNS

```bash
sbctl cert cloudflare
```

使用 Certbot `certbot-dns-cloudflare` 标准 Global API Key 格式：

```ini
dns_cloudflare_email = you@example.com
dns_cloudflare_api_key = YOUR_GLOBAL_API_KEY
```

默认路径：

```text
/var/lib/sbctl/letsencrypt/cloudflare.ini
```

文件权限固定为 `600`。Global API Key 不写入 metadata，也不进入 sbctl 备份。删除凭据时若有证书依赖它续期，会先明确警告。

### 公网 IP 证书

公网 IP 使用 Certbot `5.4+` short-lived profile + HTTP 验证，需要 80/TCP 可达。

### Certbot 默认路径

| 内容 | 默认路径 |
| --- | --- |
| Certbot venv | `/opt/sbctl/certbot/` |
| Let's Encrypt account / lineage | `/var/lib/sbctl/letsencrypt/` |
| Cloudflare 凭据 | `/var/lib/sbctl/letsencrypt/cloudflare.ini` |
| work | `/var/lib/sbctl/certbot-work/` |
| logs | `/var/log/sbctl/certbot/` |

### 证书安全

- 导入/同步前校验证书可解析、未过期、私钥可解析且公私钥匹配。
- 证书替换使用临时文件与回滚，避免只换 cert 或只换 key。
- 被 TLS 入站引用的证书禁止直接删除。
- 删除 sbctl 签发的证书会同步删除对应 sbctl Certbot lineage。
- 旧版证书会登记为 `legacy`，不会擅自假设可以自动续期。
- 备份保存托管证书副本，但不保存 Certbot account/lineage 或 Cloudflare Key；恢复后缺失续期数据会明确告警。

## 备份与恢复

```bash
sbctl backup
sbctl restore /path/to/backup.tar.gz
```

恢复前会检查 tar.gz 和路径穿越，再用 sing-box 校验备份配置。恢复 config、metadata、certs 后若服务无法恢复，会整体回滚三者，而不是只恢复 config。

## 卸载

### 仅卸载核心

```bash
sbctl uninstall
```

卸载 sing-box 核心和 sbctl 管理的服务定义，保留配置、证书、sbctl、Certbot/Cloudflare 续期数据、续期任务和备份，可直接重新运行 `sbctl install`。

### 完全卸载，保留备份

```bash
sbctl uninstall --purge
```

先创建最终备份；如果最终备份失败则取消 purge。之后删除 sing-box、sbctl、配置、metadata、托管证书、独立 Certbot/Cloudflare 数据和续期任务，保留 `/var/backups/sbctl/`。

### 彻底删除

```bash
sbctl uninstall --erase
```

必须输入 `DELETE`。除 purge 内容外还删除 sbctl 自己的备份和带所有权标记的 BBR 配置，并执行残留扫描。

目录清理会校验危险路径和 metadata 资源归属，不删除系统 Certbot、其他网站的 `/etc/letsencrypt` 或无关系统目录。

## 诊断

```bash
sbctl diagnose
```

会检查：

- 系统、内核、虚拟化类型
- systemd / OpenRC
- sing-box 版本、运行/自启状态
- 服务硬化状态
- 公网 IPv4 / IPv6
- BBR
- metadata schema
- 托管证书与自动续期数量
- Certbot account 数量
- Cloudflare DNS 凭据状态
- 入站/出站数量
- 当前 sing-box 配置有效性

## 项目结构

```text
sbctl.sh                         开发入口、路径初始化与集中模块加载
src/core.sh                      日志、交互、validator、临时文件与表格输出
src/platform.sh                  平台探测、包管理、网络和 systemd/OpenRC 抽象
src/state.sh                     config/meta、migration、事务、备份与恢复
src/security.sh                  TLS/REALITY 构造与密钥读取
src/certificate/                 证书生命周期、Certbot 与 Cloudflare
src/protocols.sh                 普通协议 capability 与 JSON builder
src/hysteria2.sh                 Hysteria2 builder、端口跳跃与 nft/iptables
src/inbound.sh                   入站生命周期
src/inbound/clients.sh           入站用户 CRUD
src/outbound.sh                  出站与路由绑定
src/share.sh                     分享 URI / 客户端 JSON（只读）
src/service.sh                   sing-box 安装、服务、BBR 与诊断
src/uninstall.sh                 三级卸载与资源归属保护
src/menu.sh                      菜单、CLI dispatch 与 help
scripts/build.sh                 生成单文件 dist/sbctl
scripts/lint.sh                  语法、ShellCheck 与 diff 校验
scripts/test.sh                  可移植的单元/集成/冒烟安全网
dist/sbctl                       服务器实际安装的单文件发行版
install.sh                       通用 Linux bootstrap
alpine/install.sh                Alpine bootstrap
architecture-audit.md            重构前架构、重复函数与写入点审计
```

模块依赖集中声明在 `sbctl.sh` 与 `scripts/build.sh`；`src/` 内模块不会自行 `source` 其他模块。正式函数名在整个 `src/` 中只能定义一次，architecture test 会在新增重复实现时直接失败。

### 构建发行版

```bash
bash scripts/build.sh
bash -n dist/sbctl
SBCTL_TESTING=1 bash dist/sbctl version
```

构建顺序固定，`dist/sbctl` 完全来自当前工作树中的入口与领域源码。CI 会重新构建并要求生成结果与仓库中的发行版一致。

## 测试

GitHub Actions 会：

- 对主脚本、模块、安装器和测试执行 Bash/POSIX shell 语法检查；
- 运行 ShellCheck 和 `git diff --check`；
- 安装当前稳定 sing-box，以真实 `sing-box check` 执行协议回归；
- 测试证书、Cloudflare、备份/恢复、路由、事务回滚、Certbot 多账户、卸载和 BBR 安全边界；
- 在 Alpine 容器再次运行生命周期/Cloudflare/成熟度测试，覆盖 musl/OpenRC 兼容面。

本地常用：

```bash
bash scripts/build.sh
bash scripts/lint.sh
bash scripts/test.sh

# Linux 上的完整兼容回归
SBCTL_TESTING=1 TERM=xterm bash tests/smoke-current.sh
SBCTL_TESTING=1 TERM=xterm bash tests/lifecycle.sh
SBCTL_TESTING=1 TERM=xterm bash tests/cloudflare.sh
SBCTL_TESTING=1 TERM=xterm bash tests/maturity.sh
```
