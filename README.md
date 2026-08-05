# sbctl

`sbctl` 是一个 Linux sing-box 终端管理器，交互方式参考 `xrayctl`，底层使用 sing-box 配置和命令。

当前版本：`0.3.1`

## 支持环境

- systemd Linux：Debian、Ubuntu、RHEL 系、Arch、openSUSE 等
- Alpine Linux / OpenRC
- sing-box `1.12.0+`

## 功能

- AnyTLS、VLESS、Hysteria2、Trojan、SOCKS5、HTTP 入站
- REALITY 与证书 TLS
- 用户新增、删除、重置凭据
- 配置校验与失败回滚
- TLS 证书导入、Let's Encrypt 域名证书和公网 IP 证书签发
- Cloudflare DNS 自动验证/自动续期（邮箱 + Global API Key）
- HTTP 验证证书自动续期；同时保留 DNS 手动 TXT 验证
- 独立 Certbot 环境，不复用或污染系统 Certbot
- 托管证书元数据、证书/私钥匹配校验、原子替换与安全删除
- config / meta / certs 整体备份恢复
- 三级卸载：仅核心、完全卸载、彻底删除
- systemd / OpenRC 服务管理
- VLESS、Trojan、Hysteria2 与 AnyTLS(TLS) 分享链接
- AnyTLS + REALITY 客户端 outbound JSON

## 安装

### systemd Linux

```bash
curl -fsSL https://raw.githubusercontent.com/QiuXiaoye1112/sbctl/main/install.sh | sudo bash
```

指定 sing-box 版本：

```bash
curl -fsSL https://raw.githubusercontent.com/QiuXiaoye1112/sbctl/main/install.sh | sudo bash -s -- 1.13.12
```

### Alpine Linux

```sh
wget -qO- https://raw.githubusercontent.com/QiuXiaoye1112/sbctl/main/alpine/install.sh | sh
```

安装完成后运行：

```bash
sbctl
```

## 常用命令

```bash
sbctl status
sbctl update
sbctl restart
sbctl logs 100

sbctl inbound list
sbctl inbound add
sbctl inbound show TAG
sbctl inbound modify TAG
sbctl inbound delete TAG

sbctl client list TAG
sbctl client add TAG
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

完整帮助：

```bash
sbctl help
```

## TLS 证书

### Let's Encrypt 域名证书

执行：

```bash
sbctl cert issue example.com you@example.com
```

域名证书提供三种验证方式：

- **Cloudflare DNS 自动验证**：使用 Cloudflare 账号邮箱 + Global API Key；无需开放 80 端口，支持自动续期。
- **HTTP 验证**：需要公网 `80/TCP` 可达；签发成功后登记为可自动续期证书。
- **DNS 手动验证**：按 Certbot 提示手动添加 TXT 记录；不会登记为自动续期证书。

### Cloudflare DNS 自动验证

先运行：

```bash
sbctl cert cloudflare
```

配置 Cloudflare 账号邮箱和 **Global API Key**。凭据使用 Certbot `certbot-dns-cloudflare` 插件标准格式：

```ini
dns_cloudflare_email = you@example.com
dns_cloudflare_api_key = YOUR_GLOBAL_API_KEY
```

默认保存到：

```text
/var/lib/sbctl/letsencrypt/cloudflare.ini
```

文件权限固定为 `600`。Cloudflare DNS 证书在 metadata 中记录为 `dns-cloudflare`，会被 `sbctl cert renew-auto` 和 systemd/OpenRC 自动续期任务处理；如果凭据被删除，对应证书会明确显示为续期阻塞，而不会退回 HTTP 或手动验证。

首次选择 Cloudflare DNS 签发时，如果尚未配置凭据，`sbctl` 也会直接进入凭据配置流程。`certbot-dns-cloudflare` 插件只在 Cloudflare 验证/续期需要时安装到 sbctl 自己的 Certbot venv。

### 公网 IP 证书

`sbctl` 使用 Certbot `5.4+` 的 short-lived profile 和 HTTP 验证签发公网 IP 证书，因此同样需要 `80/TCP` 可达。

### 独立 Certbot 环境

证书签发使用 sbctl 自己的 Certbot 环境：

| 内容 | 默认路径 |
| --- | --- |
| Certbot venv | `/opt/sbctl/certbot/` |
| Let's Encrypt 配置/lineage | `/var/lib/sbctl/letsencrypt/` |
| Cloudflare 凭据 | `/var/lib/sbctl/letsencrypt/cloudflare.ini` |
| Certbot work | `/var/lib/sbctl/certbot-work/` |
| Certbot logs | `/var/log/sbctl/certbot/` |

这样不会复用或删除系统已有 Certbot 的其他网站证书。

### 证书安全

- 导入或同步证书前会校验证书格式、有效期、私钥格式以及公私钥是否匹配。
- 更新托管证书使用临时文件和回滚机制，避免只替换证书或只替换私钥。
- 正被 TLS 入站引用的托管证书不能直接删除。
- 删除 sbctl 签发的 Let's Encrypt 证书时，会同时删除对应的 sbctl Certbot lineage。
- Cloudflare Global API Key 不写入 metadata，只保存于权限为 `600` 的凭据文件。
- 删除 Cloudflare 凭据前，如果存在依赖它自动续期的证书，会明确警告。
- 旧版 `/etc/sing-box/certs/*.crt + *.key` 会自动登记到 metadata，但默认不会假定其可自动续期。
- 备份包含托管证书副本，但不包含 Certbot 账户/lineage 或 Cloudflare 凭据；恢复后若缺少续期数据，会明确提示重新签发。

## 卸载

### 1. 仅卸载 sing-box 核心

```bash
sbctl uninstall
```

删除 sing-box 核心和服务定义，保留：

- 配置
- 托管证书
- sbctl 命令与模块
- Cloudflare/Certbot 续期数据
- 自动续期任务
- 备份

之后可直接运行 `sbctl install` 重新安装核心。

### 2. 完全卸载，保留备份

```bash
sbctl uninstall --purge
```

会先尝试创建最终备份，然后删除：

- sing-box 核心
- sbctl 命令与模块
- 配置与 metadata
- sbctl 托管证书
- sbctl 独立 Certbot 数据、Cloudflare 凭据和续期任务

`/var/backups/sbctl/` 中的备份会保留。

### 3. 彻底删除

```bash
sbctl uninstall --erase
```

需要手动输入 `DELETE` 确认。除完全卸载内容外，还会删除 sbctl 备份和 sbctl 写入的 BBR 配置，并在结束后扫描已知残留。

清理逻辑会校验路径/资源归属，不会因为 sbctl 卸载而删除系统 Certbot、其他网站的 `/etc/letsencrypt` 数据或无关系统目录。

## 项目结构

```text
sbctl.sh              命令入口
lib/core.sh            通用函数、服务抽象、元数据
lib/certmeta.sh        证书与资源 metadata、旧版迁移
lib/engine.sh          sing-box 安装、配置事务、服务定义
lib/inbound.sh         入站基础管理
lib/certificate.sh     TLS 证书选择与 SNI
lib/certops.sh         证书签发、导入、续期、删除与原子同步
lib/cloudflare.sh      Cloudflare DNS 验证、Global API Key 凭据与续期扩展
lib/reality.sh         REALITY 交互
lib/protocols.sh       支持协议与入站生成
lib/clients.sh         用户管理
lib/share.sh           分享信息
lib/ops.sh             备份、状态、配置操作
lib/uninstall.sh       三级卸载与安全清理
lib/enhancements.sh    新证书/卸载 CLI 与兼容扩展
lib/menu.sh            菜单与 CLI 路由
install.sh             systemd Linux 安装入口
alpine/install.sh      Alpine 安装入口
tests/smoke-current.sh 当前协议回归测试
tests/lifecycle.sh     证书与卸载生命周期回归测试
tests/cloudflare.sh    Cloudflare 凭据/验证/续期回归测试
```

systemd 与 OpenRC 共用同一套业务模块，不维护两份重复的管理脚本。

## 默认路径

| 内容 | 路径 |
| --- | --- |
| sing-box 配置 | `/etc/sing-box/config.json` |
| sbctl 元数据 | `/var/lib/sbctl/meta.json` |
| 托管证书 | `/etc/sing-box/certs/` |
| sing-box 数据 | `/var/lib/sing-box/` |
| Cloudflare 凭据 | `/var/lib/sbctl/letsencrypt/cloudflare.ini` |
| 备份 | `/var/backups/sbctl/` |
| 命令入口 | `/usr/local/sbin/sbctl` |
| 共享模块 | `/usr/local/lib/sbctl/` |

## 配置与数据安全

每次修改先生成候选配置并执行：

```bash
sing-box check -c <candidate>
```

只有校验通过才替换当前配置；如果原服务正在运行且重启失败，会自动恢复旧配置。

metadata 当前使用 schema 2，在保留原有入站 metadata 的同时增加 `certificates`、`managedResources` 和迁移标记，用于明确证书来源、自动续期能力和 sbctl 所有资源，降低卸载时误删系统文件的风险。

## 测试

CI 会安装当前稳定 sing-box，并使用真实 `sing-box check` 运行协议、旧配置迁移、REALITY/Hysteria2、证书生命周期、Cloudflare DNS 验证和卸载安全测试。

本地可运行：

```bash
SBCTL_TESTING=1 TERM=xterm bash tests/smoke-current.sh
SBCTL_TESTING=1 TERM=xterm bash tests/lifecycle.sh
SBCTL_TESTING=1 TERM=xterm bash tests/cloudflare.sh
```
