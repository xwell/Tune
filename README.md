# tune.sh

## Requirements

- Debian or Ubuntu.
- Run as `root`, usually with `sudo`.
- `systemd` is required for actions that install or manage services.
- `apt` repositories must be reachable for package installation.
- For SSH hardening, keep an existing working SSH session open while testing the new port.
- DKMS BBR actions need build tools and headers matching the running kernel; containers are rejected.

## Quick start

```bash
bash <(wget -qO- https://raw.githubusercontent.com/xwell/Tune/main/tune.sh)
bash <(wget -qO- https://raw.githubusercontent.com/xwell/Tune/main/tune.sh) --help
bash <(wget -qO- https://raw.githubusercontent.com/xwell/Tune/main/tune.sh) --dry-run --verbose -t
```

## Actions

| Option | Long option | What it does |
|---|---|---|
| `-a` | `--auto-updates` | Installs and configures unattended security updates. |
| `-b` | `--bandwidth-limit` | Configures a monthly bandwidth shutdown guard using `vnStat`. |
| `-c` | `--cpu-shutdown` | Configures a sustained high-CPU shutdown guard. |
| `-d` | `--ddos-shutdown` | Configures a traffic spike shutdown guard using `vnStat` and `jq`. |
| `-f` | `--fail2ban` | Installs and configures SSH `fail2ban` protection without changing SSH settings. |
| `-i` | `--disk-scheduler` | Selects supported disk I/O schedulers on bare metal and installs a boot-time service. |
| `-s` | `--ssh-security` | Hardens SSH, changes the SSH port, optionally disables password login, and configures `fail2ban`. |
| `-t` | `--tune` | Applies kernel/network tuning and installs a periodic network helper. |
| `-x` | `--bbrx` | Builds and installs BBRx through DKMS from pinned, verified source. |
| `-Y` | `--bbry` | Builds and installs BBRy through DKMS from pinned, verified source. |
| `-z` | `--bbrz` | Builds and installs BBRz through DKMS from pinned, verified source. |
| `-3` | `--bbrv3` | Installs a BBRv3 kernel through the pinned, verified Dedicated installer. |

Short options can be combined, for example:

```bash
sudo ./tune.sh -ts
```

## General options

| Option | Meaning |
|---|---|
| `-y`, `--yes` | Assume yes for yes/no confirmations where the script considers it safe. |
| `--dry-run` | Preview changes; commands are logged but not executed. |
| `-v`, `--verbose` | Show step-level progress, commands, and generated file content. |
| `--zh-cn` | Shortcut for `--lang zh-CN`. |
| `--en` | Shortcut for `--lang en`. |
| `-h`, `--help` | Show help. |

`-y` remains the upstream "assume yes" option. BBRy uses `-Y` (uppercase) or `--bbry`; this intentionally resolves the short-option conflict in the old fork.

## Network and disk tuning behavior

- On bare metal, ring buffers use a speed-based target: 1 Gbit/s and below uses 1024, up to 10 Gbit/s uses 4096, and faster links use 8192. Each value is capped at the maximum reported by `ethtool -g`; unreadable values are skipped instead of guessed.
- The primary IPv4 default route is updated with `initcwnd 100` and `initrwnd 100` using an argument array. The route is never deleted, `eval` is not used, and the result is verified immediately. A timer reapplies the network settings one minute after boot and every five minutes thereafter, so routes recreated by the network manager are corrected.
- Disk scheduler tuning checks each device's supported scheduler list. NVMe prefers `none`, SATA SSD prefers `kyber`, and HDD prefers `mq-deadline`, with supported fallbacks. Loop, RAM, optical, device-mapper, and MD devices are skipped.
- Disk scheduler changes are skipped in VMs and containers. The action installs `tune-disk-scheduler.service` instead of broad udev rules.

## BBR variants

| Variant | Supported systems | Installation behavior |
|---|---|---|
| BBRx | Debian 12 and 13 | Builds the distro-specific C source through DKMS. |
| BBRy | Debian or Ubuntu | Attempts a DKMS build against the running kernel; the actual kernel headers/API are the final compatibility check. |
| BBRz | Debian 12 and 13 | Builds the distro-specific C source through DKMS. |
| BBRv3 | Installer support: Debian 11/12/13 and Ubuntu 22.04/24.04/26.04 on amd64; Debian 13 on arm64 | Installs a prebuilt kernel and requires a reboot into that kernel. |

BBRx, BBRy, and BBRz sources are pinned to `guowanghushifu/Seedbox-Components` commit `802fada1488bfbb9540a5740082d557aa88f8d6b`. The script verifies a hard-coded SHA-256 before DKMS sees the source, creates its own `Makefile` and `dkms.conf`, loads the module, and verifies both availability and the active congestion-control setting. It does not schedule a reboot.

BBRv3 uses `jerry048/Dedicated-Seedbox` installer commit `97470df47a948b0f39082e7679c630eaeff438d1`, whose script SHA-256 is also pinned. That installer currently obtains kernel packages from the moving `jerry048/Trove` `main` branch, but downloads its `SHA256SUMS` manifest first and verifies the selected packages. Advanced users can override that payload base with `TUNE_BBRV3_RAW_BASE`.

Only one BBR variant may be selected per run. Test every BBR action on a disposable VM that matches the production OS, architecture, and kernel before using it on a production seedbox; a DKMS build succeeding on one kernel does not establish compatibility with another.

Examples:

```bash
sudo ./tune.sh --dry-run --verbose --bbrx
sudo ./tune.sh --bbry       # uppercase short form: -Y
sudo ./tune.sh --bbrz
sudo ./tune.sh --bbrv3      # reboot manually after a successful install
```

## SSH hardening safety

The SSH action is intentionally staged:

1. It adds the new SSH port while keeping the current port active.
2. It asks you to open a second SSH session and verify the new port.
3. Only after confirmation does it finalize the new SSH port.
4. It disables password authentication only after you confirm SSH key login works.

Recommended command:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/xwell/Tune/main/tune.sh) --ssh-security
```

After it completes, verify from another terminal:

```bash
ssh -p <new-port> root@<server-ip>
sshd -T | grep -E '^(port|passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication) '
fail2ban-client ping
fail2ban-client status sshd
```

This version also waits and retries `fail2ban-client ping` after restarting `fail2ban`, which avoids a short startup race where the service is running but the client socket is not ready yet.

## Logs and troubleshooting

Logs are stored under `/var/log/tune`:

```text
/var/log/tune/<run-id>.log
/var/log/tune/<run-id>-<step>.log
```

Use verbose mode to see each step while it runs:

```bash
sudo ./tune.sh --verbose -t
```

Useful diagnostics:

```bash
journalctl -u fail2ban.service --no-pager -n 120
journalctl -u ssh.service --no-pager -n 120
journalctl -u tune-boot-apply.service --no-pager -n 120
systemctl list-timers tune-boot-apply.timer --no-pager
journalctl -u tune-disk-scheduler.service --no-pager -n 120
dkms status
sysctl net.ipv4.tcp_available_congestion_control net.ipv4.tcp_congestion_control
```

On Ubuntu systems where the SSH unit is named `sshd.service`, use that unit name instead of `ssh.service`.

## Files managed by the script

Depending on selected actions, the script may create or update:

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

The BBRv3 installer additionally manages `/etc/sysctl.d/90-bbr-congestion-control.conf`. Tune keeps `/etc/sysctl.d/90-tune.conf` aligned with the selected BBR variant so later sysctl load order does not silently override it.

Existing files that need direct modification are backed up with a `.bak.<run-id>` suffix where applicable.

## Recovery notes

If SSH changes fail validation, the script stops before applying them. If you confirmed a new SSH port and later need to revert manually, inspect:

```bash
ls -l /etc/ssh/sshd_config.bak.*
cat /etc/ssh/sshd_config.d/99-tune.conf
sshd -t
systemctl reload ssh || systemctl restart ssh
```

For failed package operations, repair `dpkg`/`apt` first:

```bash
dpkg --configure -a
apt-get -f install
apt-get update
```
