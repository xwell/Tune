#!/usr/bin/env bash
# tune.sh
# Debian/Ubuntu server hardening and network tuning helper.
#
# Goals:
#   - readable progress/status output
#   - concise default output with detailed per-step logs under /var/log/tune
#   - Debian/Ubuntu-only compatibility
#   - Debian 13-compatible sysctl.d usage
#   - safer defaults than the original script

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_DIR="${LOG_DIR:-/var/log/tune}"
readonly CONFIG_DIR="${CONFIG_DIR:-/etc/tune}"
readonly BIN_DIR="${BIN_DIR:-/usr/local/sbin}"
readonly SYSCTL_FILE="/etc/sysctl.d/90-tune.conf"
readonly LIMITS_FILE="/etc/security/limits.d/90-tune.conf"
readonly SYSTEMD_LIMITS_DIR="/etc/systemd/system.conf.d"
readonly SYSTEMD_LIMITS_FILE="${SYSTEMD_LIMITS_DIR}/90-tune.conf"
readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
readonly SSHD_DROPIN="${SSHD_DROPIN_DIR}/99-tune.conf"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_LOG="${LOG_DIR}/${RUN_ID}.log"
ASSUME_YES=0
DRY_RUN=0
VERBOSE=0
LANGUAGE="${TUNE_LANG:-en}"
OS_ID=""
OS_NAME=""
OS_VERSION_ID=""
OS_MAJOR=0
VIRT_TECH="none"
VIRT_KIND="none"
PRIMARY_IFACE=""
SSH_SERVICE=""

# Action/status tracking
declare -a ACTIONS=()
declare -a SUMMARY_LABELS=()
declare -a SUMMARY_RESULTS=()
declare -a SUMMARY_LOGS=()
CURRENT_ACTION_LOGS=()
LAST_STEP_LOG=""
LAST_FAILURE_CAUSE=""

# Color setup. Color is disabled automatically for non-TTY output.
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    C_RESET="$(tput sgr0)"
    C_INFO="$(tput setaf 6)"
    C_OK="$(tput setaf 2)"
    C_WARN="$(tput setaf 3)"
    C_ERR="$(tput setaf 1)"
    C_BOLD="$(tput bold)"
else
    C_RESET=""
    C_INFO=""
    C_OK=""
    C_WARN=""
    C_ERR=""
    C_BOLD=""
fi


set_language() {
    local requested="${1:-en}"
    case "${requested,,}" in
        en|en-us|en_us|english)
            LANGUAGE="en"
            ;;
        zh|zh-cn|zh_cn|zh-hans|zh_hans|cn|sc|simplified-chinese|simplified_chinese|chinese)
            LANGUAGE="zh-CN"
            ;;
        *)
            error "Unsupported language: ${requested}. Use en or zh-CN."
            return 1
            ;;
    esac
}

preparse_language() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --lang=*)
                set_language "${1#*=}" || return 1
                ;;
            --lang)
                if [[ "$#" -gt 1 ]]; then
                    set_language "$2" || return 1
                    shift
                fi
                ;;
            --zh|--zh-cn|--zh-CN)
                set_language zh-CN || return 1
                ;;
            --en|--english)
                set_language en || return 1
                ;;
        esac
        shift || true
    done
}

tr_text() {
    local text="$*"
    if [[ "${LANGUAGE:-en}" != "zh-CN" ]]; then
        printf '%s' "$text"
        return 0
    fi

    if [[ "$text" =~ ^START:\ (.*)$ ]]; then printf '开始：%s' "$(tr_text "${BASH_REMATCH[1]}")"; return 0; fi
    if [[ "$text" =~ ^[[:space:]][[:space:]]Command:\ (.*)$ ]]; then printf '  命令：%s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^[[:space:]][[:space:]]Log:\ (.*)$ ]]; then printf '  日志：%s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^OK:\ (.*)$ ]]; then printf '成功：%s' "$(tr_text "${BASH_REMATCH[1]}")"; return 0; fi
    if [[ "$text" =~ ^DRY-RUN\ OK:\ (.*)$ ]]; then printf '试运行成功：%s' "$(tr_text "${BASH_REMATCH[1]}")"; return 0; fi
    if [[ "$text" =~ ^Action:\ (.*)$ ]]; then printf '操作：%s' "$(tr_text "${BASH_REMATCH[1]}")"; return 0; fi
    if [[ "$text" =~ ^Installing\ packages:\ (.*)$ ]]; then printf '正在安装软件包：%s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Install\ packages:\ (.*)$ ]]; then printf '安装软件包：%s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Packages\ already\ installed:\ (.*)$ ]]; then printf '软件包已安装：%s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Back\ up\ (.*)$ ]]; then printf '备份 %s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Backup\ created:\ (.*)$ ]]; then printf '已创建备份：%s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Wrote\ (.*)\.\ A\ reboot\ or\ systemd\ daemon-reexec\ is\ required\ for\ manager-wide\ defaults\.$ ]]; then printf '已写入 %s。需要重启或执行 systemd daemon-reexec 后，管理器级默认限制才会生效。' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Wrote\ (.*)$ ]]; then printf '已写入 %s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Installed\ (.*)$ ]]; then printf '已安装 %s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Enable\ and\ start\ (.*)$ ]]; then printf '启用并启动 %s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Check\ (.*)\ is\ active$ ]]; then printf '检查 %s 是否正在运行' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^To\ diagnose\ (.*):\ (.*)$ ]]; then printf '诊断 %s：%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return 0; fi
    if [[ "$text" =~ ^Likely\ cause:\ (.*)$ ]]; then printf '可能原因：%s' "$(tr_text "${BASH_REMATCH[1]}")"; return 0; fi
    if [[ "$text" =~ ^Relevant\ log:\ (.*)$ ]]; then printf '相关日志：%s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Last\ log\ lines:$ ]]; then printf '日志最后几行：'; return 0; fi
    if [[ "$text" =~ ^DRY-RUN:\ would\ write\ (.*)$ ]]; then printf '试运行：将写入 %s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^DRY-RUN:\ would\ insert\ Include\ (.*)\ at\ top\ of\ (.*)$ ]]; then printf '试运行：将在 %s 顶部插入 Include %s' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^DRY-RUN:\ would\ comment\ global\ Port\ directives\ in\ (.*)$ ]]; then printf '试运行：将注释 %s 中的全局 Port 指令' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^DRY-RUN:\ would\ write\ temporary\ SSH\ drop-in\ (.*)$ ]]; then printf '试运行：将写入临时 SSH drop-in 文件 %s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Assuming\ yes:\ (.*)$ ]]; then printf '自动确认 yes：%s' "$(tr_text "${BASH_REMATCH[1]}")"; return 0; fi
    if [[ "$text" =~ ^Interactive\ input\ is\ required\ for:\ (.*)$ ]]; then printf '需要交互式输入：%s' "$(tr_text "${BASH_REMATCH[1]}")"; return 0; fi
    if [[ "$text" =~ ^Enter\ a\ number\ between\ ([0-9]+)\ and\ ([0-9]+)\.$ ]]; then printf '请输入 %s 到 %s 之间的数字。' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return 0; fi
    if [[ "$text" =~ ^Invalid\ option:\ (.*)$ ]]; then printf '无效选项：%s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Unexpected\ argument:\ (.*)$ ]]; then printf '意外参数：%s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Unsupported\ language:\ (.*)\.\ Use\ en\ or\ zh-CN\.$ ]]; then printf '不支持的语言：%s。请使用 en 或 zh-CN。' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Detected\ system:\ (.*),\ virtualization:\ (.*),\ primary\ interface:\ (.*)$ ]]; then printf '检测到系统：%s，虚拟化：%s，主网卡：%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"; return 0; fi
    if [[ "$text" =~ ^Detected\ interface\ has\ unexpected\ characters\ and\ will\ not\ be\ used:\ (.*)$ ]]; then printf '检测到的网卡名称包含异常字符，将不使用：%s' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Port\ ([0-9]+)\ already\ appears\ to\ be\ listening\.\ SSH\ may\ already\ use\ it,\ or\ another\ service\ may\ conflict\.$ ]]; then printf '端口 %s 看起来已在监听。可能是 SSH 已使用该端口，或有其他服务冲突。' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Open\ a\ second\ SSH\ session\ now\ and\ verify\ that\ port\ ([0-9]+)\ works\ before\ continuing\.$ ]]; then printf '现在请打开第二个 SSH 会话，并在继续前确认端口 %s 可以登录。' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Can\ you\ log\ in\ through\ SSH\ port\ ([0-9]+)\?$ ]]; then printf '你能通过 SSH 端口 %s 登录吗？' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^SSH\ now\ listens\ on\ port\ ([0-9]+)\.\ Existing\ global\ Port\ directives\ were\ backed\ up/commented\.$ ]]; then printf 'SSH 现在监听端口 %s。现有全局 Port 指令已备份并注释。' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Allow\ SSH\ port\ ([0-9]+)/tcp\ in\ UFW$ ]]; then printf '在 UFW 中放行 SSH 端口 %s/tcp' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Initialize\ vnStat\ database\ for\ (.*)$ ]]; then printf '初始化 %s 的 vnStat 数据库' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Set\ RX\ ring\ buffer\ on\ (.*)$ ]]; then printf '设置 %s 的 RX 环形缓冲区' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Set\ TX\ ring\ buffer\ on\ (.*)$ ]]; then printf '设置 %s 的 TX 环形缓冲区' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Disable\ TSO/GSO/GRO\ offloads\ on\ (.*)$ ]]; then printf '关闭 %s 的 TSO/GSO/GRO 卸载' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Set\ txqueuelen\ on\ (.*)$ ]]; then printf '设置 %s 的 txqueuelen' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Apply\ sysctl\ tuning\ from\ (.*)$ ]]; then printf '应用来自 %s 的 sysctl 调优' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^Starting\ (.*)\.\ Main\ log:\ (.*)$ ]]; then printf '开始运行 %s。主日志：%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return 0; fi
    if [[ "$text" =~ ^Check\ fail2ban\ status$ ]]; then printf '检查 fail2ban 状态'; return 0; fi
    if [[ "$text" =~ ^Container\ detected\ \((.*)\)\.\ Skipping\ sysctl\ tuning\ because\ many\ kernel\ parameters\ are\ controlled\ by\ the\ host\.$ ]]; then printf '检测到容器（%s）。跳过 sysctl 调优，因为许多内核参数由宿主机控制。' "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$text" =~ ^BBR\ is\ not\ available\ in\ the\ current\ kernel\;\ keeping\ congestion\ control\ as\ (.*)\.$ ]]; then printf '当前内核不支持 BBR；保持拥塞控制为 %s。' "${BASH_REMATCH[1]}"; return 0; fi

    case "$text" in
        "Auto updates") printf '自动安全更新' ;;
        "Bandwidth guard") printf '月流量保护' ;;
        "CPU guard") printf 'CPU 保护' ;;
        "Traffic spike guard") printf '流量突增保护' ;;
        "SSH security") printf 'SSH 安全加固' ;;
        "System tuning") printf '系统调优' ;;
        "SUCCESS") printf '成功' ;;
        "FAILED") printf '失败' ;;
        "command") printf '命令' ;;
        "Update apt package index") printf '更新 APT 软件包索引' ;;
        "Reload systemd unit files") printf '重新加载 systemd 单元文件' ;;
        "Enable apt daily timers") printf '启用 APT 每日定时器' ;;
        "Enable vnStat service") printf '启用 vnStat 服务' ;;
        "Enable unattended-upgrades with debconf") printf '通过 debconf 启用 unattended-upgrades' ;;
        "Validate SSH server configuration") printf '验证 SSH 服务器配置' ;;
        "Reload SSH service") printf '重新加载 SSH 服务' ;;
        "Restart SSH service") printf '重启 SSH 服务' ;;
        "Restart fail2ban") printf '重启 fail2ban' ;;
        "Configuring unattended security updates") printf '正在配置无人值守安全更新' ;;
        "Configuring monthly bandwidth shutdown guard") printf '正在配置月流量关机保护' ;;
        "Configuring sustained high-CPU shutdown guard") printf '正在配置持续高 CPU 关机保护' ;;
        "Configuring traffic spike shutdown guard") printf '正在配置流量突增关机保护' ;;
        "Configuring SSH hardening") printf '正在配置 SSH 加固' ;;
        "Installing and configuring fail2ban for SSH") printf '正在为 SSH 安装并配置 fail2ban' ;;
        "Applying system tuning") printf '正在应用系统调优' ;;
        "Set initial congestion window on default route") printf '设置默认路由的初始拥塞窗口' ;;
        "System tuning completed. Some limits require a reboot or a new login session to fully apply.") printf '系统调优已完成。部分限制需要重启或重新登录后才会完全生效。' ;;
        "No primary network interface detected.") printf '未检测到主网卡。' ;;
        "No primary interface detected. Skipping netdev tuning.") printf '未检测到主网卡，跳过网络设备调优。' ;;
        "Container detected; skipping link queue and route tuning.") printf '检测到容器，跳过链路队列和路由调优。' ;;
        "ip command not found. Network-interface actions will fail until iproute2 is installed.") printf '未找到 ip 命令。安装 iproute2 前，网卡相关操作会失败。' ;;
        "This action requires systemd. The current environment does not appear to be booted with systemd.") printf '此操作需要 systemd。当前环境似乎不是由 systemd 启动。' ;;
        "This script must be run as root. Try: sudo ./${SCRIPT_NAME} ...") printf '此脚本必须以 root 身份运行。请尝试：sudo ./${SCRIPT_NAME} ...' ;;
        "Cannot read /etc/os-release. This script supports Debian and Ubuntu only.") printf '无法读取 /etc/os-release。此脚本仅支持 Debian 和 Ubuntu。' ;;
        "Please answer y or n.") printf '请输入 y 或 n。' ;;
        "Missing value for --lang. Use en or zh-CN.") printf '缺少 --lang 的值。请使用 en 或 zh-CN。' ;;
        "No action runs by default. Pass one or more actions explicitly.") printf '默认不会执行任何操作。请明确指定一个或多个操作。' ;;
        "Dry-run mode is enabled; commands are logged but not executed.") printf '试运行模式已启用；命令会写入日志，但不会执行。' ;;
        "Keeping the existing SSH configuration. New port was not finalized.") printf '保留现有 SSH 配置。新端口未最终启用。' ;;
        "Before disabling passwords, verify key login in a second SSH session.") printf '禁用密码前，请在第二个 SSH 会话中确认密钥登录可用。' ;;
        "Can you log in with an SSH key?") printf '你能使用 SSH 密钥登录吗？' ;;
        "No /root/.ssh/authorized_keys file was found. Password authentication will not be disabled automatically.") printf '未找到 /root/.ssh/authorized_keys。不会自动禁用密码认证。' ;;
        "SSH password and keyboard-interactive authentication disabled. Root login is key-only/prohibit-password.") printf '已禁用 SSH 密码和键盘交互认证。root 登录为仅密钥/prohibit-password。' ;;
        "Password authentication left enabled.") printf '已保留密码认证。' ;;
        "RX ring tuning skipped; unsupported by this NIC/driver.") printf '已跳过 RX 环形缓冲区调优；此网卡/驱动不支持。' ;;
        "TX ring tuning skipped; unsupported by this NIC/driver.") printf '已跳过 TX 环形缓冲区调优；此网卡/驱动不支持。' ;;
        "Offload tuning skipped; unsupported by this NIC/driver/hypervisor.") printf '已跳过卸载调优；此网卡/驱动/虚拟化环境不支持。' ;;
        "txqueuelen tuning skipped.") printf '已跳过 txqueuelen 调优。' ;;
        "Initial congestion window tuning skipped.") printf '已跳过初始拥塞窗口调优。' ;;
        "APT/dpkg is locked or interrupted. Another package operation may be running, or dpkg needs repair.") printf 'APT/dpkg 被锁定或中断。可能有其他软件包操作正在运行，或需要修复 dpkg。' ;;
        "Network, DNS, or package mirror connectivity failed.") printf '网络、DNS 或软件源镜像连接失败。' ;;
        "A required package is unavailable from the enabled Debian/Ubuntu repositories.") printf '已启用的 Debian/Ubuntu 软件源中没有所需软件包。' ;;
        "APT repository signature/key verification failed.") printf 'APT 软件源签名/密钥验证失败。' ;;
        "The command lacked permission, or the host/container blocks that operation.") printf '命令权限不足，或主机/容器阻止了该操作。' ;;
        "A required command, file, or path was missing.") printf '缺少所需命令、文件或路径。' ;;
        "The detected network interface is missing or changed name.") printf '检测到的网卡不存在或名称已变化。' ;;
        "The kernel, network driver, hypervisor, or container does not support that setting.") printf '内核、网络驱动、虚拟化平台或容器不支持该设置。' ;;
        "The generated SSH configuration failed validation.") printf '生成的 SSH 配置未通过验证。' ;;
        "A systemd service failed. Use journalctl for that service for more detail.") printf 'systemd 服务失败。请使用 journalctl 查看该服务的更多详情。' ;;
        "Unknown. Check the log for the command output.") printf '未知。请检查日志中的命令输出。' ;;
        "Monthly upload limit in GiB:") printf '月上传流量限制（GiB）：' ;;
        "Monthly download limit in GiB:") printf '月下载流量限制（GiB）：' ;;
        "Bandwidth reset day of month (1-31):") printf '每月流量重置日（1-31）：' ;;
        "CPU usage threshold percent (1-100):") printf 'CPU 使用率阈值百分比（1-100）：' ;;
        "Traffic threshold in Mbps:") printf '流量阈值（Mbps）：' ;;
        "Packet threshold in packets per second:") printf '包速率阈值（pps）：' ;;
        "New SSH port (1-65535):") printf '新的 SSH 端口（1-65535）：' ;;
        "Run summary") printf '运行摘要' ;;
        *) printf '%s' "$text" ;;
    esac
}

usage() {
    if [[ "${LANGUAGE:-en}" == "zh-CN" ]]; then
        cat <<USAGE_ZH
用法：${SCRIPT_NAME} [选项]

默认不会执行任何操作。请明确指定一个或多个操作。

操作：
  -a, --auto-updates       安装/配置无人值守安全更新
  -b, --bandwidth-limit    配置月流量超限关机保护
  -c, --cpu-shutdown       配置持续高 CPU 使用率关机保护
  -d, --ddos-shutdown      配置流量突增关机保护
  -s, --ssh-security       加固 SSH，并安装/配置 fail2ban
  -t, --tune               应用内核/网络调优和开机网络设备辅助服务

通用：
  -y, --yes                在安全的 yes/no 确认处默认回答 yes
      --dry-run            预览变更；命令会写入日志但不会执行
  -v, --verbose            显示步骤进度、命令和生成的文件内容
      --lang <en|zh-CN>    选择输出语言：英文或简体中文
      --zh-cn              等同于 --lang zh-CN
      --en                 等同于 --lang en
  -h, --help               显示此帮助

示例：
  sudo ./${SCRIPT_NAME} -t -s
  sudo ./${SCRIPT_NAME} --auto-updates --tune --ssh-security
  sudo ./${SCRIPT_NAME} --lang zh-CN --dry-run --verbose -t
  sudo TUNE_LANG=zh-CN ./${SCRIPT_NAME} --help

日志：
  主日志：${LOG_DIR}/<run-id>.log
  步骤日志：${LOG_DIR}/<run-id>-<step>.log
USAGE_ZH
        return 0
    fi

    cat <<USAGE
Usage: ${SCRIPT_NAME} [options]

No action runs by default. Pass one or more actions explicitly.

Actions:
  -a, --auto-updates       Install/configure unattended security updates
  -b, --bandwidth-limit    Configure monthly bandwidth shutdown guard
  -c, --cpu-shutdown       Configure sustained high-CPU shutdown guard
  -d, --ddos-shutdown      Configure traffic spike shutdown guard
  -s, --ssh-security       Harden SSH and install/configure fail2ban
  -t, --tune               Apply kernel/network tuning and boot-time netdev helper

General:
  -y, --yes                Assume yes for yes/no confirmations where safe
      --dry-run            Preview changes; commands are logged but not executed
  -v, --verbose            Show step-level progress, commands, and generated file content
      --lang <en|zh-CN>    Display script messages in English or Simplified Chinese
      --zh-cn              Shortcut for --lang zh-CN
      --en                 Shortcut for --lang en
  -h, --help               Show this help

Examples:
  sudo ./${SCRIPT_NAME} -t -s
  sudo ./${SCRIPT_NAME} --auto-updates --tune --ssh-security
  sudo ./${SCRIPT_NAME} --lang zh-CN --dry-run --verbose -t
  sudo TUNE_LANG=zh-CN ./${SCRIPT_NAME} --help

Logs:
  Main log: ${LOG_DIR}/<run-id>.log
  Step logs: ${LOG_DIR}/<run-id>-<step>.log
USAGE
}

log_file() {
    local level="$1"
    shift
    # Logging must never break help, argument parsing, or non-root error output.
    if mkdir -p "$LOG_DIR" 2>/dev/null && [[ -w "$LOG_DIR" ]]; then
        chmod 0700 "$LOG_DIR" 2>/dev/null || true
        { printf '%s [%s] %s\n' "$(date -Is)" "$level" "$*" >> "$RUN_LOG"; } 2>/dev/null || true
    fi
}

say() {
    local color="$1"
    shift
    printf '%b%s%b\n' "$color" "$*" "$C_RESET"
}

info() {
    local rendered
    rendered="$(tr_text "$*")"
    log_file INFO "$*"
    if [[ "$VERBOSE" -eq 1 ]]; then
        say "$C_INFO" "$rendered"
    fi
}

notice() {
    local rendered
    rendered="$(tr_text "$*")"
    log_file INFO "$*"
    say "$C_INFO" "$rendered"
}

success() {
    local rendered
    rendered="$(tr_text "$*")"
    log_file OK "$*"
    if [[ "$VERBOSE" -eq 1 ]]; then
        say "$C_OK" "$rendered"
    fi
}

status_ok() {
    local rendered
    rendered="$(tr_text "$*")"
    log_file OK "$*"
    if [[ "${LANGUAGE:-en}" == "zh-CN" ]]; then
        say "$C_OK" "成功：${rendered}"
    else
        say "$C_OK" "OK: ${rendered}"
    fi
}

status_failed() {
    local rendered
    rendered="$(tr_text "$*")"
    log_file ERROR "$*"
    if [[ "${LANGUAGE:-en}" == "zh-CN" ]]; then
        printf '%b%s%b\n' "$C_ERR" "失败：${rendered}" "$C_RESET" >&2
    else
        printf '%b%s%b\n' "$C_ERR" "FAILED: ${rendered}" "$C_RESET" >&2
    fi
}

warn() {
    local rendered
    rendered="$(tr_text "$*")"
    log_file WARN "$*"
    if [[ "${LANGUAGE:-en}" == "zh-CN" ]]; then
        printf '%b%s%b\n' "$C_WARN" "警告：${rendered}" "$C_RESET" >&2
    else
        printf '%b%s%b\n' "$C_WARN" "WARNING: ${rendered}" "$C_RESET" >&2
    fi
}

error() {
    local rendered
    rendered="$(tr_text "$*")"
    log_file ERROR "$*"
    if [[ "${LANGUAGE:-en}" == "zh-CN" ]]; then
        printf '%b%s%b\n' "$C_ERR" "错误：${rendered}" "$C_RESET" >&2
    else
        printf '%b%s%b\n' "$C_ERR" "ERROR: ${rendered}" "$C_RESET" >&2
    fi
}

separator() {
    [[ "$VERBOSE" -eq 1 ]] || return 0
    local width=80
    if command -v tput >/dev/null 2>&1; then
        width="$(tput cols 2>/dev/null || echo 80)"
    fi
    printf '\n%*s\n' "$width" '' | tr ' ' '='
}

slugify() {
    tr '[:upper:]' '[:lower:]' <<<"$*" | tr -cs '[:alnum:]' '-' | sed 's/^-//; s/-$//; s/--*/-/g' | cut -c1-80
}

quote_args() {
    local out=""
    local arg
    for arg in "$@"; do
        printf -v out '%s %q' "$out" "$arg"
    done
    printf '%s' "${out# }"
}

record_summary() {
    local label="$1"
    local result="$2"
    local logs="$3"
    SUMMARY_LABELS+=("$label")
    SUMMARY_RESULTS+=("$result")
    SUMMARY_LOGS+=("$logs")
}

join_by() {
    local delimiter="$1"
    shift || true
    local first=1
    local item
    for item in "$@"; do
        if [[ "$first" -eq 1 ]]; then
            printf '%s' "$item"
            first=0
        else
            printf '%s%s' "$delimiter" "$item"
        fi
    done
}

diagnose_failure() {
    local logfile="$1"
    local label="${2:-command}"
    local cause="Unknown. Check the log for the command output."

    if [[ -s "$logfile" ]]; then
        if grep -Eqi 'Could not get lock|Unable to acquire the dpkg frontend lock|dpkg was interrupted|you must manually run dpkg --configure -a' "$logfile"; then
            cause="APT/dpkg is locked or interrupted. Another package operation may be running, or dpkg needs repair."
        elif grep -Eqi 'Temporary failure resolving|Could not resolve|Name or service not known|Network is unreachable|Connection timed out|Failed to fetch' "$logfile"; then
            cause="Network, DNS, or package mirror connectivity failed."
        elif grep -Eqi 'Unable to locate package|Package .* has no installation candidate|E: Version .* was not found' "$logfile"; then
            cause="A required package is unavailable from the enabled Debian/Ubuntu repositories."
        elif grep -Eqi 'NO_PUBKEY|The following signatures couldn.t be verified|is not signed|EXPKEYSIG|BADSIG' "$logfile"; then
            cause="APT repository signature/key verification failed."
        elif grep -Eqi 'Permission denied|Operation not permitted' "$logfile"; then
            cause="The command lacked permission, or the host/container blocks that operation."
        elif grep -Eqi 'No such file or directory|command not found|not found' "$logfile"; then
            cause="A required command, file, or path was missing."
        elif grep -Eqi 'Cannot find device|No such device|Device not found' "$logfile"; then
            cause="The detected network interface is missing or changed name."
        elif grep -Eqi 'Operation not supported|not supported' "$logfile"; then
            cause="The kernel, network driver, hypervisor, or container does not support that setting."
        elif grep -Eqi 'Bad configuration option|unsupported option|Missing privilege separation directory|sshd.*error|line [0-9]+:' "$logfile"; then
            cause="The generated SSH configuration failed validation."
        elif grep -Eqi 'Unit .* not found|Failed to start|Job for .* failed|inactive|failed' "$logfile"; then
            cause="A systemd service failed. Use journalctl for that service for more detail."
        fi
    fi

    LAST_FAILURE_CAUSE="$cause"
    status_failed "${label}"
    error "Likely cause: ${cause}"
    error "Relevant log: ${logfile}"
    if [[ "$VERBOSE" -eq 1 && -s "$logfile" ]]; then
        warn "Last log lines:"
        tail -n 8 "$logfile" | sed 's/^/  /' >&2 || true
    fi
}

run_cmd() {
    local label="$1"
    shift
    local slug step_log rc command_line
    slug="$(slugify "$label")"
    step_log="${LOG_DIR}/${RUN_ID}-${slug}.log"
    LAST_STEP_LOG="$step_log"
    CURRENT_ACTION_LOGS+=("$step_log")
    command_line="$(quote_args "$@")"

    info "START: ${label}"
    info "  Command: ${command_line}"
    info "  Log: ${step_log}"

    mkdir -p "$LOG_DIR"
    chmod 0700 "$LOG_DIR"
    {
        printf '%s\n' "### ${label}"
        printf 'Started: %s\n' "$(date -Is)"
        printf 'Command: %s\n\n' "$command_line"
    } > "$step_log"
    chmod 0600 "$step_log"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf 'DRY-RUN: command not executed.\n' >> "$step_log"
        success "DRY-RUN OK: ${label}"
        return 0
    fi

    set +e
    "$@" >> "$step_log" 2>&1
    rc=$?
    set -e

    {
        printf '\nFinished: %s\n' "$(date -Is)"
        printf 'Exit code: %s\n' "$rc"
    } >> "$step_log"
    cat "$step_log" >> "$RUN_LOG" || true

    if [[ "$rc" -eq 0 ]]; then
        success "OK: ${label}"
        return 0
    fi

    diagnose_failure "$step_log" "$label"
    return "$rc"
}

run_shell() {
    local label="$1"
    local script="$2"
    run_cmd "$label" bash -Eeuo pipefail -c "$script"
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        error "This script must be run as root. Try: sudo ./${SCRIPT_NAME} ..."
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

systemd_available() {
    command_exists systemctl && [[ -d /run/systemd/system ]]
}

apt_get() {
    DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Lock::Timeout=120 "$@"
}

is_package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

ensure_packages() {
    local missing=()
    local pkg
    for pkg in "$@"; do
        if ! is_package_installed "$pkg"; then
            missing+=("$pkg")
        fi
    done

    if [[ "${#missing[@]}" -eq 0 ]]; then
        success "Packages already installed: $(join_by ', ' "$@")"
        return 0
    fi

    notice "Installing packages: $(join_by ', ' "${missing[@]}")"
    run_cmd "Update apt package index" apt_get update || return 1
    run_cmd "Install packages: $(join_by ', ' "${missing[@]}")" apt_get install -y --no-install-recommends "${missing[@]}" || return 1
}

backup_file() {
    local file="$1"
    if [[ -e "$file" ]]; then
        local backup="${file}.bak.${RUN_ID}"
        run_cmd "Back up ${file}" cp -a "$file" "$backup" || return 1
        info "Backup created: ${backup}"
    fi
}

write_file() {
    local path="$1"
    local mode="$2"
    local owner_group="${3:-root:root}"
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "DRY-RUN: would write ${path}"
        if [[ "$VERBOSE" -eq 1 ]]; then
            sed 's/^/  | /' "$tmp" || true
        fi
        rm -f "$tmp"
        return 0
    fi
    install -o "${owner_group%:*}" -g "${owner_group#*:}" -m "$mode" "$tmp" "$path"
    rm -f "$tmp"
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local answer

    if [[ "$ASSUME_YES" -eq 1 ]]; then
        info "Assuming yes: ${prompt}"
        return 0
    fi

    while true; do
        if [[ "$default" == "y" ]]; then
            read -r -p "$(tr_text "$prompt") [Y/n]: " answer
            answer="${answer:-y}"
        else
            read -r -p "$(tr_text "$prompt") [y/N]: " answer
            answer="${answer:-n}"
        fi
        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
            *) warn "Please answer y or n." ;;
        esac
    done
}

prompt_int() {
    local prompt="$1"
    local min="$2"
    local max="$3"
    local __resultvar="$4"
    local value

    if [[ ! -t 0 ]]; then
        error "Interactive input is required for: ${prompt}"
        return 1
    fi

    while true; do
        read -r -p "$(tr_text "$prompt") " value
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min && value <= max )); then
            printf -v "$__resultvar" '%s' "$value"
            return 0
        fi
        warn "Enter a number between ${min} and ${max}."
    done
}

validate_iface_name() {
    [[ "$1" =~ ^[A-Za-z0-9_.:@-]+$ ]]
}

detect_system() {
    if [[ ! -r /etc/os-release ]]; then
        error "Cannot read /etc/os-release. This script supports Debian and Ubuntu only."
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_NAME="${PRETTY_NAME:-${NAME:-unknown}}"
    OS_VERSION_ID="${VERSION_ID:-0}"
    OS_MAJOR="${OS_VERSION_ID%%.*}"
    [[ "$OS_MAJOR" =~ ^[0-9]+$ ]] || OS_MAJOR=0

    case "$OS_ID" in
        debian|ubuntu) ;;
        *)
            error "Unsupported OS: ${OS_NAME}. This script intentionally supports only Debian and Ubuntu."
            exit 1
            ;;
    esac

    if command_exists systemd-detect-virt; then
        VIRT_TECH="$(systemd-detect-virt 2>/dev/null || true)"
        [[ -n "$VIRT_TECH" ]] || VIRT_TECH="none"
        if systemd-detect-virt --container >/dev/null 2>&1; then
            VIRT_KIND="container"
        elif systemd-detect-virt --vm >/dev/null 2>&1; then
            VIRT_KIND="vm"
        else
            VIRT_KIND="none"
        fi
    fi

    if command_exists ip; then
        PRIMARY_IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' | cut -d'@' -f1)"
        if [[ -z "$PRIMARY_IFACE" ]]; then
            PRIMARY_IFACE="$(ip -o link show up 2>/dev/null | awk -F': ' '$2 != "lo" {gsub(/@.*/, "", $2); print $2; exit}')"
        fi
        if [[ -n "$PRIMARY_IFACE" ]] && ! validate_iface_name "$PRIMARY_IFACE"; then
            warn "Detected interface has unexpected characters and will not be used: ${PRIMARY_IFACE}"
            PRIMARY_IFACE=""
        fi
    else
        warn "ip command not found. Network-interface actions will fail until iproute2 is installed."
        PRIMARY_IFACE=""
    fi

    if systemd_available; then
        if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
            SSH_SERVICE="ssh.service"
        elif systemctl list-unit-files sshd.service >/dev/null 2>&1; then
            SSH_SERVICE="sshd.service"
        else
            SSH_SERVICE="ssh.service"
        fi
    else
        SSH_SERVICE="ssh"
    fi

    info "Detected system: ${OS_NAME} (${OS_ID} ${OS_VERSION_ID}), virtualization: ${VIRT_TECH}, primary interface: ${PRIMARY_IFACE:-unknown}"
}

require_systemd() {
    if ! systemd_available; then
        error "This action requires systemd. The current environment does not appear to be booted with systemd."
        return 1
    fi
}

service_logs_hint() {
    local unit="$1"
    info "To diagnose ${unit}: journalctl -u ${unit} --no-pager -n 120"
}


wait_for_fail2ban() {
    local attempts="${1:-30}"
    local delay="${2:-1}"
    local i

    for ((i=1; i<=attempts; i++)); do
        if fail2ban-client ping >/dev/null 2>&1; then
            fail2ban-client ping
            return 0
        fi
        sleep "$delay"
    done

    fail2ban-client ping
}

reload_systemd() {
    require_systemd || return 1
    run_cmd "Reload systemd unit files" systemctl daemon-reload
}

enable_start_service() {
    local unit="$1"
    reload_systemd || return 1
    run_cmd "Enable and start ${unit}" systemctl enable --now "$unit" || {
        service_logs_hint "$unit"
        return 1
    }
    run_cmd "Check ${unit} is active" systemctl is-active --quiet "$unit" || {
        service_logs_hint "$unit"
        return 1
    }
}

install_linux_sysctl_defaults_if_needed() {
    if [[ "$OS_ID" == "debian" && "$OS_MAJOR" -ge 13 ]]; then
        ensure_packages linux-sysctl-defaults || {
            warn "linux-sysctl-defaults could not be installed. Continuing, but Debian 13 defaults may be incomplete."
            return 0
        }
    fi
}

configure_auto_updates() {
    separator
    info "Configuring unattended security updates"
    ensure_packages unattended-upgrades apt-listchanges || return 1

    run_shell "Enable unattended-upgrades with debconf" \
        "printf '%s\n' 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections && dpkg-reconfigure -f noninteractive unattended-upgrades" || return 1

    write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF_AUTO'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF_AUTO
    success "Wrote /etc/apt/apt.conf.d/20auto-upgrades"

    if systemd_available; then
        run_cmd "Enable apt daily timers" systemctl enable --now apt-daily.timer apt-daily-upgrade.timer || return 1
    fi
}

write_bandwidth_guard_script() {
    write_file "${BIN_DIR}/tune-bandwidth-guard" 0755 <<'EOF_BW_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

CONFIG_FILE="/etc/tune/bandwidth-guard.env"
[[ -r "$CONFIG_FILE" ]] || { echo "Missing config: $CONFIG_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${INTERFACE:?missing INTERFACE}"
: "${MONTHLY_UPLOAD_LIMIT_GIB:?missing MONTHLY_UPLOAD_LIMIT_GIB}"
: "${MONTHLY_DOWNLOAD_LIMIT_GIB:?missing MONTHLY_DOWNLOAD_LIMIT_GIB}"
: "${RESET_DAY:?missing RESET_DAY}"
CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-60}"

log_msg() {
    local priority="$1"
    shift
    if command -v systemd-cat >/dev/null 2>&1; then
        printf '%s\n' "$*" | systemd-cat -t tune-bandwidth-guard -p "$priority" || true
    fi
    printf '%s [%s] %s\n' "$(date -Is)" "$priority" "$*"
}

last_day_of_month() {
    date -d "$1 +1 month -1 day" +%d
}

anchor_for_month() {
    local month_start="$1"
    local year month last day
    year="$(date -d "$month_start" +%Y)"
    month="$(date -d "$month_start" +%m)"
    last="$(last_day_of_month "${year}-${month}-01")"
    day="$RESET_DAY"
    (( day > 10#$last )) && day="$last"
    printf '%04d-%02d-%02d\n' "$year" "10#$month" "$day"
}

period_bounds() {
    local today month_start current_anchor prev_month next_month begin end
    today="$(date +%Y-%m-%d)"
    month_start="$(date +%Y-%m-01)"
    current_anchor="$(anchor_for_month "$month_start")"
    if [[ "$today" > "$current_anchor" || "$today" == "$current_anchor" ]]; then
        begin="$current_anchor"
        next_month="$(date -d "$month_start +1 month" +%Y-%m-01)"
        end="$(anchor_for_month "$next_month")"
    else
        prev_month="$(date -d "$month_start -1 month" +%Y-%m-01)"
        begin="$(anchor_for_month "$prev_month")"
        end="$current_anchor"
    fi
    printf '%s %s\n' "$begin" "$end"
}

to_gib() {
    local value="$1"
    local unit="$2"
    awk -v value="$value" -v unit="$unit" 'BEGIN {
        if (unit == "B")   printf "%.6f", value / 1073741824;
        else if (unit == "KiB") printf "%.6f", value / 1048576;
        else if (unit == "MiB") printf "%.6f", value / 1024;
        else if (unit == "GiB") printf "%.6f", value;
        else if (unit == "TiB") printf "%.6f", value * 1024;
        else exit 2;
    }'
}

ge_float() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'
}

while true; do
    read -r begin_date end_date < <(period_bounds)
    if ! line="$(vnstat --begin "$begin_date" --end "$end_date" -i "$INTERFACE" --oneline 2>&1)"; then
        log_msg warning "vnStat query failed for ${INTERFACE}: ${line}"
        sleep "$CHECK_INTERVAL_SECONDS"
        continue
    fi

    upload="$(awk -F';' '{print $10}' <<<"$line")"
    download="$(awk -F';' '{print $9}' <<<"$line")"
    upload_value="$(awk '{print $1}' <<<"$upload")"
    upload_unit="$(awk '{print $2}' <<<"$upload")"
    download_value="$(awk '{print $1}' <<<"$download")"
    download_unit="$(awk '{print $2}' <<<"$download")"

    if ! upload_gib="$(to_gib "$upload_value" "$upload_unit")"; then
        log_msg warning "Unknown upload unit from vnStat: ${upload_unit:-empty}"
        sleep "$CHECK_INTERVAL_SECONDS"
        continue
    fi
    if ! download_gib="$(to_gib "$download_value" "$download_unit")"; then
        log_msg warning "Unknown download unit from vnStat: ${download_unit:-empty}"
        sleep "$CHECK_INTERVAL_SECONDS"
        continue
    fi

    if ge_float "$upload_gib" "$MONTHLY_UPLOAD_LIMIT_GIB"; then
        log_msg crit "Monthly upload limit exceeded: ${upload_gib} GiB >= ${MONTHLY_UPLOAD_LIMIT_GIB} GiB. Shutting down."
        shutdown -h now "Monthly upload bandwidth limit exceeded"
    fi
    if ge_float "$download_gib" "$MONTHLY_DOWNLOAD_LIMIT_GIB"; then
        log_msg crit "Monthly download limit exceeded: ${download_gib} GiB >= ${MONTHLY_DOWNLOAD_LIMIT_GIB} GiB. Shutting down."
        shutdown -h now "Monthly download bandwidth limit exceeded"
    fi

    sleep "$CHECK_INTERVAL_SECONDS"
done
EOF_BW_SCRIPT
}

configure_bandwidth_limit() {
    separator
    info "Configuring monthly bandwidth shutdown guard"

    local upload_limit download_limit reset_day
    prompt_int "Monthly upload limit in GiB:" 1 100000000 upload_limit || return 1
    prompt_int "Monthly download limit in GiB:" 1 100000000 download_limit || return 1
    prompt_int "Bandwidth reset day of month (1-31):" 1 31 reset_day || return 1

    if [[ -z "$PRIMARY_IFACE" ]]; then
        error "No primary network interface detected."
        return 1
    fi

    ensure_packages vnstat || return 1
    require_systemd || return 1
    mkdir -p "$CONFIG_DIR" "$BIN_DIR"

    if systemctl list-unit-files vnstat.service >/dev/null 2>&1; then
        run_cmd "Enable vnStat service" systemctl enable --now vnstat.service || return 1
    fi
    run_shell "Initialize vnStat database for ${PRIMARY_IFACE}" "vnstat --add -i '$PRIMARY_IFACE' >/dev/null 2>&1 || true" || return 1

    write_file "${CONFIG_DIR}/bandwidth-guard.env" 0600 <<EOF_BW_ENV
INTERFACE="${PRIMARY_IFACE}"
MONTHLY_UPLOAD_LIMIT_GIB="${upload_limit}"
MONTHLY_DOWNLOAD_LIMIT_GIB="${download_limit}"
RESET_DAY="${reset_day}"
CHECK_INTERVAL_SECONDS="60"
EOF_BW_ENV
    success "Wrote ${CONFIG_DIR}/bandwidth-guard.env"

    write_bandwidth_guard_script
    success "Installed ${BIN_DIR}/tune-bandwidth-guard"

    write_file /etc/systemd/system/tune-bandwidth-guard.service 0644 <<'EOF_BW_UNIT'
[Unit]
Description=Tune Bandwidth Shutdown Guard
After=network-online.target vnstat.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/tune-bandwidth-guard
Restart=always
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF_BW_UNIT
    enable_start_service tune-bandwidth-guard.service || return 1
    service_logs_hint tune-bandwidth-guard.service
}

write_cpu_guard_script() {
    write_file "${BIN_DIR}/tune-cpu-guard" 0755 <<'EOF_CPU_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

CONFIG_FILE="/etc/tune/cpu-guard.env"
[[ -r "$CONFIG_FILE" ]] || { echo "Missing config: $CONFIG_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${CPU_LIMIT_PERCENT:?missing CPU_LIMIT_PERCENT}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-10}"
REQUIRED_SAMPLES="${REQUIRED_SAMPLES:-180}"

log_msg() {
    local priority="$1"
    shift
    if command -v systemd-cat >/dev/null 2>&1; then
        printf '%s\n' "$*" | systemd-cat -t tune-cpu-guard -p "$priority" || true
    fi
    printf '%s [%s] %s\n' "$(date -Is)" "$priority" "$*"
}

read_cpu_totals() {
    awk '/^cpu / {
        idle=$5
        total=0
        for (i=2; i<=NF; i++) total += $i
        print idle, total
    }' /proc/stat
}

ge_float() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'
}

read -r prev_idle prev_total < <(read_cpu_totals)
excess_samples=0

while true; do
    sleep "$SAMPLE_INTERVAL_SECONDS"
    read -r idle total < <(read_cpu_totals)
    delta_idle=$((idle - prev_idle))
    delta_total=$((total - prev_total))
    prev_idle="$idle"
    prev_total="$total"

    if (( delta_total <= 0 )); then
        continue
    fi

    usage="$(awk -v di="$delta_idle" -v dt="$delta_total" 'BEGIN { printf "%.2f", (1 - di / dt) * 100 }')"
    if ge_float "$usage" "$CPU_LIMIT_PERCENT"; then
        excess_samples=$((excess_samples + 1))
    else
        excess_samples=0
    fi

    if (( excess_samples >= REQUIRED_SAMPLES )); then
        log_msg crit "CPU usage stayed above ${CPU_LIMIT_PERCENT}% for $((SAMPLE_INTERVAL_SECONDS * REQUIRED_SAMPLES)) seconds. Shutting down. Last usage: ${usage}%."
        shutdown -h now "Sustained CPU usage limit exceeded"
    fi
done
EOF_CPU_SCRIPT
}

configure_cpu_shutdown() {
    separator
    info "Configuring sustained high-CPU shutdown guard"

    local cpu_limit
    prompt_int "CPU usage threshold percent (1-100):" 1 100 cpu_limit || return 1
    require_systemd || return 1
    mkdir -p "$CONFIG_DIR" "$BIN_DIR"

    write_file "${CONFIG_DIR}/cpu-guard.env" 0600 <<EOF_CPU_ENV
CPU_LIMIT_PERCENT="${cpu_limit}"
SAMPLE_INTERVAL_SECONDS="10"
REQUIRED_SAMPLES="180"
EOF_CPU_ENV
    success "Wrote ${CONFIG_DIR}/cpu-guard.env"

    write_cpu_guard_script
    success "Installed ${BIN_DIR}/tune-cpu-guard"

    write_file /etc/systemd/system/tune-cpu-guard.service 0644 <<'EOF_CPU_UNIT'
[Unit]
Description=Tune Sustained CPU Shutdown Guard
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/tune-cpu-guard
Restart=always
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF_CPU_UNIT
    enable_start_service tune-cpu-guard.service || return 1
    service_logs_hint tune-cpu-guard.service
}

write_ddos_guard_script() {
    write_file "${BIN_DIR}/tune-ddos-guard" 0755 <<'EOF_DDOS_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

CONFIG_FILE="/etc/tune/ddos-guard.env"
[[ -r "$CONFIG_FILE" ]] || { echo "Missing config: $CONFIG_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${INTERFACE:?missing INTERFACE}"
: "${SPEED_LIMIT_MBPS:?missing SPEED_LIMIT_MBPS}"
: "${PACKET_LIMIT_PPS:?missing PACKET_LIMIT_PPS}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-30}"
REQUIRED_SAMPLES="${REQUIRED_SAMPLES:-20}"
BYTE_LIMIT=$((SPEED_LIMIT_MBPS * 1000 * 1000 / 8))

log_msg() {
    local priority="$1"
    shift
    if command -v systemd-cat >/dev/null 2>&1; then
        printf '%s\n' "$*" | systemd-cat -t tune-ddos-guard -p "$priority" || true
    fi
    printf '%s [%s] %s\n' "$(date -Is)" "$priority" "$*"
}

excess_samples=0
while true; do
    if ! json="$(vnstat -tr "$SAMPLE_SECONDS" -i "$INTERFACE" --json 2>&1)"; then
        log_msg warning "vnStat traffic sample failed for ${INTERFACE}: ${json}"
        sleep 5
        continue
    fi

    byte_rate="$(jq -r '(.rx.bytespersecond // 0) + (.tx.bytespersecond // 0)' <<<"$json")"
    packet_rate="$(jq -r '(.rx.packetspersecond // 0) + (.tx.packetspersecond // 0)' <<<"$json")"

    if [[ ! "$byte_rate" =~ ^[0-9]+$ || ! "$packet_rate" =~ ^[0-9]+$ ]]; then
        log_msg warning "Unexpected vnStat JSON values: byte_rate=${byte_rate}, packet_rate=${packet_rate}"
        sleep 5
        continue
    fi

    if (( byte_rate > BYTE_LIMIT || packet_rate > PACKET_LIMIT_PPS )); then
        excess_samples=$((excess_samples + 1))
    else
        excess_samples=0
    fi

    if (( excess_samples >= REQUIRED_SAMPLES )); then
        log_msg crit "Traffic stayed above threshold for $((SAMPLE_SECONDS * REQUIRED_SAMPLES)) seconds. byte_rate=${byte_rate}B/s limit=${BYTE_LIMIT}B/s packet_rate=${packet_rate}pps limit=${PACKET_LIMIT_PPS}pps. Shutting down."
        shutdown -h now "Traffic spike threshold exceeded"
    fi
done
EOF_DDOS_SCRIPT
}

configure_ddos_shutdown() {
    separator
    info "Configuring traffic spike shutdown guard"

    local speed_limit packet_limit
    prompt_int "Traffic threshold in Mbps:" 1 10000000 speed_limit || return 1
    prompt_int "Packet threshold in packets per second:" 1 100000000 packet_limit || return 1

    if [[ -z "$PRIMARY_IFACE" ]]; then
        error "No primary network interface detected."
        return 1
    fi

    ensure_packages vnstat jq || return 1
    require_systemd || return 1
    mkdir -p "$CONFIG_DIR" "$BIN_DIR"

    if systemctl list-unit-files vnstat.service >/dev/null 2>&1; then
        run_cmd "Enable vnStat service" systemctl enable --now vnstat.service || return 1
    fi
    run_shell "Initialize vnStat database for ${PRIMARY_IFACE}" "vnstat --add -i '$PRIMARY_IFACE' >/dev/null 2>&1 || true" || return 1

    write_file "${CONFIG_DIR}/ddos-guard.env" 0600 <<EOF_DDOS_ENV
INTERFACE="${PRIMARY_IFACE}"
SPEED_LIMIT_MBPS="${speed_limit}"
PACKET_LIMIT_PPS="${packet_limit}"
SAMPLE_SECONDS="30"
REQUIRED_SAMPLES="20"
EOF_DDOS_ENV
    success "Wrote ${CONFIG_DIR}/ddos-guard.env"

    write_ddos_guard_script
    success "Installed ${BIN_DIR}/tune-ddos-guard"

    write_file /etc/systemd/system/tune-ddos-guard.service 0644 <<'EOF_DDOS_UNIT'
[Unit]
Description=Tune Traffic Spike Shutdown Guard
After=network-online.target vnstat.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/tune-ddos-guard
Restart=always
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF_DDOS_UNIT
    enable_start_service tune-ddos-guard.service || return 1
    service_logs_hint tune-ddos-guard.service
}

sshd_binary() {
    mkdir -p /run/sshd 2>/dev/null || true
    if command_exists sshd; then
        command -v sshd
    elif [[ -x /usr/sbin/sshd ]]; then
        printf '%s\n' /usr/sbin/sshd
    else
        return 1
    fi
}
ensure_sshd_include() {
    mkdir -p "$SSHD_DROPIN_DIR"
    chmod 0755 "$SSHD_DROPIN_DIR"

    if [[ ! -f "$SSHD_CONFIG" ]]; then
        error "Missing ${SSHD_CONFIG}. Is openssh-server installed?"
        return 1
    fi

    if ! grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_CONFIG"; then
        backup_file "$SSHD_CONFIG" || return 1
        if [[ "$DRY_RUN" -eq 1 ]]; then
            info "DRY-RUN: would insert Include /etc/ssh/sshd_config.d/*.conf at top of ${SSHD_CONFIG}"
        else
            local tmp
            tmp="$(mktemp)"
            {
                printf '%s\n' 'Include /etc/ssh/sshd_config.d/*.conf'
                cat "$SSHD_CONFIG"
            } > "$tmp"
            install -o root -g root -m 0644 "$tmp" "$SSHD_CONFIG"
            rm -f "$tmp"
        fi
    fi
}

get_sshd_ports() {
    local bin
    bin="$(sshd_binary)" || return 1
    "$bin" -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -nu
}

validate_sshd_config() {
    local bin
    bin="$(sshd_binary)" || return 1
    run_cmd "Validate SSH server configuration" "$bin" -t
}

reload_ssh() {
    if systemd_available; then
        run_cmd "Reload SSH service" systemctl reload "$SSH_SERVICE" || run_cmd "Restart SSH service" systemctl restart "$SSH_SERVICE"
    else
        run_cmd "Reload SSH service" service ssh reload || run_cmd "Restart SSH service" service ssh restart
    fi
}

write_sshd_dropin() {
    local port="$1"
    local mode="${2:-port_only}"
    mkdir -p "$SSHD_DROPIN_DIR"

    if [[ "$mode" == "key_only" ]]; then
        write_file "$SSHD_DROPIN" 0644 <<EOF_SSH_DROPIN
# Managed by tune.sh. Generated ${RUN_ID}.
# Validate with: sshd -t
Port ${port}
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding yes
AllowTcpForwarding yes
EOF_SSH_DROPIN
    else
        write_file "$SSHD_DROPIN" 0644 <<EOF_SSH_DROPIN
# Managed by tune.sh. Generated ${RUN_ID}.
# Validate with: sshd -t
Port ${port}
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding yes
AllowTcpForwarding yes
EOF_SSH_DROPIN
    fi
}
comment_global_port_directives_in_sshd_config() {
    if [[ ! -f "$SSHD_CONFIG" ]]; then
        return 0
    fi
    backup_file "$SSHD_CONFIG" || return 1
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "DRY-RUN: would comment global Port directives in ${SSHD_CONFIG}"
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    awk '
        BEGIN { in_match = 0 }
        /^[[:space:]]*Match[[:space:]]/ { in_match = 1 }
        !in_match && /^[[:space:]]*Port[[:space:]]+[0-9]+/ {
            print "# Managed by tune.sh: disabled because Port is set in /etc/ssh/sshd_config.d/99-tune.conf"
            print "#" $0
            next
        }
        { print }
    ' "$SSHD_CONFIG" > "$tmp"
    install -o root -g root -m 0644 "$tmp" "$SSHD_CONFIG"
    rm -f "$tmp"
}

open_ufw_port_if_active() {
    local port="$1"
    if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
        run_cmd "Allow SSH port ${port}/tcp in UFW" ufw allow "${port}/tcp" || return 1
    fi
}

configure_fail2ban() {
    info "Installing and configuring fail2ban for SSH"
    ensure_packages fail2ban nftables || return 1
    require_systemd || return 1

    local ports port_csv
    ports="$(get_sshd_ports 2>/dev/null | paste -sd, -)"
    port_csv="${ports:-ssh}"
    mkdir -p /etc/fail2ban/jail.d

    write_file /etc/fail2ban/jail.d/sshd-tune.local 0644 <<EOF_F2B
[sshd]
enabled = true
mode = aggressive
port = ${port_csv}
backend = systemd
maxretry = 5
findtime = 1h
bantime = 1d
EOF_F2B
    success "Wrote /etc/fail2ban/jail.d/sshd-tune.local"

    run_cmd "Restart fail2ban" systemctl restart fail2ban.service || {
        service_logs_hint fail2ban.service
        return 1
    }
    run_cmd "Check fail2ban status" wait_for_fail2ban 30 1 || {
        service_logs_hint fail2ban.service
        return 1
    }
}

configure_ssh_security() {
    separator
    info "Configuring SSH hardening"

    ensure_packages openssh-server || return 1
    require_systemd || return 1
    ensure_sshd_include || return 1

    local new_ssh_port
    prompt_int "New SSH port (1-65535):" 1 65535 new_ssh_port || return 1

    if command_exists ss && ss -tln 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${new_ssh_port}$"; then
        warn "Port ${new_ssh_port} already appears to be listening. SSH may already use it, or another service may conflict."
    fi

    open_ufw_port_if_active "$new_ssh_port" || return 1

    local existing_ports=()
    mapfile -t existing_ports < <(get_sshd_ports 2>/dev/null || true)
    if [[ "${#existing_ports[@]}" -eq 0 ]]; then
        existing_ports=(22)
    fi

    # Stage 1: keep current ports and add the new port, so the user can test before old ports are removed.
    local stage_file
    stage_file="$(mktemp)"
    {
        printf '# Managed by tune.sh. Temporary test config generated %s.\n' "$RUN_ID"
        for p in "${existing_ports[@]}" "$new_ssh_port"; do
            printf 'Port %s\n' "$p"
        done | awk '!seen[$0]++'
        printf '%s\n' 'PubkeyAuthentication yes'
    } > "$stage_file"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "DRY-RUN: would write temporary SSH drop-in ${SSHD_DROPIN}"
        sed 's/^/  | /' "$stage_file" || true
        rm -f "$stage_file"
    else
        install -o root -g root -m 0644 "$stage_file" "$SSHD_DROPIN"
        rm -f "$stage_file"
    fi

    validate_sshd_config || return 1
    reload_ssh || return 1

    warn "Open a second SSH session now and verify that port ${new_ssh_port} works before continuing."
    if ! prompt_yes_no "Can you log in through SSH port ${new_ssh_port}?" n; then
        warn "Keeping the existing SSH configuration. New port was not finalized."
        return 1
    fi

    comment_global_port_directives_in_sshd_config || return 1
    write_sshd_dropin "$new_ssh_port" "port_only"
    validate_sshd_config || return 1
    reload_ssh || return 1
    success "SSH now listens on port ${new_ssh_port}. Existing global Port directives were backed up/commented."

    if [[ ! -s /root/.ssh/authorized_keys ]]; then
        warn "No /root/.ssh/authorized_keys file was found. Password authentication will not be disabled automatically."
    else
        warn "Before disabling passwords, verify key login in a second SSH session."
        if prompt_yes_no "Can you log in with an SSH key?" n; then
            write_sshd_dropin "$new_ssh_port" "key_only"
            validate_sshd_config || return 1
            reload_ssh || return 1
            success "SSH password and keyboard-interactive authentication disabled. Root login is key-only/prohibit-password."
        else
            warn "Password authentication left enabled."
        fi
    fi

    configure_fail2ban || return 1
}

compute_memory_tuning() {
    local mem_size
    mem_size="$(awk '/MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)"

    rmem_default=131072
    wmem_default=131072
    swappiness=10

    if (( mem_size <= 128 )); then
        rmem_max=4194304
        wmem_max=4194304
        tcp_rmem="4096 87380 4194304"
        tcp_wmem="4096 32768 4194304"
        notsent_lowat=65536
        somaxconn=4096
        syn_backlog=2048
        netdev_backlog=1000
        dirty_bg=2097152
        dirty=8388608
        file_max=262144
    elif (( mem_size <= 256 )); then
        rmem_max=8388608
        wmem_max=8388608
        tcp_rmem="4096 131072 12582912"
        tcp_wmem="4096 65536 12582912"
        notsent_lowat=65536
        somaxconn=8192
        syn_backlog=4096
        netdev_backlog=2000
        dirty_bg=4194304
        dirty=16777216
        file_max=524288
    elif (( mem_size <= 512 )); then
        rmem_default=262144
        wmem_default=262144
        rmem_max=16777216
        wmem_max=16777216
        tcp_rmem="4096 131072 16777216"
        tcp_wmem="4096 65536 16777216"
        notsent_lowat=131072
        somaxconn=16384
        syn_backlog=8192
        netdev_backlog=4096
        dirty_bg=8388608
        dirty=33554432
        file_max=1048576
    elif (( mem_size <= 1024 )); then
        rmem_default=262144
        wmem_default=262144
        rmem_max=16777216
        wmem_max=16777216
        tcp_rmem="4096 131072 16777216"
        tcp_wmem="4096 65536 16777216"
        notsent_lowat=131072
        somaxconn=32768
        syn_backlog=16384
        netdev_backlog=8192
        dirty_bg=16777216
        dirty=67108864
        file_max=1048576
    elif (( mem_size <= 2048 )); then
        rmem_default=262144
        wmem_default=262144
        rmem_max=33554432
        wmem_max=33554432
        tcp_rmem="4096 131072 33554432"
        tcp_wmem="4096 65536 33554432"
        notsent_lowat=131072
        somaxconn=65535
        syn_backlog=32768
        netdev_backlog=16384
        dirty_bg=33554432
        dirty=134217728
        file_max=2097152
    else
        rmem_default=262144
        wmem_default=262144
        rmem_max=33554432
        wmem_max=33554432
        tcp_rmem="4096 131072 33554432"
        tcp_wmem="4096 65536 33554432"
        notsent_lowat=131072
        somaxconn=65535
        syn_backlog=32768
        netdev_backlog=32768
        dirty_bg=67108864
        dirty=268435456
        file_max=2097152
    fi
}

write_sysctl_tuning() {
    if [[ "$VIRT_KIND" == "container" ]]; then
        warn "Container detected (${VIRT_TECH}). Skipping sysctl tuning because many kernel parameters are controlled by the host."
        return 0
    fi

    install_linux_sysctl_defaults_if_needed
    compute_memory_tuning

    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true

    local congestion_control default_qdisc
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        congestion_control="bbr"
        default_qdisc="fq"
    else
        congestion_control="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)"
        default_qdisc="fq_codel"
        warn "BBR is not available in the current kernel; keeping congestion control as ${congestion_control}."
    fi

    write_file "$SYSCTL_FILE" 0644 <<EOF_SYSCTL
# Managed by tune.sh. Generated ${RUN_ID}.
# Debian 13/trixie: local sysctl settings should live in /etc/sysctl.d/*.conf.
# Lines prefixed with '-' are allowed to fail on kernels that do not expose that key.

# Socket buffers
net.core.rmem_default = ${rmem_default}
net.core.rmem_max = ${rmem_max}
net.core.wmem_default = ${wmem_default}
net.core.wmem_max = ${wmem_max}
net.ipv4.tcp_rmem = ${tcp_rmem}
net.ipv4.tcp_wmem = ${tcp_wmem}
net.ipv4.tcp_moderate_rcvbuf = 1

# TCP behavior for long-lived/high-throughput connections
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = ${notsent_lowat}
net.core.somaxconn = ${somaxconn}
net.ipv4.tcp_max_syn_backlog = ${syn_backlog}
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_abort_on_overflow = 0
net.core.netdev_max_backlog = ${netdev_backlog}
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 30

# File handle and VM writeback ceiling
fs.file-max = ${file_max}
vm.dirty_background_bytes = ${dirty_bg}
vm.dirty_bytes = ${dirty}
vm.swappiness = ${swappiness}

# Safer baseline network hardening for non-router servers
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Local kernel hardening. Optional keys may not exist on every kernel.
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
-fs.protected_fifos = 2
-fs.protected_regular = 2
kernel.dmesg_restrict = 1
-kernel.kptr_restrict = 2
-kernel.unprivileged_bpf_disabled = 1
-net.core.bpf_jit_harden = 2

# Queue discipline and congestion control
net.core.default_qdisc = ${default_qdisc}
net.ipv4.tcp_congestion_control = ${congestion_control}
EOF_SYSCTL
    success "Wrote ${SYSCTL_FILE}"

    run_cmd "Apply sysctl tuning from ${SYSCTL_FILE}" sysctl -e -p "$SYSCTL_FILE" || return 1
}

write_limits_tuning() {
    write_file "$LIMITS_FILE" 0644 <<'EOF_LIMITS'
# Managed by tune.sh.
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF_LIMITS
    success "Wrote ${LIMITS_FILE}"

    mkdir -p "$SYSTEMD_LIMITS_DIR"
    write_file "$SYSTEMD_LIMITS_FILE" 0644 <<'EOF_SYSTEMD_LIMITS'
# Managed by tune.sh.
[Manager]
DefaultLimitNOFILE=1048576
EOF_SYSTEMD_LIMITS
    success "Wrote ${SYSTEMD_LIMITS_FILE}. A reboot or systemd daemon-reexec is required for manager-wide defaults."
}

write_netdev_boot_helper() {
    write_file "${BIN_DIR}/tune-boot-apply" 0755 <<'EOF_NETDEV'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

log_msg() {
    local priority="$1"
    shift
    if command -v systemd-cat >/dev/null 2>&1; then
        printf '%s\n' "$*" | systemd-cat -t tune-boot-apply -p "$priority" || true
    fi
    printf '%s [%s] %s\n' "$(date -Is)" "$priority" "$*"
}

primary_iface() {
    ip -o -4 route show to default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' | cut -d'@' -f1
}

virt_kind() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        if systemd-detect-virt --container >/dev/null 2>&1; then
            printf 'container\n'
        elif systemd-detect-virt --vm >/dev/null 2>&1; then
            printf 'vm\n'
        else
            printf 'none\n'
        fi
    else
        printf 'unknown\n'
    fi
}

iface="$(primary_iface)"
if [[ -z "$iface" ]]; then
    log_msg warning "No default-route network interface detected."
    exit 0
fi

kind="$(virt_kind)"

if command -v ethtool >/dev/null 2>&1; then
    if [[ "$kind" == "none" ]]; then
        ethtool -G "$iface" rx 1024 >/dev/null 2>&1 || log_msg warning "Could not set RX ring buffer on ${iface}; driver may not support it."
        ethtool -G "$iface" tx 2048 >/dev/null 2>&1 || log_msg warning "Could not set TX ring buffer on ${iface}; driver may not support it."
    else
        ethtool -K "$iface" tso off gso off gro off >/dev/null 2>&1 || log_msg warning "Could not disable offloads on ${iface}; hypervisor/driver may not support it."
    fi
fi

if [[ "$kind" != "container" ]]; then
    ip link set dev "$iface" txqueuelen 10000 >/dev/null 2>&1 || log_msg warning "Could not set txqueuelen on ${iface}."
    default_route="$(ip -o -4 route show to default | head -n 1 || true)"
    if [[ -n "$default_route" ]]; then
        # The route may already contain metrics/options. Preserve the route and add init windows.
        IFS=' ' read -r -a route_parts <<< "$default_route"
        ip route change "${route_parts[@]}" initcwnd 100 initrwnd 100 >/dev/null 2>&1 || log_msg warning "Could not set initial congestion window on default route."
    fi
fi
EOF_NETDEV

    write_file /etc/systemd/system/tune-boot-apply.service 0644 <<'EOF_NETDEV_UNIT'
[Unit]
Description=Tune Boot-time Network Device Tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tune-boot-apply
RemainAfterExit=yes
CapabilityBoundingSet=CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_ADMIN
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF_NETDEV_UNIT
}

apply_netdev_tuning_now() {
    if [[ -z "$PRIMARY_IFACE" ]]; then
        warn "No primary interface detected. Skipping netdev tuning."
        return 0
    fi

    ensure_packages ethtool || return 1

    if [[ "$VIRT_KIND" == "none" ]]; then
        run_cmd "Set RX ring buffer on ${PRIMARY_IFACE}" ethtool -G "$PRIMARY_IFACE" rx 1024 || warn "RX ring tuning skipped; unsupported by this NIC/driver."
        run_cmd "Set TX ring buffer on ${PRIMARY_IFACE}" ethtool -G "$PRIMARY_IFACE" tx 2048 || warn "TX ring tuning skipped; unsupported by this NIC/driver."
    else
        run_cmd "Disable TSO/GSO/GRO offloads on ${PRIMARY_IFACE}" ethtool -K "$PRIMARY_IFACE" tso off gso off gro off || warn "Offload tuning skipped; unsupported by this NIC/driver/hypervisor."
    fi

    if [[ "$VIRT_KIND" != "container" ]]; then
        run_cmd "Set txqueuelen on ${PRIMARY_IFACE}" ip link set dev "$PRIMARY_IFACE" txqueuelen 10000 || warn "txqueuelen tuning skipped."
        run_shell "Set initial congestion window on default route" \
            'route="$(ip -o -4 route show to default | head -n 1 || true)"; if [[ -n "$route" ]]; then IFS=" " read -r -a route_parts <<< "$route"; ip route change "${route_parts[@]}" initcwnd 100 initrwnd 100 || true; fi' || warn "Initial congestion window tuning skipped."
    else
        warn "Container detected; skipping link queue and route tuning."
    fi
}

apply_system_tuning() {
    separator
    info "Applying system tuning"

    write_limits_tuning
    write_sysctl_tuning || return 1
    apply_netdev_tuning_now || return 1

    if systemd_available; then
        write_netdev_boot_helper
        success "Installed ${BIN_DIR}/tune-boot-apply"
        enable_start_service tune-boot-apply.service || return 1
    fi

    success "System tuning completed. Some limits require a reboot or a new login session to fully apply."
}

run_action() {
    local label="$1"
    local function_name="$2"
    CURRENT_ACTION_LOGS=()
    LAST_FAILURE_CAUSE=""

    info "Action: ${label}"
    if "$function_name"; then
        record_summary "$label" "SUCCESS" "$(join_by ', ' "${CURRENT_ACTION_LOGS[@]}")"
        status_ok "$label"
        return 0
    fi

    record_summary "$label" "FAILED" "$(join_by ', ' "${CURRENT_ACTION_LOGS[@]}")"
    status_failed "$label"
    [[ -n "$LAST_FAILURE_CAUSE" ]] && error "Likely cause: ${LAST_FAILURE_CAUSE}"
    return 1
}

add_short_action() {
    case "$1" in
        a) ACTIONS+=("Auto updates:configure_auto_updates") ;;
        b) ACTIONS+=("Bandwidth guard:configure_bandwidth_limit") ;;
        c) ACTIONS+=("CPU guard:configure_cpu_shutdown") ;;
        d) ACTIONS+=("Traffic spike guard:configure_ddos_shutdown") ;;
        s) ACTIONS+=("SSH security:configure_ssh_security") ;;
        t) ACTIONS+=("System tuning:apply_system_tuning") ;;
        h) usage; exit 0 ;;
        *) error "Invalid option: -$1"; usage; exit 1 ;;
    esac
}

parse_args() {
    if [[ "$#" -eq 0 ]]; then
        usage
        exit 1
    fi

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -a|--auto-updates) ACTIONS+=("Auto updates:configure_auto_updates") ;;
            -b|--bandwidth-limit) ACTIONS+=("Bandwidth guard:configure_bandwidth_limit") ;;
            -c|--cpu-shutdown) ACTIONS+=("CPU guard:configure_cpu_shutdown") ;;
            -d|--ddos-shutdown) ACTIONS+=("Traffic spike guard:configure_ddos_shutdown") ;;
            -s|--ssh-security) ACTIONS+=("SSH security:configure_ssh_security") ;;
            -t|--tune) ACTIONS+=("System tuning:apply_system_tuning") ;;
            --lang)
                shift
                if [[ "$#" -eq 0 ]]; then
                    error "Missing value for --lang. Use en or zh-CN."
                    usage
                    exit 1
                fi
                set_language "$1" || { usage; exit 1; }
                ;;
            --lang=*) set_language "${1#*=}" || { usage; exit 1; } ;;
            --zh|--zh-cn|--zh-CN) set_language zh-CN ;;
            --en|--english) set_language en ;;
            -y|--yes) ASSUME_YES=1 ;;
            --dry-run) DRY_RUN=1 ;;
            -v|--verbose) VERBOSE=1 ;;
            -h|--help) usage; exit 0 ;;
            --) shift; break ;;
            -*)
                if [[ "$1" =~ ^-[abcdsth]+$ && "${#1}" -gt 2 ]]; then
                    local chars="${1#-}"
                    local i
                    for ((i=0; i<${#chars}; i++)); do
                        add_short_action "${chars:i:1}"
                    done
                else
                    error "Invalid option: $1"
                    usage
                    exit 1
                fi
                ;;
            *)
                error "Unexpected argument: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done

    if [[ "${#ACTIONS[@]}" -eq 0 ]]; then
        usage
        exit 1
    fi
}

print_summary() {
    if [[ "$VERBOSE" -ne 1 ]]; then
        if [[ "${LANGUAGE:-en}" == "zh-CN" ]]; then
            printf '日志：%s\n' "$RUN_LOG"
        else
            printf 'Log: %s\n' "$RUN_LOG"
        fi
        return 0
    fi

    separator
    say "$C_BOLD" "$(tr_text "Run summary")"
    if [[ "${LANGUAGE:-en}" == "zh-CN" ]]; then
        printf '主日志：%s\n\n' "$RUN_LOG"
    else
        printf 'Main log: %s\n\n' "$RUN_LOG"
    fi

    local i result_color result_text label_text
    for i in "${!SUMMARY_LABELS[@]}"; do
        if [[ "${SUMMARY_RESULTS[$i]}" == "SUCCESS" ]]; then
            result_color="$C_OK"
        else
            result_color="$C_ERR"
        fi
        result_text="$(tr_text "${SUMMARY_RESULTS[$i]}")"
        label_text="$(tr_text "${SUMMARY_LABELS[$i]}")"
        printf '%b%-24s%b %s\n' "$result_color" "$result_text" "$C_RESET" "$label_text"
        if [[ -n "${SUMMARY_LOGS[$i]}" ]]; then
            if [[ "${LANGUAGE:-en}" == "zh-CN" ]]; then
                printf '  日志：%s\n' "${SUMMARY_LOGS[$i]}"
            else
                printf '  Logs: %s\n' "${SUMMARY_LOGS[$i]}"
            fi
        fi
    done
}

main() {
    set_language "$LANGUAGE" || exit 1
    preparse_language "$@" || exit 1
    parse_args "$@"
    require_root
    mkdir -p "$LOG_DIR" "$CONFIG_DIR" "$BIN_DIR"
    chmod 0700 "$LOG_DIR"
    chmod 0755 "$CONFIG_DIR" "$BIN_DIR"
    touch "$RUN_LOG"
    chmod 0600 "$RUN_LOG"

    info "Starting ${SCRIPT_NAME}. Main log: ${RUN_LOG}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "Dry-run mode is enabled; commands are logged but not executed."
    fi

    detect_system

    local overall=0
    local entry label function_name
    for entry in "${ACTIONS[@]}"; do
        label="${entry%%:*}"
        function_name="${entry#*:}"
        if ! run_action "$label" "$function_name"; then
            overall=1
        fi
    done

    print_summary
    exit "$overall"
}

main "$@"
