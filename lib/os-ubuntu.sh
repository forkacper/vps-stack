#!/usr/bin/env bash
# Ubuntu implementation of the OS layer (see lib/os-detect.sh for the
# interface). Written for 24.04 and 26.04. Anything that may differ between
# releases is detected at run time instead of being assumed.
#
# Requires lib/common.sh and the OS_* variables set by os_detect.

if [[ -n "${VPS_STACK_OS_UBUNTU_LOADED:-}" ]]; then
    return 0
fi
VPS_STACK_OS_UBUNTU_LOADED=1

DOCKER_REPO_URL="https://download.docker.com/linux/ubuntu"
DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
DOCKER_SOURCES_LIST="/etc/apt/sources.list.d/docker.list"

# How long to wait for apt and dpkg locks held by another apt process, e.g.
# apt-daily or unattended-upgrades, which run on a fresh server shortly after
# boot. Overridable only so the waiting can be tested without minutes of it.
APT_LOCK_TIMEOUT="${VPS_STACK_APT_LOCK_TIMEOUT:-600}"
APT_LOCK_RETRY_DELAY="${VPS_STACK_APT_LOCK_RETRY_DELAY:-10}"

# Both releases report `untested` until the repository owner records a real
# test run in README.md. Switch a release to `ok` only together with that
# entry.
os_check_supported() {
    case "${OS_VERSION_ID}" in
        24.04 | 26.04) printf 'untested\n' ;;
        *) printf 'unsupported\n' ;;
    esac
}

# _os_apt <apt-get arguments...>: apt-get that waits for locks held by
# another apt process instead of failing at once.
#
# Two mechanisms, because apt treats its locks differently (checked in the
# apt 2.7.14 sources, and observed with apt 2.8.3 on Ubuntu 24.04):
# DPkg::Lock::Timeout makes apt wait for the dpkg locks
# (/var/lib/dpkg/lock-frontend and lock), but `apt-get update` takes
# /var/lib/apt/lists/lock without any timeout and fails at once with "Could
# not get lock". That failure is retried here until APT_LOCK_TIMEOUT runs
# out. apt runs with LC_ALL=C, so that the message is
# recognised whatever the server's locale.
_os_apt() {
    local log code remaining started="${SECONDS}"
    if is_dry_run; then
        run env DEBIAN_FRONTEND=noninteractive apt-get -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" "$@"
        return 0
    fi
    log="$(mktemp)" || return 1
    while true; do
        remaining=$((APT_LOCK_TIMEOUT - (SECONDS - started)))
        [[ "${remaining}" -ge 1 ]] || remaining=1
        code=0
        # stdout goes where the caller sends it; stderr is shown and kept in
        # the log, to look for the lock message.
        { env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get -o "DPkg::Lock::Timeout=${remaining}" "$@" 2>&1 1>&3 |
            tee "${log}" >&2; } 3>&1 || code=$?
        if [[ "${code}" -eq 0 ]]; then
            rm -f "${log}"
            return 0
        fi
        if ! grep -q 'Could not get lock' "${log}"; then
            rm -f "${log}"
            return "${code}"
        fi
        if [[ $((SECONDS - started)) -ge "${APT_LOCK_TIMEOUT}" ]]; then
            rm -f "${log}"
            log_error "apt is still locked after ${APT_LOCK_TIMEOUT} s: another apt process is probably still running (automatic updates on a fresh server). Check: ps -o pid,etime,cmd -C apt-get,apt,unattended-upgr"
            return "${code}"
        fi
        log_warn "apt is busy (another apt process, e.g. automatic updates); waiting ${APT_LOCK_RETRY_DELAY} s and trying again..."
        sleep "${APT_LOCK_RETRY_DELAY}"
    done
}

os_pkg_update() {
    _os_apt update
}

os_pkg_install() {
    _os_apt install -y "$@"
}

_os_pkg_installed() {
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == "installed" ]]
}

# os_docker_repo_available: does Docker publish packages for this codename?
os_docker_repo_available() {
    [[ -n "${OS_CODENAME}" ]] || return 1
    curl -fsI --max-time 15 "${DOCKER_REPO_URL}/dists/${OS_CODENAME}/Release" >/dev/null 2>&1
}

# os_docker_repo_setup: returns 2 when Docker has no repository for this
# release, so the caller can stop and point at --docker-fallback.
os_docker_repo_setup() {
    local arch
    if ! have_cmd curl; then
        # Only possible in --dry-run on a fresh system: curl is installed by
        # the package step, which a dry run does not execute.
        is_dry_run || die "Command curl not found."
        log_dry "check ${DOCKER_REPO_URL}/dists/${OS_CODENAME}/Release and configure the Docker repository"
        return 0
    fi
    if ! os_docker_repo_available; then
        return 2
    fi
    arch="$(dpkg --print-architecture)"
    run install -d -m 755 /etc/apt/keyrings
    if [[ ! -s "${DOCKER_KEYRING}" ]]; then
        run curl -fsSL "${DOCKER_REPO_URL}/gpg" -o "${DOCKER_KEYRING}"
        run chmod a+r "${DOCKER_KEYRING}"
    fi
    write_file "${DOCKER_SOURCES_LIST}" 644 \
        <<<"deb [arch=${arch} signed-by=${DOCKER_KEYRING}] ${DOCKER_REPO_URL} ${OS_CODENAME} stable"
    os_pkg_update
}

# os_docker_conflicts <official|fallback>: print installed packages that
# conflict with the chosen installation method.
os_docker_conflicts() {
    local mode="$1" pkg candidates
    if [[ "${mode}" == "official" ]]; then
        candidates="docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc"
    else
        candidates="docker-ce docker-ce-cli containerd.io docker-compose podman-docker"
    fi
    for pkg in ${candidates}; do
        if _os_pkg_installed "${pkg}"; then
            printf '%s\n' "${pkg}"
        fi
    done
}

os_docker_remove_packages() {
    _os_apt remove -y "$@"
}

# os_docker_install <official|fallback>
os_docker_install() {
    case "$1" in
        official)
            os_pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        fallback)
            os_pkg_install docker.io docker-compose-v2
            ;;
        *)
            die "os_docker_install: unknown mode '$1'."
            ;;
    esac
}

# os_unattended_upgrades_setup <true|false>
# Only options are written. The list of allowed origins stays the
# distribution's own (50unattended-upgrades): redefining it here would
# append duplicates, and its exact form is release specific.
os_unattended_upgrades_setup() {
    local auto_reboot="$1" origins content
    content='APT::Periodic::Update-Package-Lists "1";'$'\n''APT::Periodic::Unattended-Upgrade "1";'
    write_file /etc/apt/apt.conf.d/20auto-upgrades 644 <<<"${content}"
    content="$(render_template "${REPO_ROOT}/templates/unattended-upgrades.conf" "AUTO_REBOOT=${auto_reboot}")"
    write_file /etc/apt/apt.conf.d/52vps-stack-unattended-upgrades 644 <<<"${content}"

    if is_dry_run; then
        return 0
    fi
    origins="$(apt-config dump 2>/dev/null | grep -E '^Unattended-Upgrade::(Allowed-Origins|Origins-Pattern)::' || true)"
    if [[ "${origins}" != *security* ]]; then
        log_warn "No security update origin found in the unattended-upgrades configuration."
        log_warn "Check /etc/apt/apt.conf.d/50unattended-upgrades (the Allowed-Origins section)."
        return 3
    fi
}

# os_ssh_mode: `socket` when sshd is started through ssh.socket.
os_ssh_mode() {
    if systemctl is-active --quiet ssh.socket 2>/dev/null ||
        systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        printf 'socket\n'
    else
        printf 'service\n'
    fi
}

# os_ssh_service: name of the sshd service unit.
os_ssh_service() {
    local unit
    for unit in ssh sshd; do
        if systemctl cat "${unit}.service" >/dev/null 2>&1; then
            printf '%s\n' "${unit}"
            return 0
        fi
    done
    return 1
}

# os_ssh_ports: ports sshd listens on right now, one per line.
# With socket activation the port comes from the socket unit and `Port` in
# sshd_config is not what decides, so the two cases are read differently.
os_ssh_ports() {
    if [[ "$(os_ssh_mode)" == "socket" ]]; then
        systemctl show ssh.socket -p Listen 2>/dev/null |
            grep -oE ':[0-9]+ \(Stream\)' | grep -oE '[0-9]+' | sort -un
    else
        sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -un
    fi
}

os_fail2ban_backend() {
    printf 'systemd\n'
}
