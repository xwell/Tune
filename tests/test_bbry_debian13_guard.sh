#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TEST_TMP="$(mktemp -d -t tune-bbry-test.XXXXXX)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

export LOG_DIR="${TEST_TMP}/log"
# shellcheck source=../tune.sh
source "${REPO_DIR}/tune.sh"

fail_test() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    [[ "$haystack" == *"$needle"* ]] || fail_test "${label}: missing '${needle}'"
}

run_expect_failure() {
    local __output_var="$1"
    shift
    local command_status command_output

    set +e
    command_output="$("$@" 2>&1)"
    command_status=$?
    set -e
    [[ "$command_status" -ne 0 ]] || fail_test "command unexpectedly succeeded: $*"
    printf -v "$__output_var" '%s' "$command_output"
}

OS_ID="debian"
OS_MAJOR="13"
VIRT_KIND="vm"
LANGUAGE="en"

guard_output=""
run_expect_failure guard_output resolve_bbr_source bbry
assert_contains "$guard_output" "BBRy is not supported on Debian 13" "English Debian 13 guard"
assert_contains "$guard_output" "install BBRx or BBRz instead" "English alternatives"

install_marker="${TEST_TMP}/ensure-packages-called"
ensure_packages() {
    touch "$install_marker"
}
run_expect_failure guard_output install_bbry
[[ ! -e "$install_marker" ]] || fail_test "package installation was reached before the BBRy guard"

LANGUAGE="zh-CN"
run_expect_failure guard_output resolve_bbr_source bbry
assert_contains "$guard_output" "Debian 13 不支持 BBRy" "Chinese Debian 13 guard"
assert_contains "$guard_output" "请改为安装 BBRx 或 BBRz" "Chinese alternatives"

LANGUAGE="en"
OS_MAJOR="12"
debian_source="$(resolve_bbr_source bbry)"
assert_contains "$debian_source" $'\ttcp_bbry.c\t' "Debian 12 BBRy source"

OS_ID="ubuntu"
OS_MAJOR="26"
ubuntu_source="$(resolve_bbr_source bbry)"
assert_contains "$ubuntu_source" $'\ttcp_bbry.c\t' "Ubuntu BBRy source"

OS_ID="debian"
OS_MAJOR="13"
assert_contains "$(resolve_bbr_source bbrx)" $'\ttcp_bbrx_debian13.c\t' "Debian 13 BBRx alternative"
assert_contains "$(resolve_bbr_source bbrz)" $'\ttcp_bbrz_debian13.c\t' "Debian 13 BBRz alternative"

help_output="$(bash "${REPO_DIR}/tune.sh" --help)"
assert_contains "$help_output" "not supported on Debian 13" "English help warning"

printf 'PASS: Debian 13 BBRy guard\n'
