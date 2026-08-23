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
- DKMS BBR 操作需要编译工具和与当前运行内核匹配的头文件；容器中会拒绝执行。

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
| `-f` | `--fail2ban` | 不修改 SSH 设置，独立安装并配置 SSH `fail2ban` 防护。 |
| `-i` | `--disk-scheduler` | 在裸机上按设备支持情况选择磁盘 I/O 调度器，并安装开机服务。 |
| `-s` | `--ssh-security` | 加固 SSH、更改 SSH 端口、可选禁用密码登录，并配置 `fail2ban`。 |
| `-t` | `--tune` | 应用内核/网络调优，并安装周期性网络辅助服务。 |
| `-x` | `--bbrx` | 从固定并校验的源码通过 DKMS 构建安装 BBRx。 |
| `-Y` | `--bbry` | 从固定并校验的源码通过 DKMS 构建安装 BBRy。 |
| `-z` | `--bbrz` | 从固定并校验的源码通过 DKMS 构建安装 BBRz。 |
| `-3` | `--bbrv3` | 通过固定并校验的 Dedicated 安装器安装 BBRv3 内核。 |

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

`-y` 保留为上游新版的“自动确认”选项。BBRy 使用大写 `-Y` 或 `--bbry`，以解决旧 fork 中的短选项冲突。

## 网络和磁盘调优行为

- 裸机 ring buffer 按链路速率选择目标值：1 Gbit/s 及以下为 1024，10 Gbit/s 及以下为 4096，更高速率为 8192。最终值不会超过 `ethtool -g` 报告的硬件上限；无法可靠解析时直接跳过，不猜测回退值。
- 主 IPv4 默认路由使用参数数组设置 `initcwnd 100` 和 `initrwnd 100`。不使用 `eval`、不删除默认路由，并立即验证结果。定时器会在开机一分钟后及此后每五分钟重应用网络设置，因此网络管理器重建路由后也能自动修正。
- 磁盘调度会检查每个设备的实际支持列表：NVMe 优先 `none`，SATA SSD 优先 `kyber`，HDD 优先 `mq-deadline`，再从可用算法中回退。loop、RAM、光驱、device-mapper 和 MD 设备会被跳过。
- 虚拟机和容器中会跳过磁盘调度。该操作使用 `tune-disk-scheduler.service`，不写宽泛的 udev 规则。

## BBR 变体

| 变体 | 支持系统 | 安装行为 |
|---|---|---|
| BBRx | Debian 12 和 13 | 通过 DKMS 构建与发行版对应的 C 源码。 |
| BBRy | Debian 或 Ubuntu | 尝试针对当前运行内核构建 DKMS；实际内核头文件/API 是最终兼容性判据。 |
| BBRz | Debian 12 和 13 | 通过 DKMS 构建与发行版对应的 C 源码。 |
| BBRv3 | 安装器支持：amd64 上的 Debian 11/12/13 和 Ubuntu 22.04/24.04/26.04；arm64 上的 Debian 13 | 安装预编译内核，完成后需手动重启进入新内核。 |

BBRx、BBRy 和 BBRz 源码固定在 `guowanghushifu/Seedbox-Components` 提交 `802fada1488bfbb9540a5740082d557aa88f8d6b`。脚本在 DKMS 处理源码之前校验硬编码 SHA-256，自行生成 `Makefile` 和 `dkms.conf`，加载模块，然后验证算法可用且已激活。脚本不会安排自动重启。

BBRv3 使用 `jerry048/Dedicated-Seedbox` 安装器提交 `97470df47a948b0f39082e7679c630eaeff438d1`，安装器脚本本身也有固定 SHA-256。该安装器当前从持续变化的 `jerry048/Trove` `main` 分支获取内核包，但会先下载 `SHA256SUMS` 清单并校验选中的包。高级用户可使用 `TUNE_BBRV3_RAW_BASE` 覆盖该 payload 基址。

每次运行只能选择一个 BBR 变体。在生产 seedbox 上使用前，必须先在与生产环境的系统、架构和内核一致的一次性虚拟机中验证。某个内核上 DKMS 构建成功，不代表其他内核也兼容。

示例：

```bash
sudo ./tune.sh --dry-run --verbose --bbrx
sudo ./tune.sh --bbry       # 大写短选项：-Y
sudo ./tune.sh --bbrz
sudo ./tune.sh --bbrv3      # 安装成功后手动重启
```

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
systemctl list-timers tune-boot-apply.timer --no-pager
journalctl -u tune-disk-scheduler.service --no-pager -n 120
dkms status
sysctl net.ipv4.tcp_available_congestion_control net.ipv4.tcp_congestion_control
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
/etc/sysctl.d/90-tune-bbr.conf
/etc/modules-load.d/90-tune-bbr.conf
/etc/tune/*.env
/usr/local/sbin/tune-*-guard
/usr/local/sbin/tune-boot-apply
/usr/local/sbin/tune-disk-scheduler-apply
/etc/systemd/system/tune-disk-scheduler.service
/etc/systemd/system/tune-*.service
/etc/systemd/system/tune-*.timer
/usr/src/{bbrx,bbry,bbrz}-1.0.0.802fada/
```

BBRv3 安装器另外管理 `/etc/sysctl.d/90-bbr-congestion-control.conf`。Tune 会使 `/etc/sysctl.d/90-tune.conf` 与当前选中的 BBR 变体保持一致，避免后续 sysctl 加载顺序悄然覆盖它。

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
