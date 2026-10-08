#!/usr/bin/env bash
# Turn a fresh VPS into a hardened Docker host with a shared reverse proxy.
# Idempotent: safe to run again. See docs/quickstart.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=lib/validate.sh
source "${SCRIPT_DIR}/../lib/validate.sh"
# shellcheck source=lib/os-detect.sh
source "${SCRIPT_DIR}/../lib/os-detect.sh"

CONFIG_FILE=""
SKIP_DOCKER=0
DOCKER_FALLBACK=0
SECOND_SESSION_TESTED=0

TOTAL_STEPS=13
CURRENT_STEP=0
CURRENT_STEP_NAME=""
STOPPED_ON_PURPOSE=0

# Overridable only so the script can be exercised on small test machines.
MIN_FREE_GB="${VPS_STACK_MIN_FREE_GB:-5}"
SSHD_HARDENING_FILE="/etc/ssh/sshd_config.d/00-hardening.conf"
CLOUD_INIT_CFG_DIR="/etc/cloud/cloud.cfg.d"
CLOUD_INIT_HOSTNAME_FILE="${CLOUD_INIT_CFG_DIR}/99-vps-stack-hostname.cfg"
BASE_PACKAGES=(ca-certificates curl gnupg git ufw fail2ban unattended-upgrades cron restic jq dnsutils rsync logrotate)

usage() {
    cat <<USAGE
Usage: sudo vps-stack provision [options]

Prepares a fresh server: packages, swap, users, SSH hardening, firewall,
fail2ban, automatic updates, Docker and the shared proxy.
Running it again is safe (steps already done are skipped).

Options:
  --config <file>     configuration file (see config/stack.env.example);
                      required on the first run, later runs use
                      ${STACK_ENV_FILE}
  --dry-run           print what would be done, change nothing
  --yes               do not ask ordinary questions; does NOT skip the
                      confirmations of steps that can cut off access
                      (SSH, ufw)
  --skip-docker       skip the Docker installation and the proxy start
  --docker-fallback   install Docker from the distribution repository
                      (docker.io) when Docker publishes no packages for
                      this release
  --i-tested-second-ssh-session
                      confirms that key login and sudo were checked in a
                      SECOND SSH session; replaces typing YES
  --version           print the version
  --help              this help

Log: ${PROVISION_LOG_FILE}
USAGE
}

step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    CURRENT_STEP_NAME="$1"
    log_step "${CURRENT_STEP}/${TOTAL_STEPS}" "$1"
}

on_exit() {
    local code=$?
    if [[ "${code}" -ne 0 && "${CURRENT_STEP}" -gt 0 ]]; then
        if [[ "${STOPPED_ON_PURPOSE}" != "1" ]]; then
            report_add "ERROR" "${CURRENT_STEP_NAME}" "aborted in this step"
        fi
        report_print
        printf '\nProvisioning did NOT finish (step %s/%s: %s).\n' \
            "${CURRENT_STEP}" "${TOTAL_STEPS}" "${CURRENT_STEP_NAME}"
        printf 'Fix the cause and run the command again: completed steps are skipped.\n'
        printf 'Do not close this SSH session until you have checked that you can log in from a new one.\n'
    fi
}

# --- helpers ----------------------------------------------------------------

user_exists() { id -u "$1" >/dev/null 2>&1; }

user_home() { getent passwd "$1" | cut -d: -f6; }

# Note on style: with `set -o pipefail`, `producer | grep -q` can fail when
# grep exits at the first match and the producer gets SIGPIPE. Output is
# therefore captured first and matched from a here-string.
user_in_group() {
    local groups
    groups="$(id -nG "$1" 2>/dev/null | tr ' ' '\n')" || return 1
    grep -qxF -- "$2" <<<"${groups}"
}

authorized_keys_valid() {
    local home file
    user_exists "$1" || return 1
    home="$(user_home "$1")"
    file="${home}/.ssh/authorized_keys"
    [[ -s "${file}" ]] && ssh-keygen -l -f "${file}" >/dev/null 2>&1
}

ensure_user() {
    if user_exists "$1"; then
        log_info "User $1 already exists."
    else
        run useradd --create-home --shell /bin/bash "$1"
    fi
}

ensure_group_member() {
    local user="$1" group="$2"
    if user_in_group "${user}" "${group}"; then
        return 0
    fi
    run usermod -aG "${group}" "${user}"
}

install_pubkeys() {
    local user="$1" source_file="$2" home group ssh_dir auth_file line
    if ! user_exists "${user}"; then
        log_dry "install keys from ${source_file} into authorized_keys of user ${user}"
        return 0
    fi
    home="$(user_home "${user}")"
    group="$(id -gn "${user}")"
    ssh_dir="${home}/.ssh"
    auth_file="${ssh_dir}/authorized_keys"
    run install -d -m 700 -o "${user}" -g "${group}" "${ssh_dir}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        case "${line}" in
            "" | "#"*) continue ;;
            *) ;;
        esac
        append_line "${auth_file}" "${line}"
    done <"${source_file}"
    run chown "${user}:${group}" "${auth_file}"
    run chmod 600 "${auth_file}"
}

swap_size_mib() {
    local size="$1" number="${1%[MG]}"
    case "${size}" in
        *G) printf '%s\n' "$((number * 1024))" ;;
        *) printf '%s\n' "${number}" ;;
    esac
}

# sshd_effective_ok: does the running configuration match the hardening?
sshd_effective_ok() {
    local effective user
    effective="$(sshd -T 2>/dev/null)" || return 1
    grep -qx 'passwordauthentication no' <<<"${effective}" || return 1
    grep -qx 'kbdinteractiveauthentication no' <<<"${effective}" || return 1
    grep -qx 'permitrootlogin no' <<<"${effective}" || return 1
    grep -qx 'pubkeyauthentication yes' <<<"${effective}" || return 1
    for user in "${ADMIN_USER}" "${DEPLOY_USER}"; do
        grep -qx "allowusers ${user}" <<<"${effective}" || return 1
    done
}

sshd_show_effective() {
    sshd -T 2>/dev/null | grep -Ei '^(passwordauthentication|permitrootlogin|allowusers|port) ' || true
}

sshd_reload() {
    local service
    if ! service="$(os_ssh_service)"; then
        if is_dry_run; then
            log_dry "reload the sshd service"
            return 0
        fi
        die "No SSH service found (neither ssh.service nor sshd.service)."
    fi
    if systemctl is-active --quiet "${service}.service"; then
        run systemctl reload "${service}.service"
    else
        log_info "Service ${service} is not running right now (socket activation): the new configuration applies to the next connection."
    fi
}

# sshd_conflicts: print directives in other files that touch what we set.
sshd_conflicts() {
    local file
    for file in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "${file}" && "${file}" != "${SSHD_HARDENING_FILE}" ]] || continue
        grep -HnEi '^[[:space:]]*(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PubkeyAuthentication|AuthenticationMethods|AllowUsers|AllowGroups|DenyUsers|DenyGroups|Port)[[:space:]]' \
            "${file}" || true
    done
}

ufw_active() {
    local status
    status="$(LC_ALL=C ufw status 2>/dev/null || true)"
    grep -q '^Status: active' <<<"${status}"
}

# --- configuration ----------------------------------------------------------

ACTIVE_CONFIG=""

load_config() {
    stack_config_defaults
    if [[ -f "${STACK_ENV_FILE}" ]]; then
        ACTIVE_CONFIG="${STACK_ENV_FILE}"
        if [[ -n "${CONFIG_FILE}" ]] && ! cmp -s "${CONFIG_FILE}" "${STACK_ENV_FILE}"; then
            log_warn "Configuration ${STACK_ENV_FILE} already exists and is the one in use. The file given with --config was ignored."
            log_warn "To change settings, edit ${STACK_ENV_FILE}."
        fi
    elif [[ -n "${CONFIG_FILE}" ]]; then
        [[ -r "${CONFIG_FILE}" ]] || die "Cannot read the configuration file: ${CONFIG_FILE}"
        ACTIVE_CONFIG="${CONFIG_FILE}"
    else
        die "The first run needs --config <file>. Copy config/stack.env.example, fill it in and pass its path."
    fi
    load_env_file "${ACTIVE_CONFIG}"
}

validate_config() {
    local -a errors=()
    local re_user='^[a-z_][a-z0-9_-]{0,31}$'
    local re_swap='^(0|[1-9][0-9]{0,4}[MG])$'
    local re_tz='^[A-Za-z0-9_+/-]+$'
    local re_ips='^[0-9a-fA-F.:/ ]*$'
    local re_net='^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$'
    local name value ports

    for name in ADMIN_USER DEPLOY_USER; do
        value="${!name}"
        if [[ ! "${value}" =~ ${re_user} ]]; then
            errors+=("${name}: '${value}' is not a valid user name.")
        elif [[ "${value}" == "root" ]]; then
            errors+=("${name}: must not be 'root'.")
        elif ! user_exists "${value}" && getent group "${value}" >/dev/null 2>&1; then
            # useradd creates a group named after the user and fails when one
            # exists. Ubuntu cloud images have a group "admin" (cloud-init).
            errors+=("${name}: a group named '${value}' already exists on this system (on Ubuntu cloud images cloud-init creates 'admin'). Choose another name, e.g. ${name}=sysadmin.")
        fi
    done
    if [[ "${ADMIN_USER}" == "${DEPLOY_USER}" ]]; then
        errors+=("ADMIN_USER and DEPLOY_USER must be different users.")
    fi
    for name in DEPLOY_IN_DOCKER_GROUP AUTO_REBOOT; do
        value="${!name}"
        if [[ "${value}" != "true" && "${value}" != "false" ]]; then
            errors+=("${name}: allowed values are true and false.")
        fi
    done
    if ! validate_port "${SSH_PORT}"; then
        errors+=("SSH_PORT: '${SSH_PORT}' is not a port in the range 1-65535.")
    elif [[ "${SSH_PORT}" == "80" || "${SSH_PORT}" == "443" ]]; then
        errors+=("SSH_PORT: ports 80 and 443 are taken by the proxy.")
    fi
    if [[ ! "${SWAP_SIZE}" =~ ${re_swap} ]]; then
        errors+=("SWAP_SIZE: give 0 or a size such as 2G or 512M.")
    fi
    if [[ -n "${SERVER_HOSTNAME}" ]] && ! validate_hostname "${SERVER_HOSTNAME}" 2>/dev/null; then
        errors+=("SERVER_HOSTNAME: '${SERVER_HOSTNAME}' is not a valid host name: lowercase letters, digits and -, e.g. srv1 or srv1.example.com. Leave it empty to keep the current name.")
    fi
    if [[ ! "${TIMEZONE}" =~ ${re_tz} ]]; then
        errors+=("TIMEZONE: '${TIMEZONE}' contains characters that are not allowed.")
    elif [[ -d /usr/share/zoneinfo && ! -e "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
        errors+=("TIMEZONE: there is no zone '${TIMEZONE}' in /usr/share/zoneinfo.")
    fi
    if [[ ! "${FAIL2BAN_IGNOREIP}" =~ ${re_ips} ]]; then
        errors+=("FAIL2BAN_IGNOREIP: only IP addresses and CIDR networks separated by spaces are allowed.")
    fi
    if [[ ! "${PROXY_NETWORK}" =~ ${re_net} ]]; then
        errors+=("PROXY_NETWORK: '${PROXY_NETWORK}' is not a valid Docker network name.")
    fi

    # The administrator's key is required unless a previous run already
    # installed one.
    if [[ -n "${ADMIN_SSH_PUBKEY_FILE}" && -r "${ADMIN_SSH_PUBKEY_FILE}" ]]; then
        if ! ssh-keygen -l -f "${ADMIN_SSH_PUBKEY_FILE}" >/dev/null 2>&1; then
            errors+=("ADMIN_SSH_PUBKEY_FILE: ${ADMIN_SSH_PUBKEY_FILE} does not contain a valid SSH public key.")
        fi
    elif ! authorized_keys_valid "${ADMIN_USER}"; then
        if [[ -z "${ADMIN_SSH_PUBKEY_FILE}" ]]; then
            errors+=("ADMIN_SSH_PUBKEY_FILE: required (path to a file with the administrator's public key).")
        else
            errors+=("ADMIN_SSH_PUBKEY_FILE: cannot read ${ADMIN_SSH_PUBKEY_FILE}.")
        fi
    fi
    if [[ -n "${DEPLOY_SSH_PUBKEY_FILE}" ]]; then
        if [[ ! -r "${DEPLOY_SSH_PUBKEY_FILE}" ]]; then
            if ! authorized_keys_valid "${DEPLOY_USER}"; then
                errors+=("DEPLOY_SSH_PUBKEY_FILE: cannot read ${DEPLOY_SSH_PUBKEY_FILE}.")
            fi
        elif ! ssh-keygen -l -f "${DEPLOY_SSH_PUBKEY_FILE}" >/dev/null 2>&1; then
            errors+=("DEPLOY_SSH_PUBKEY_FILE: ${DEPLOY_SSH_PUBKEY_FILE} does not contain a valid SSH public key.")
        fi
    fi

    # provision never moves sshd to another port: that is what ssh-port is
    # for, with its own safeguards. So SSH_PORT has to match reality.
    if have_cmd sshd; then
        ports="$(os_ssh_ports || true)"
        if [[ -n "${ports}" ]] && ! grep -qx -- "${SSH_PORT}" <<<"${ports}"; then
            errors+=("SSH_PORT=${SSH_PORT}, but sshd listens on: $(tr '\n' ' ' <<<"${ports}"). Keep the current port here and change it after provisioning: vps-stack ssh-port <port>.")
        fi
    elif ! is_dry_run; then
        errors+=("sshd not found. This script expects a server with a working OpenSSH.")
    fi

    if [[ "${#errors[@]}" -gt 0 ]]; then
        log_error "Configuration ${ACTIVE_CONFIG} is invalid:"
        for value in "${errors[@]}"; do
            printf '  - %s\n' "${value}" >&2
        done
        die "Fix the configuration and run again. Nothing was changed."
    fi
}

# --- steps ------------------------------------------------------------------

step_preflight() {
    local free_kb invoker
    step "Preflight"

    os_detect
    os_require_supported
    require_cmd ssh-keygen awk grep sed cmp

    load_config
    validate_config
    log_ok "Configuration ${ACTIVE_CONFIG} is valid."

    log_info "Checking connectivity and package repositories (apt update)..."
    os_pkg_update >/dev/null || die "apt update failed. Check internet connectivity and the package sources."

    free_kb="$(df -Pk / | awk 'NR == 2 { print $4 }')"
    if [[ "${free_kb}" -lt $((MIN_FREE_GB * 1024 * 1024)) ]]; then
        die "Not enough free space on /: $((free_kb / 1024)) MB. At least ${MIN_FREE_GB} GB is needed."
    fi

    invoker="${SUDO_USER:-$(id -un)}"
    cat <<SUMMARY

Summary before any change
  Run by:                  ${invoker}
  System:                  ${OS_PRETTY_NAME} (${OS_CODENAME:-no codename})
  Configuration:           ${ACTIVE_CONFIG}
  ADMIN_USER:              ${ADMIN_USER} (sudo, key login)
  DEPLOY_USER:             ${DEPLOY_USER} (no sudo; docker group: ${DEPLOY_IN_DOCKER_GROUP})
  Admin key:               ${ADMIN_SSH_PUBKEY_FILE:-(already installed)}
  Deploy key:              ${DEPLOY_SSH_PUBKEY_FILE:-(none)}
  SSH_PORT:                ${SSH_PORT}
  FAIL2BAN_IGNOREIP:       ${FAIL2BAN_IGNOREIP:-(empty)}
  SWAP_SIZE:               ${SWAP_SIZE}
  SERVER_HOSTNAME:         ${SERVER_HOSTNAME:-(empty: keep $(hostname 2>/dev/null || printf 'the current name'))}
  TIMEZONE:                ${TIMEZONE}
  AUTO_REBOOT:             ${AUTO_REBOOT}
  PROXY_NETWORK:           ${PROXY_NETWORK}
  Docker:                  $(if [[ "${SKIP_DOCKER}" == "1" ]]; then printf 'skipped'; elif [[ "${DOCKER_FALLBACK}" == "1" ]]; then printf 'from the distribution repository'; else printf 'from the Docker repository'; fi)
  Free space on /:         $((free_kb / 1024 / 1024)) GB

The script will change the SSH and firewall configuration. Keep access to
your provider's rescue console open and do NOT close this SSH session until
the end.
SUMMARY
    confirm "Start provisioning?" || {
        STOPPED_ON_PURPOSE=1
        die "Aborted at the user's request. Nothing was changed."
    }

    run install -d -m 700 -o root -g root "${ETC_DIR}"
    if [[ ! -f "${STACK_ENV_FILE}" ]]; then
        run install -m 600 -o root -g root "${ACTIVE_CONFIG}" "${STACK_ENV_FILE}"
        is_dry_run || log_info "Configuration saved as ${STACK_ENV_FILE}. Later runs read this file."
    fi
    report_add "OK" "Preflight"
}

step_packages() {
    step "System packages"
    os_pkg_install "${BASE_PACKAGES[@]}"
    report_add "OK" "System packages"
}

# set_hostname: the host name from SERVER_HOSTNAME, its line in /etc/hosts
# (without it sudo prints "unable to resolve host") and, on cloud images, a
# cloud-init setting that keeps both across reboots.
set_hostname() {
    local short="${SERVER_HOSTNAME%%.*}" content
    content="$(hosts_with_hostname "${SERVER_HOSTNAME}" "${short}" </etc/hosts)"
    # /etc/hosts first: sudo resolves the new name from the moment it is set.
    write_file /etc/hosts 644 <<<"${content}"
    if [[ "$(hostname)" != "${short}" || "$(cat /etc/hostname 2>/dev/null)" != "${short}" ]]; then
        run hostnamectl set-hostname "${short}"
    fi
    if [[ -d "${CLOUD_INIT_CFG_DIR}" ]]; then
        content="# Managed by vps-stack (provision, SERVER_HOSTNAME). Manual edits are overwritten."$'\n'
        content+="# cloud-init would otherwise set the provider's host name and rewrite"$'\n'
        content+="# /etc/hosts at every boot."$'\n'
        content+="preserve_hostname: true"$'\n'"manage_etc_hosts: false"
        write_file --no-backup "${CLOUD_INIT_HOSTNAME_FILE}" 644 <<<"${content}"
    fi
}

step_system() {
    local current_tz content
    step "Host name, time zone, journald, sysctl"

    if [[ -n "${SERVER_HOSTNAME}" ]]; then
        set_hostname
    fi

    current_tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    if [[ "${current_tz}" != "${TIMEZONE}" ]]; then
        run timedatectl set-timezone "${TIMEZONE}"
    fi

    run install -d -m 755 /etc/systemd/journald.conf.d
    content="[Journal]"$'\n'"SystemMaxUse=200M"
    write_file /etc/systemd/journald.conf.d/size.conf 644 <<<"${content}"
    if [[ "${WRITE_FILE_CHANGED}" == "1" ]]; then
        run systemctl restart systemd-journald
    fi

    content="vm.swappiness=10"$'\n'"vm.vfs_cache_pressure=50"
    write_file /etc/sysctl.d/99-vps-stack.conf 644 <<<"${content}"
    if [[ "${WRITE_FILE_CHANGED}" == "1" ]]; then
        run sysctl --system >/dev/null
    fi
    report_add "OK" "Host name, time zone, journald, sysctl" "${SERVER_HOSTNAME:-host name unchanged}"
}

step_swap() {
    local size_mib fstype
    step "Swap"

    if [[ "${SWAP_SIZE}" == "0" ]]; then
        report_add "OK" "Swap" "disabled in the configuration (SWAP_SIZE=0)"
        return 0
    fi
    if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
        log_info "Swap already exists, skipping."
        report_add "OK" "Swap" "already active"
        return 0
    fi
    if [[ -e /swapfile ]]; then
        log_warn "/swapfile exists but is not active. Not overwriting it."
        report_add "WARN" "Swap" "/swapfile exists but is inactive; check it manually"
        return 0
    fi
    fstype="$(findmnt -no FSTYPE / 2>/dev/null || true)"
    if [[ "${fstype}" == "btrfs" || "${fstype}" == "zfs" ]]; then
        log_warn "File system ${fstype}: a swap file needs separate setup, skipping."
        report_add "WARN" "Swap" "skipped on ${fstype}; set it up manually"
        return 0
    fi

    size_mib="$(swap_size_mib "${SWAP_SIZE}")"
    if ! run fallocate -l "${size_mib}M" /swapfile; then
        log_warn "fallocate failed, using dd (takes longer)."
        run rm -f /swapfile
        run dd if=/dev/zero of=/swapfile bs=1M count="${size_mib}"
    fi
    run chmod 600 /swapfile
    run mkswap /swapfile >/dev/null
    run swapon /swapfile
    if ! grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab 2>/dev/null; then
        append_line /etc/fstab "/swapfile none swap sw 0 0"
    fi
    report_add "OK" "Swap" "${SWAP_SIZE} in /swapfile"
}

step_users() {
    local status attempt
    step "Users"

    getent group sudo >/dev/null || die "The system has no 'sudo' group. Not guessing how to grant administrator rights."

    ensure_user "${ADMIN_USER}"
    ensure_group_member "${ADMIN_USER}" sudo
    if [[ -n "${ADMIN_SSH_PUBKEY_FILE}" && -r "${ADMIN_SSH_PUBKEY_FILE}" ]]; then
        install_pubkeys "${ADMIN_USER}" "${ADMIN_SSH_PUBKEY_FILE}"
    fi

    ensure_user "${DEPLOY_USER}"
    if [[ -n "${DEPLOY_SSH_PUBKEY_FILE}" && -r "${DEPLOY_SSH_PUBKEY_FILE}" ]]; then
        install_pubkeys "${DEPLOY_USER}" "${DEPLOY_SSH_PUBKEY_FILE}"
    fi

    # With SSH passwords disabled the admin still needs a password for sudo.
    # NOPASSWD is deliberately not used.
    if is_dry_run; then
        log_dry "if ${ADMIN_USER} has no password: interactive passwd ${ADMIN_USER} (needed for sudo)"
    else
        status="$(passwd -S "${ADMIN_USER}" 2>/dev/null | awk '{ print $2 }')"
        if [[ "${status}" != "P" ]]; then
            log_info "User ${ADMIN_USER} has no password. One is needed for sudo (SSH login stays key-only)."
            has_tty || die "No terminal, cannot set the password. Run: passwd ${ADMIN_USER}, then run provisioning again."
            attempt=0
            until passwd "${ADMIN_USER}" </dev/tty >/dev/tty 2>&1; do
                attempt=$((attempt + 1))
                if [[ "${attempt}" -ge 3 ]]; then
                    die "Could not set a password for ${ADMIN_USER}."
                fi
                log_warn "Try again."
            done
        fi
    fi
    report_add "OK" "Users" "${ADMIN_USER} (sudo), ${DEPLOY_USER}"
}

step_ssh() {
    local mode port_line="" content conflicts invoker
    step "SSH hardening"

    if ! grep -Eiq '^[[:space:]]*Include[[:space:]]+(/etc/ssh/)?sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
        if is_dry_run; then
            log_warn "/etc/ssh/sshd_config does not include sshd_config.d/*.conf: a real run would stop here."
        else
            die "/etc/ssh/sshd_config does not include sshd_config.d/*.conf. Not guessing the configuration layout: add the line 'Include /etc/ssh/sshd_config.d/*.conf' at the top of the file and run again."
        fi
    fi

    mode="$(os_ssh_mode)"
    log_info "sshd start mode: ${mode}"
    if [[ "${mode}" == "service" && "${SSH_PORT}" != "22" ]]; then
        port_line="Port ${SSH_PORT}"
    fi
    content="$(render_template "${REPO_ROOT}/templates/sshd-hardening.conf.tmpl" \
        "ALLOW_USERS=${ADMIN_USER} ${DEPLOY_USER}" "PORT_LINE=${port_line}")"

    if [[ -f "${SSHD_HARDENING_FILE}" && "$(cat "${SSHD_HARDENING_FILE}")" == "${content}" ]] && sshd_effective_ok; then
        log_info "SSH hardening is already applied."
        report_add "OK" "SSH hardening" "unchanged"
        return 0
    fi

    if ! is_dry_run && ! authorized_keys_valid "${ADMIN_USER}"; then
        die "User ${ADMIN_USER} has no valid key in ~/.ssh/authorized_keys. Not disabling passwords."
    fi

    conflicts="$(sshd_conflicts)"
    if [[ -n "${conflicts}" ]]; then
        log_warn "Other files set the same sshd directives (the first value read wins, which is why our file has the 00- prefix):"
        printf '%s\n' "${conflicts}" | sed 's/^/    /'
    fi

    invoker="${SUDO_USER:-$(id -un)}"
    if [[ "${invoker}" != "${ADMIN_USER}" && "${invoker}" != "${DEPLOY_USER}" ]]; then
        log_warn "After this change user '${invoker}' will NOT be able to log in over SSH any more (AllowUsers: ${ADMIN_USER} ${DEPLOY_USER})."
        log_warn "This session stays open."
    fi

    if [[ "${SECOND_SESSION_TESTED}" == "1" ]]; then
        log_info "Question skipped: --i-tested-second-ssh-session was given."
    elif ! confirm_phrase "YES" "Password login and root login over SSH are about to be disabled.
Open a SECOND SSH session as ${ADMIN_USER} and check that key login and 'sudo -v' work."; then
        report_add "WARN" "SSH hardening" "second session test not confirmed; sshd unchanged"
        STOPPED_ON_PURPOSE=1
        die "Not confirmed. The sshd configuration was not changed. Check the second session and run provisioning again."
    fi

    write_file "${SSHD_HARDENING_FILE}" 644 <<<"${content}"
    if ! run sshd -t; then
        restore_last_write "${SSHD_HARDENING_FILE}"
        die "sshd -t rejected the new configuration. The previous state was restored and sshd was not reloaded."
    fi
    sshd_reload

    if is_dry_run; then
        report_add "OK" "SSH hardening" "dry-run"
        return 0
    fi

    log_info "Effective sshd configuration (sshd -T):"
    sshd_show_effective | sed 's/^/    /'
    if ! sshd_effective_ok; then
        restore_last_write "${SSHD_HARDENING_FILE}"
        sshd_reload
        die "After the reload sshd still has values other than expected (see the directives printed above). The previous state was restored."
    fi
    log_warn "Do NOT close this session. Open a new SSH session as ${ADMIN_USER} and make sure you can still log in."
    report_add "OK" "SSH hardening" "keys only, root disabled"
}

step_ufw() {
    local content port added
    step "Firewall (ufw)"

    if [[ -f /etc/default/ufw ]] && ! grep -qx 'IPV6=yes' /etc/default/ufw; then
        content="$(grep -v '^IPV6=' /etc/default/ufw || true)"$'\n'"IPV6=yes"
        write_file /etc/default/ufw 644 <<<"${content}"
    fi

    run ufw default deny incoming >/dev/null
    run ufw default allow outgoing >/dev/null
    for port in "${SSH_PORT}/tcp" 80/tcp 443/tcp 443/udp; do
        run ufw allow "${port}" >/dev/null
    done

    if is_dry_run; then
        log_dry "enable ufw after checking the SSH rule and asking for confirmation"
        report_add "OK" "Firewall (ufw)" "dry-run"
        return 0
    fi

    if ufw_active; then
        log_info "ufw is already enabled."
    else
        added="$(ufw show added 2>/dev/null || true)"
        if ! grep -qxF "ufw allow ${SSH_PORT}/tcp" <<<"${added}"; then
            die "Rule 'ufw allow ${SSH_PORT}/tcp' is not on the list of added rules. Not enabling the firewall, so that SSH is not cut off."
        fi
        log_info "Rules that will take effect:"
        printf '%s\n' "${added}" | sed 's/^/    /'
        # Not skippable with --yes: a wrong rule set here cuts off SSH.
        confirm_risky "The SSH rule (${SSH_PORT}/tcp) is on the list. Enable the firewall?" || {
            report_add "WARN" "Firewall (ufw)" "rules added, firewall NOT enabled"
            STOPPED_ON_PURPOSE=1
            die "The firewall was not enabled. Run provisioning again when you are ready."
        }
        ufw --force enable
    fi
    ufw status verbose | sed 's/^/    /'
    report_add "OK" "Firewall (ufw)" "SSH ${SSH_PORT}, 80, 443"
}

step_fail2ban() {
    local content i
    step "fail2ban"

    content="$(render_template "${REPO_ROOT}/templates/jail.local.tmpl" \
        "BACKEND=$(os_fail2ban_backend)" \
        "IGNOREIP=${FAIL2BAN_IGNOREIP:+ ${FAIL2BAN_IGNOREIP}}" \
        "SSH_PORT=${SSH_PORT}")"
    write_file /etc/fail2ban/jail.local 644 <<<"${content}"
    run systemctl enable --quiet fail2ban || true
    if [[ "${WRITE_FILE_CHANGED}" == "1" ]] || ! systemctl is-active --quiet fail2ban 2>/dev/null; then
        run systemctl restart fail2ban || true
    fi
    if is_dry_run; then
        report_add "OK" "fail2ban" "dry-run"
        return 0
    fi

    # Never fatal: fail2ban adds little once passwords are off, and a broken
    # jail must not stop the rest of the provisioning.
    for ((i = 0; i < 10; i++)); do
        if fail2ban-client status sshd >/dev/null 2>&1; then
            fail2ban-client status sshd | sed 's/^/    /'
            report_add "OK" "fail2ban" "sshd jail active"
            return 0
        fi
        sleep 1
    done
    log_warn "The sshd jail did not start. Check: journalctl -u fail2ban"
    report_add "ERROR" "fail2ban" "sshd jail not running (journalctl -u fail2ban)"
}

step_unattended() {
    local code=0
    step "Automatic updates"
    os_unattended_upgrades_setup "${AUTO_REBOOT}" || code=$?
    case "${code}" in
        0) report_add "OK" "Automatic updates" "automatic reboot: ${AUTO_REBOOT}" ;;
        3) report_add "WARN" "Automatic updates" "security update origin not confirmed" ;;
        *) die "Setting up automatic updates failed." ;;
    esac
}

docker_ready() {
    have_cmd docker && docker compose version >/dev/null 2>&1
}

step_docker() {
    local mode="official" conflicts code=0 merged content
    local daemon_file="/etc/docker/daemon.json"
    step "Docker"

    if [[ "${SKIP_DOCKER}" == "1" ]]; then
        report_add "WARN" "Docker" "skipped (--skip-docker)"
        return 0
    fi
    if [[ "${DOCKER_FALLBACK}" == "1" ]]; then
        mode="fallback"
    fi

    if docker_ready; then
        log_info "Docker and the Compose plugin are already installed."
    else
        conflicts="$(os_docker_conflicts "${mode}")"
        if [[ -n "${conflicts}" ]]; then
            log_warn "Installed packages that conflict with the chosen Docker installation:"
            printf '%s\n' "${conflicts}" | sed 's/^/    /'
            confirm "Remove these packages? (images and containers are not deleted)" ||
                die "Not installing Docker without removing the conflicting packages. You can also use --skip-docker."
            # shellcheck disable=SC2086  # word splitting wanted: list of package names
            os_docker_remove_packages ${conflicts}
        fi
        if [[ "${mode}" == "official" ]]; then
            os_docker_repo_setup || code=$?
            if [[ "${code}" == "2" ]]; then
                die "Docker publishes no repository for this release (${OS_ID} ${OS_CODENAME:-?}). Not guessing: run again with --docker-fallback to install docker.io and docker-compose-v2 from the distribution repository."
            elif [[ "${code}" != "0" ]]; then
                die "Setting up the Docker repository failed."
            fi
        fi
        os_docker_install "${mode}"
    fi

    # Merge our keys into an existing daemon.json instead of replacing it.
    if have_cmd jq; then
        if [[ -s "${daemon_file}" ]]; then
            merged="$(jq -s '.[0] * .[1]' "${daemon_file}" "${REPO_ROOT}/templates/docker-daemon.json")" ||
                die "${daemon_file} is not valid JSON. Fix it manually and run again."
        else
            merged="$(jq . "${REPO_ROOT}/templates/docker-daemon.json")"
        fi
        run install -d -m 755 /etc/docker
        write_file "${daemon_file}" 644 <<<"${merged}"
        if [[ "${WRITE_FILE_CHANGED}" == "1" ]]; then
            run systemctl restart docker
        fi
    else
        log_dry "merge ${daemon_file} with templates/docker-daemon.json (jq is not installed yet)"
    fi
    run systemctl enable --quiet --now docker || die "Could not start the docker service."

    ensure_group_member "${ADMIN_USER}" docker
    if [[ "${DEPLOY_IN_DOCKER_GROUP}" == "true" ]]; then
        log_warn "DEPLOY_IN_DOCKER_GROUP=true: ${DEPLOY_USER} gets privileges equivalent to root."
        ensure_group_member "${DEPLOY_USER}" docker
    fi

    content="# Managed by vps-stack (provision). Manual edits are overwritten.
# Weekly cleanup of dangling images and old build cache. Never prunes volumes
# or images that are still tagged.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 4 * * 0 root docker image prune -f >/dev/null 2>&1; docker builder prune -f --filter until=168h >/dev/null 2>&1"
    write_file /etc/cron.d/vps-stack-docker-cleanup 644 <<<"${content}"

    report_add "OK" "Docker" "$(if [[ "${mode}" == "fallback" ]]; then printf 'distribution packages'; else printf 'Docker repository'; fi)"
}

step_layout() {
    local content sibling
    step "Directories and network"

    run install -d -m 700 -o root -g root "${ETC_DIR}"
    run install -d -m 755 -o root -g root "${SITES_DIR}"
    run install -d -m 700 -o root -g root "${HOOKS_DIR}"
    run install -d -m 755 -o root -g root "$(dirname "${CADDY_DATA_DIR}")"
    run install -d -m 700 -o root -g root "${CADDY_DATA_DIR}"
    run install -d -m 700 -o root -g root "${CADDY_DATA_DIR}/data"
    run install -d -m 700 -o root -g root "${CADDY_DATA_DIR}/config"
    run install -d -m 700 -o root -g root "${STAGING_DIR}"

    if [[ ! -f "${PROXY_ENV_FILE}" ]]; then
        sibling=""
        if [[ -n "${CONFIG_FILE}" ]]; then
            sibling="$(dirname "${CONFIG_FILE}")/proxy.env"
        fi
        if [[ -n "${sibling}" && -r "${sibling}" ]]; then
            run install -m 600 -o root -g root "${sibling}" "${PROXY_ENV_FILE}"
            is_dry_run || log_info "Copied ${sibling} to ${PROXY_ENV_FILE}."
        else
            run install -m 600 -o root -g root "${REPO_ROOT}/config/proxy.env.example" "${PROXY_ENV_FILE}"
            is_dry_run || log_info "Created ${PROXY_ENV_FILE} from the example. Fill in ACME_EMAIL there."
        fi
    fi

    if [[ ! -e /usr/local/bin/vps-stack ]]; then
        run ln -s "${REPO_ROOT}/bin/vps-stack" /usr/local/bin/vps-stack
    fi

    content="${BACKUP_LOG_FILE} ${PROVISION_LOG_FILE} {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    create 0600 root root
}"
    # --no-backup: logrotate would read a *.bak.* copy as another config.
    write_file --no-backup /etc/logrotate.d/vps-stack 644 <<<"${content}"

    if have_cmd docker; then
        # With IPv6, so that Caddy sees the real address of IPv6 clients
        # (see ensure_network in scripts/proxy.sh).
        if ! docker network inspect "${PROXY_NETWORK}" >/dev/null 2>&1; then
            run docker network create --ipv6 "${PROXY_NETWORK}" >/dev/null
            report_add "OK" "Directories and network" "Docker network: ${PROXY_NETWORK} (IPv4 and IPv6)"
        elif [[ "$(docker network inspect -f '{{.EnableIPv6}}' "${PROXY_NETWORK}" 2>/dev/null)" == "true" ]]; then
            report_add "OK" "Directories and network" "Docker network: ${PROXY_NETWORK} (IPv4 and IPv6)"
        else
            # Not changed here: recreating the network stops every site.
            report_add "WARN" "Directories and network" "${PROXY_NETWORK} is IPv4 only; run once: sudo vps-stack proxy network-ipv6"
        fi
    else
        report_add "WARN" "Directories and network" "no Docker network (Docker not installed)"
    fi
}

step_proxy() {
    local ACME_EMAIL="" file has_sites=0
    step "Proxy (Caddy)"

    if is_dry_run; then
        log_dry "start the proxy: vps-stack proxy up (or restart when sites already exist)"
        report_add "OK" "Proxy (Caddy)" "dry-run"
        return 0
    fi
    if ! have_cmd docker; then
        report_add "WARN" "Proxy (Caddy)" "skipped (Docker not installed)"
        return 0
    fi
    load_env_file "${PROXY_ENV_FILE}"
    if [[ -z "${ACME_EMAIL}" ]]; then
        log_warn "ACME_EMAIL in ${PROXY_ENV_FILE} is empty. Fill it in, then run: vps-stack proxy up"
        report_add "WARN" "Proxy (Caddy)" "not started: fill in ACME_EMAIL in ${PROXY_ENV_FILE}"
        return 0
    fi

    for file in "${SITES_DIR}"/*.caddy; do
        if [[ -f "${file}" ]]; then
            has_sites=1
            break
        fi
    done
    if [[ "${has_sites}" == "1" ]]; then
        # Existing sites: validate first, then recreate the container.
        log_info "Sites are already configured: validating the configuration and restarting the proxy."
        "${SCRIPT_DIR}/proxy.sh" restart ||
            die "Restarting the proxy failed. The previous container keeps running if validation rejected the configuration."
        report_add "OK" "Proxy (Caddy)" "validated and restarted"
    else
        # No sites yet: Caddy starts without hosts and requests no
        # certificates. Ports 80/443 refuse connections until add-site.
        "${SCRIPT_DIR}/proxy.sh" up || die "Starting the proxy failed. Check: vps-stack proxy logs"
        report_add "OK" "Proxy (Caddy)" "running, no sites"
    fi
}

step_summary() {
    local user others=""
    step "Summary"
    report_print

    if have_cmd ss; then
        printf '\nListening ports (ss -tlnp):\n'
        ss -tlnp 2>/dev/null | sed 's/^/    /' || true
    fi

    while IFS=: read -r user _ uid _; do
        if [[ "${uid}" -ge 1000 && "${uid}" -lt 60000 && "${user}" != "${ADMIN_USER}" && "${user}" != "${DEPLOY_USER}" ]]; then
            others="${others:+${others} }${user}"
        fi
    done </etc/passwd

    if is_dry_run; then
        if [[ -n "${others}" ]]; then
            printf '\nOther users with a shell on this server: %s. After provisioning they will no longer log in over SSH (AllowUsers).\n' "${others}"
        fi
        if [[ "${REPORT_ERRORS}" -gt 0 ]]; then
            printf '\nDry run finished WITH ERRORS (%s). Nothing was changed.\n' "${REPORT_ERRORS}"
            STOPPED_ON_PURPOSE=1
            CURRENT_STEP=0
            exit 1
        fi
        printf '\nDry run finished: nothing was changed. Run the command again without --dry-run to apply it.\n'
        return 0
    fi

    cat <<NEXT

Manual steps (the script does not do them):
  1. Enable two-factor authentication (2FA) on your VPS provider account.
  2. Take a snapshot of the server in the provider's panel.
  3. Log in as ${ADMIN_USER} in a NEW SSH session and check 'sudo -v'.
     Only then close this session.
  4. Point the DNS records of your domains at this server, then add the sites:
     vps-stack add-site <domain> <container:port>
  5. Set up off-site backup: docs/backup-restore.md
  6. Set up external uptime monitoring: docs/monitoring.md
  7. Check the state of the server: sudo vps-stack verify
NEXT
    if [[ -n "${others}" ]]; then
        cat <<LOCK

Other users with a shell on this server: ${others}
They were not removed. Their SSH login is already blocked (AllowUsers).
Once you have confirmed that ${ADMIN_USER} works, you can lock their passwords too:
  sudo passwd -l <user>
LOCK
    fi
    if [[ "${REPORT_ERRORS}" -gt 0 ]]; then
        printf '\nProvisioning finished WITH ERRORS (%s). See the table above.\n' "${REPORT_ERRORS}"
        STOPPED_ON_PURPOSE=1
        CURRENT_STEP=0
        exit 1
    fi
    printf '\nProvisioning finished.\n'
}

# --- main -------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                [[ $# -ge 2 ]] || die "Option --config needs a file path."
                CONFIG_FILE="$2"
                shift
                ;;
            --dry-run) DRY_RUN=1 ;;
            --yes | -y) ASSUME_YES=1 ;;
            --skip-docker) SKIP_DOCKER=1 ;;
            --docker-fallback) DOCKER_FALLBACK=1 ;;
            --i-tested-second-ssh-session) SECOND_SESSION_TESTED=1 ;;
            --version)
                cat "${REPO_ROOT}/VERSION"
                exit 0
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "Unknown option: $1"
                ;;
        esac
        shift
    done
    if [[ "${SKIP_DOCKER}" == "1" && "${DOCKER_FALLBACK}" == "1" ]]; then
        die "Options --skip-docker and --docker-fallback are mutually exclusive."
    fi

    require_root
    if is_dry_run; then
        log_info "--dry-run mode: nothing will be changed."
    else
        touch "${PROVISION_LOG_FILE}"
        chmod 600 "${PROVISION_LOG_FILE}"
        exec > >(tee -a "${PROVISION_LOG_FILE}") 2>&1
        printf '\n===== vps-stack provision %s, %s =====\n' "$(cat "${REPO_ROOT}/VERSION")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
    trap on_exit EXIT

    step_preflight
    step_packages
    step_system
    step_swap
    step_users
    step_ssh
    step_ufw
    step_fail2ban
    step_unattended
    step_docker
    step_layout
    step_proxy
    step_summary
}

main "$@"
