#!/usr/bin/env bash
# OS detection. Loads the matching lib/os-<id>.sh, which implements the
# common interface:
#
#   os_check_supported            print: ok | untested | planned | unsupported
#   os_pkg_update                 refresh the package index
#   os_pkg_install <pkg...>       non-interactive install
#   os_docker_repo_setup          configure Docker's package repo (verified)
#   os_docker_install <mode>      install Docker (official | fallback)
#   os_docker_conflicts <mode>    print installed packages that conflict
#   os_unattended_upgrades_setup <true|false>
#   os_ssh_mode                   print: socket | service
#   os_ssh_service                print the sshd unit name (ssh | sshd)
#   os_ssh_ports                  print the ports sshd listens on
#   os_fail2ban_backend           print the fail2ban backend
#
# Requires lib/common.sh.

if [[ -n "${VPS_STACK_OS_DETECT_LOADED:-}" ]]; then
    return 0
fi
VPS_STACK_OS_DETECT_LOADED=1

OS_RELEASE_FILE="${VPS_STACK_OS_RELEASE_FILE:-/etc/os-release}"
OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""
OS_PRETTY_NAME=""

# _os_release_field <KEY>: value of one os-release field, quotes removed.
_os_release_field() {
    awk -F= -v key="$1" '
        $1 == key {
            value = substr($0, length(key) + 2)
            gsub(/^["\047]|["\047]$/, "", value)
            print value
            exit
        }' "${OS_RELEASE_FILE}"
}

# os_detect: read /etc/os-release and load the OS layer.
os_detect() {
    [[ -r "${OS_RELEASE_FILE}" ]] || die "${OS_RELEASE_FILE} not found: cannot detect the system."

    # Read field by field, never sourced.
    OS_ID="$(_os_release_field ID)"
    OS_VERSION_ID="$(_os_release_field VERSION_ID)"
    OS_CODENAME="$(_os_release_field VERSION_CODENAME)"
    OS_PRETTY_NAME="$(_os_release_field PRETTY_NAME)"
    OS_PRETTY_NAME="${OS_PRETTY_NAME:-${OS_ID} ${OS_VERSION_ID}}"

    case "${OS_ID}" in
        ubuntu)
            # shellcheck source=lib/os-ubuntu.sh
            source "${REPO_ROOT}/lib/os-ubuntu.sh"
            ;;
        debian)
            # shellcheck source=lib/os-debian.sh
            source "${REPO_ROOT}/lib/os-debian.sh"
            ;;
        *)
            # shellcheck disable=SC2317,SC2329  # called by os_require_supported
            os_check_supported() { printf 'unsupported\n'; }
            ;;
    esac
}

# os_require_supported: stop unless the detected system may be provisioned.
os_require_supported() {
    local status
    status="$(os_check_supported)"
    case "${status}" in
        ok)
            log_ok "System: ${OS_PRETTY_NAME}"
            ;;
        untested)
            log_warn "System: ${OS_PRETTY_NAME}. vps-stack has not been confirmed on this system yet (UNTESTED)."
            log_warn "Do the first run on a machine you can throw away. Have a snapshot and access to your provider's rescue console."
            if [[ "${ASSUME_YES}" != "1" ]]; then
                confirm "Continue at your own risk?" || die "Aborted at the user's request."
            fi
            ;;
        planned)
            die "System ${OS_PRETTY_NAME}: support is planned, not implemented. Ubuntu 24.04 and 26.04 are supported."
            ;;
        *)
            die "System ${OS_PRETTY_NAME} (${OS_ID}:${OS_VERSION_ID}) is not supported. Ubuntu 24.04 and 26.04 are supported."
            ;;
    esac
}
