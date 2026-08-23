#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"
TEST_TMP="$(mktemp -d -t tune-bbrv3-test.XXXXXX)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

export LOG_DIR="${TEST_TMP}/log"
# shellcheck source=../tune.sh
source "${REPO_DIR}/tune.sh"

fail_test() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local expected="$1" actual="$2" label="$3"
    [[ "$actual" == "$expected" ]] || fail_test "${label}: expected '${expected}', got '${actual}'"
}

assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    [[ "$haystack" == *"$needle"* ]] || fail_test "${label}: missing '${needle}'"
}

run_expect_failure() {
    local __status_var="$1" __output_var="$2"
    shift 2
    local command_status command_output

    set +e
    command_output="$("$@" 2>&1)"
    command_status=$?
    set -e
    [[ "$command_status" -ne 0 ]] || fail_test "command unexpectedly succeeded: $*"
    printf -v "$__status_var" '%s' "$command_status"
    printf -v "$__output_var" '%s' "$command_output"
}

assert_equal "7.0.0" "$(kernel_base_version '7.0.0-15-generic')" "Ubuntu kernel normalization"
assert_equal "6.13.0" "$(kernel_base_version '6.13-bbr3')" "two-part kernel normalization"
if kernel_base_version 'not-a-kernel' >/dev/null 2>&1; then
    fail_test "invalid kernel version was accepted"
fi

uname() {
    printf '%s\n' '6.13.7-bbr3ubuntu2604-generic+'
}

dpkg-query() {
    printf '%s\n' \
        $'install ok installed\tlinux-image-6.13.7-bbr3ubuntu2604-generic+:amd64' \
        $'install ok installed\tlinux-image-6.13.7-bbrv3-d13-arm64+:arm64' \
        $'install ok installed\tlinux-image-6.12.0-99-generic:amd64' \
        $'install ok installed\tlinux-image-7.0.0-15-generic:amd64' \
        $'deinstall ok config-files\tlinux-image-7.1.0-1-generic:amd64'
}

assert_equal "7.0.0" "$(highest_reference_kernel_version)" "highest distro kernel selection"

dpkg-query() {
    printf '%s\n' $'install ok installed\tlinux-image-6.13.7-bbrv3-d13-arm64+:arm64'
}
assert_equal "6.13.7-bbrv3-d13-arm64+" "$(installed_bbrv3_kernel)" "arm64 BBRv3 package selection"
unset -f uname dpkg-query

highest_reference_kernel_version() {
    printf '%s\n' '7.0.0'
}

DRY_RUN=1
ASSUME_YES=1
ALLOW_OLDER_BBRV3_KERNEL=0
guard_status=0
guard_output=""
run_expect_failure guard_status guard_output check_bbrv3_kernel_age
assert_contains "$guard_output" "distribution 7.0.0, payload 6.13.7" "dry-run version report"
assert_contains "$guard_output" "--yes does not bypass it" "--yes bypass prevention"

ALLOW_OLDER_BBRV3_KERNEL=1
guard_output="$(check_bbrv3_kernel_age 2>&1)"
assert_contains "$guard_output" "Explicit override accepted" "explicit override"

highest_reference_kernel_version() {
    printf '%s\n' '6.12.0'
}
ALLOW_OLDER_BBRV3_KERNEL=0
check_bbrv3_kernel_age >/dev/null 2>&1 || fail_test "newer BBRv3 payload was rejected"

ACTIONS=()
ALLOW_OLDER_BBRV3_KERNEL=0
parse_args --bbrv3 --allow-older-bbrv3-kernel
assert_equal "1" "$ALLOW_OLDER_BBRV3_KERNEL" "override option parsing"
assert_equal "BBRv3:install_bbrv3" "${ACTIONS[0]}" "BBRv3 action parsing"

highest_reference_kernel_version() {
    printf '%s\n' '7.0.0'
}
ALLOW_OLDER_BBRV3_KERNEL=0
VIRT_KIND="none"
install_marker="${TEST_TMP}/ensure-packages-called"
ensure_packages() {
    touch "$install_marker"
}
run_expect_failure guard_status guard_output install_bbrv3
[[ ! -e "$install_marker" ]] || fail_test "package installation was reached before the kernel guard"

help_output="$(bash "${REPO_DIR}/tune.sh" --help)"
assert_contains "$help_output" "--allow-older-bbrv3-kernel" "help output"

printf 'PASS: BBRv3 kernel downgrade guard\n'
