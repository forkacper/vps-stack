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

# Both releases report `untested` until the repository owner records a real
# test run in README.md. Switch a release to `ok` only together with that
# entry.
os_check_supported() {
    case "${OS_VERSION_ID}" in
        24.04 | 26.04) printf 'untested\n' ;;
        *) printf 'unsupported\n' ;;
    esac
}

os_pkg_update() {
    run env DEBIAN_FRONTEND=noninteractive apt-get update
}

os_pkg_install() {
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
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
    run env DEBIAN_FRONTEND=noninteractive apt-get remove -y "$@"
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
