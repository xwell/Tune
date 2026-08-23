# tune.sh

`tune.sh` 是一个适用于 Debian/Ubuntu 服务器的安全加固和网络调优辅助脚本。默认不会执行任何操作；必须明确指定一个或多个操作。

此版本新增英文和简体中文输出选项：

```bash
sudo ./tune.sh --lang zh-CN --help
sudo TUNE_LANG=zh-CN ./tune.sh --help
```

## 要求

- Debian 或 Ubuntu。
- 以 `root` 身份运行，通常使用 `sudo`。
- 安装或管理服务的操作需要 `systemd`。
- 需要能访问 `apt` 软件源以安装软件包。
- 执行 SSH 加固时，请保留一个现有可用的 SSH 会话，并在第二个会话中测试新端口。

## 快速开始

```bash
chmod +x tune.sh
sudo ./tune.sh --help
sudo ./tune.sh --dry-run --verbose -t
sudo ./tune.sh -t -s
```

使用简体中文输出：

```bash
sudo ./tune.sh --lang zh-CN --dry-run --verbose -t
sudo ./tune.sh --zh-cn -s
sudo TUNE_LANG=zh-CN ./tune.sh -t -s
```

显式切回英文：

```bash
sudo ./tune.sh --lang en -t
sudo ./tune.sh --en --help
```

## 操作选项

| 选项 | 长选项 | 作用 |
|---|---|---|
| `-a` | `--auto-updates` | 安装并配置无人值守安全更新。 |
| `-b` | `--bandwidth-limit` | 使用 `vnStat` 配置月流量超限关机保护。 |
| `-c` | `--cpu-shutdown` | 配置持续高 CPU 使用率关机保护。 |
| `-d` | `--ddos-shutdown` | 使用 `vnStat` 和 `jq` 配置流量突增关机保护。 |
| `-s` | `--ssh-security` | 加固 SSH、更改 SSH 端口、可选禁用密码登录，并配置 `fail2ban`。 |
| `-t` | `--tune` | 应用内核/网络调优，并安装开机网络辅助服务。 |

短选项可以合并，例如：

```bash
sudo ./tune.sh -ts
```

## 通用选项

| 选项 | 含义 |
|---|---|
| `-y`, `--yes` | 在脚本认为安全的 yes/no 确认处默认回答 yes。 |
| `--dry-run` | 预览变更；命令会写入日志但不会执行。 |
| `-v`, `--verbose` | 显示步骤进度、命令和生成的文件内容。 |
| `--lang <en|zh-CN>` | 选择脚本输出语言：英文或简体中文。 |
| `--zh-cn` | 等同于 `--lang zh-CN`。 |
| `--en` | 等同于 `--lang en`。 |
| `-h`, `--help` | 显示帮助。 |

## SSH 加固安全流程

SSH 操作采用分阶段流程：

1. 先添加新的 SSH 端口，同时保留当前端口。
2. 提示你打开第二个 SSH 会话并验证新端口。
3. 只有确认新端口可登录后，才会最终切换 SSH 端口。
4. 只有确认 SSH 密钥登录可用后，才会禁用密码认证。

推荐命令：

```bash
sudo ./tune.sh --ssh-security
```

完成后，从另一个终端验证：

```bash
ssh -p <new-port> root@<server-ip>
sshd -T | grep -E '^(port|passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication) '
fail2ban-client ping
fail2ban-client status sshd
```

此版本在重启 `fail2ban` 后会等待并重试 `fail2ban-client ping`，避免服务已经运行但客户端 socket 暂时未就绪造成的短暂启动竞态。

## 日志和排错

日志保存在 `/var/log/tune`：

```text
/var/log/tune/<run-id>.log
/var/log/tune/<run-id>-<step>.log
```

使用 verbose 模式可以看到每个步骤：

```bash
sudo ./tune.sh --verbose -t
```

常用诊断命令：

```bash
journalctl -u fail2ban.service --no-pager -n 120
journalctl -u ssh.service --no-pager -n 120
journalctl -u tune-boot-apply.service --no-pager -n 120
```

在某些 Ubuntu 系统上 SSH 服务单元可能叫 `sshd.service`，此时请把 `ssh.service` 替换为 `sshd.service`。

## 脚本管理的文件

根据选择的操作，脚本可能创建或更新：

```text
/etc/sysctl.d/90-tune.conf
/etc/security/limits.d/90-tune.conf
/etc/systemd/system.conf.d/90-tune.conf
/etc/ssh/sshd_config.d/99-tune.conf
/etc/fail2ban/jail.d/sshd-tune.local
/etc/tune/*.env
/usr/local/sbin/tune-*-guard
/usr/local/sbin/tune-boot-apply
/etc/systemd/system/tune-*.service
```

需要直接修改的现有文件会在适用时备份为 `.bak.<run-id>` 后缀。

## 恢复说明

如果 SSH 配置验证失败，脚本会在应用前停止。如果你已经确认过新 SSH 端口，之后又需要手动回退，请检查：

```bash
ls -l /etc/ssh/sshd_config.bak.*
cat /etc/ssh/sshd_config.d/99-tune.conf
sshd -t
systemctl reload ssh || systemctl restart ssh
```

如果软件包操作失败，请先修复 `dpkg`/`apt`：

```bash
dpkg --configure -a
apt-get -f install
apt-get update
```
