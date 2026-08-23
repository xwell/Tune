# tune.sh

## Requirements

- Debian or Ubuntu.
- Run as `root`, usually with `sudo`.
- `systemd` is required for actions that install or manage services.
- `apt` repositories must be reachable for package installation.
- For SSH hardening, keep an existing working SSH session open while testing the new port.

## Quick start

```bash
bash <(wget -qO- https://raw.githubusercontent.com/jerry048/Tune/main/tune.sh)
bash <(wget -qO- https://raw.githubusercontent.com/jerry048/Tune/main/tune.sh) --help
bash <(wget -qO- https://raw.githubusercontent.com/jerry048/Tune/main/tune.sh) --dry-run --verbose -t
```

## Actions

| Option | Long option | What it does |
|---|---|---|
| `-a` | `--auto-updates` | Installs and configures unattended security updates. |
| `-b` | `--bandwidth-limit` | Configures a monthly bandwidth shutdown guard using `vnStat`. |
| `-c` | `--cpu-shutdown` | Configures a sustained high-CPU shutdown guard. |
| `-d` | `--ddos-shutdown` | Configures a traffic spike shutdown guard using `vnStat` and `jq`. |
| `-s` | `--ssh-security` | Hardens SSH, changes the SSH port, optionally disables password login, and configures `fail2ban`. |
| `-t` | `--tune` | Applies kernel/network tuning and installs a boot-time network helper. |

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

## SSH hardening safety

The SSH action is intentionally staged:

1. It adds the new SSH port while keeping the current port active.
2. It asks you to open a second SSH session and verify the new port.
3. Only after confirmation does it finalize the new SSH port.
4. It disables password authentication only after you confirm SSH key login works.

Recommended command:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/jerry048/Tune/main/tune.sh) --ssh-security
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
/etc/tune/*.env
/usr/local/sbin/tune-*-guard
/usr/local/sbin/tune-boot-apply
/etc/systemd/system/tune-*.service
```

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
