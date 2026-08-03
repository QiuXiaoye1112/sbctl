# sbctl

`sbctl` 是一个 Linux sing-box 终端管理器，交互方式参考 `xrayctl`，底层使用 sing-box 配置和命令。

当前版本：`0.1.0`

## 支持环境

- systemd Linux：Debian、Ubuntu、RHEL 系、Arch、openSUSE 等
- Alpine Linux / OpenRC
- sing-box `1.12.0+`

## 首批功能

- AnyTLS、VLESS、Hysteria2、Trojan、SOCKS5、HTTP、Mixed 入站
- REALITY 与证书 TLS
- 用户新增、删除、重置凭据
- 配置校验与失败回滚
- TLS 证书导入和 Let's Encrypt 域名证书签发
- config / meta / certs 整体备份恢复
- systemd / OpenRC 服务管理
- 分享信息与 AnyTLS 客户端 outbound JSON

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
sbctl backup
sbctl restore /path/to/backup.tar.gz
```

完整帮助：

```bash
sbctl help
```

## 项目结构

```text
sbctl.sh              命令入口
lib/core.sh            通用函数、服务抽象、元数据
lib/engine.sh          sing-box 安装、配置事务、服务定义
lib/inbound.sh         入站生成与管理
lib/clients.sh         用户与分享信息
lib/ops.sh             证书、备份、状态、配置操作
lib/menu.sh            菜单与 CLI 路由
install.sh             systemd Linux 安装入口
alpine/install.sh      Alpine 安装入口
tests/smoke.sh         回归测试
```

systemd 与 OpenRC 共用同一套业务模块，不维护两份重复的管理脚本。

## 默认路径

| 内容 | 路径 |
| --- | --- |
| sing-box 配置 | `/etc/sing-box/config.json` |
| sbctl 元数据 | `/var/lib/sbctl/meta.json` |
| 托管证书 | `/etc/sing-box/certs/` |
| sing-box 数据 | `/var/lib/sing-box/` |
| 备份 | `/var/backups/sbctl/` |
| 命令入口 | `/usr/local/sbin/sbctl` |
| 共享模块 | `/usr/local/lib/sbctl/` |

## 配置安全

每次修改先生成候选配置并执行：

```bash
sing-box check -c <candidate>
```

只有校验通过才替换当前配置；如果原服务正在运行且重启失败，会自动恢复旧配置。

备份恢复把 `config.json`、`meta.json` 和托管证书作为一个整体处理，恢复后服务失败时一起回滚。

## 测试

```bash
TERM=xterm bash tests/smoke.sh
```

GitHub Actions 会安装当前稳定 sing-box，并使用真实 `sing-box check` 检查代表性配置。

## 当前范围

`0.1.0` 优先完成基础管理链路。端口跳跃管理、复杂出站路由、流量统计和更多新协议留到后续版本。
