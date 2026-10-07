#!/usr/bin/env bash
# Check the state of the server. Read-only: changes nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=lib/os-detect.sh
source "${SCRIPT_DIR}/../lib/os-detect.sh"

usage() {
    cat <<USAGE
Usage: sudo vps-stack verify

Checks the state of the server and prints an OK / WARN / ERROR table. Changes
nothing. The exit code is non-zero when there is at least one ERROR.
USAGE
}

check_sshd() {
    local effective ports
    if ! effective="$(sshd -T 2>/dev/null)"; then
        report_add "ERROR" "SSH: configuration" "sshd -T fails"
        return 0
    fi
    if grep -qx 'passwordauthentication no' <<<"${effective}"; then
        report_add "OK" "SSH: password login" "disabled"
    else
        report_add "ERROR" "SSH: password login" "ENABLED (PasswordAuthentication)"
    fi
    if grep -qx 'permitrootlogin no' <<<"${effective}"; then
        report_add "OK" "SSH: root login" "disabled"
    else
        report_add "ERROR" "SSH: root login" "allowed: $(grep '^permitrootlogin ' <<<"${effective}" || true)"
    fi
    if grep -qx "allowusers ${ADMIN_USER}" <<<"${effective}"; then
        report_add "OK" "SSH: AllowUsers" "$(grep '^allowusers ' <<<"${effective}" | awk '{ print $2 }' | tr '\n' ' ')"
    else
        report_add "ERROR" "SSH: AllowUsers" "${ADMIN_USER} is not on the list"
    fi
    ports="$(os_ssh_ports 2>/dev/null | tr '\n' ' ' || true)"
    ports="${ports% }"
    if [[ "${ports}" == "${SSH_PORT}" ]]; then
        report_add "OK" "SSH: port" "${ports} (mode: $(os_ssh_mode))"
    else
        report_add "WARN" "SSH: port" "sshd listens on '${ports}' but SSH_PORT=${SSH_PORT}"
    fi
}

check_ufw() {
    local status
    if ! have_cmd ufw; then
        report_add "ERROR" "Firewall (ufw)" "ufw is not installed"
        return 0
    fi
    status="$(LC_ALL=C ufw status verbose 2>/dev/null || true)"
    if ! grep -q '^Status: active' <<<"${status}"; then
        report_add "ERROR" "Firewall (ufw)" "inactive"
        return 0
    fi
    if grep -q '^Default: deny (incoming)' <<<"${status}"; then
        report_add "OK" "Firewall: policy" "deny incoming"
    else
        report_add "ERROR" "Firewall: policy" "$(grep '^Default:' <<<"${status}" || true)"
    fi
    if grep -qE "^${SSH_PORT}/tcp[[:space:]]+ALLOW IN" <<<"${status}"; then
        report_add "OK" "Firewall: SSH rule" "${SSH_PORT}/tcp"
    else
        report_add "ERROR" "Firewall: SSH rule" "no ALLOW for ${SSH_PORT}/tcp"
    fi
}

check_fail2ban() {
    if have_cmd fail2ban-client && fail2ban-client status sshd >/dev/null 2>&1; then
        report_add "OK" "fail2ban" "sshd jail active"
    else
        report_add "WARN" "fail2ban" "sshd jail not running"
    fi
}

check_docker() {
    local info health
    if ! have_cmd docker; then
        report_add "WARN" "Docker" "not installed"
        return 0
    fi
    if ! info="$(docker info --format '{{.LoggingDriver}} {{.LiveRestoreEnabled}}' 2>/dev/null)"; then
        report_add "ERROR" "Docker" "daemon not responding"
        return 0
    fi
    if [[ "${info}" == "json-file true" ]]; then
        report_add "OK" "Docker: daemon" "log-driver json-file, live-restore"
    else
        report_add "WARN" "Docker: daemon" "log-driver and live-restore: ${info}"
    fi
    if have_cmd jq && [[ "$(jq -r '."log-opts"."max-size" // empty' /etc/docker/daemon.json 2>/dev/null)" != "" ]]; then
        report_add "OK" "Docker: log rotation" "max-size $(jq -r '."log-opts"."max-size"' /etc/docker/daemon.json)"
    else
        report_add "WARN" "Docker: log rotation" "no log-opts.max-size in /etc/docker/daemon.json"
    fi

    health="$(docker inspect -f '{{.State.Status}}{{if .State.Health}} {{.State.Health.Status}}{{end}}' "${CADDY_CONTAINER}" 2>/dev/null || true)"
    case "${health}" in
        "running healthy") report_add "OK" "Proxy (Caddy)" "running" ;;
        "running"*) report_add "WARN" "Proxy (Caddy)" "state: ${health}" ;;
        "") report_add "ERROR" "Proxy (Caddy)" "container does not exist (vps-stack proxy up)" ;;
        *) report_add "ERROR" "Proxy (Caddy)" "state: ${health}" ;;
    esac
}

check_memory_and_disk() {
    local swappiness used
    if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
        report_add "OK" "Swap" "active"
    elif [[ "${SWAP_SIZE}" == "0" ]]; then
        report_add "OK" "Swap" "disabled in the configuration"
    else
        report_add "WARN" "Swap" "no active swap"
    fi
    swappiness="$(sysctl -n vm.swappiness 2>/dev/null || true)"
    if [[ "${swappiness}" == "10" ]]; then
        report_add "OK" "vm.swappiness" "10"
    else
        report_add "WARN" "vm.swappiness" "${swappiness:-unknown} (expected 10)"
    fi

    used="$(df -P / | awk 'NR == 2 { gsub("%", "", $5); print $5 }')"
    if [[ "${used}" -gt 90 ]]; then
        report_add "ERROR" "Disk space on /" "${used}% used"
    elif [[ "${used}" -gt 70 ]]; then
        report_add "WARN" "Disk space on /" "${used}% used (threshold 70%)"
    else
        report_add "OK" "Disk space on /" "${used}% used"
    fi

    if [[ -e /var/run/reboot-required ]]; then
        report_add "WARN" "System reboot" "required after updates (/var/run/reboot-required)"
    else
        report_add "OK" "System reboot" "not required"
    fi
}

check_ports() {
    local code=0
    "${SCRIPT_DIR}/check-ports.sh" || code=$?
    case "${code}" in
        0) report_add "OK" "Ports" "SSH, 80 and 443 only" ;;
        1) report_add "WARN" "Ports" "unexpected ports on the host (details above)" ;;
        *) report_add "ERROR" "Ports" "a container publishes a port bypassing ufw (details above)" ;;
    esac
}

check_permissions() {
    local file problems=""
    if [[ ! -d "${ETC_DIR}" ]]; then
        report_add "ERROR" "Permissions of ${ETC_DIR}" "directory does not exist"
        return 0
    fi
    file_has_mode "${ETC_DIR}" 700 || problems="${ETC_DIR} (expected 700)"
    if [[ -d "${HOOKS_DIR}" ]] && ! file_has_mode "${HOOKS_DIR}" 700; then
        problems="${problems:+${problems}, }${HOOKS_DIR} (700)"
    fi
    for file in "${STACK_ENV_FILE}" "${PROXY_ENV_FILE}" "${RESTIC_ENV_FILE}" "${RESTIC_PASSWORD_DEFAULT_FILE}" "${MONITOR_ENV_FILE}" "${MONITOR_SITE_FILE}"; do
        if [[ -e "${file}" ]] && ! file_has_mode "${file}" 600; then
            problems="${problems:+${problems}, }${file} (600)"
        fi
    done
    if [[ -n "${problems}" ]]; then
        report_add "ERROR" "Permissions of ${ETC_DIR}" "too permissive: ${problems}"
    else
        report_add "OK" "Permissions of ${ETC_DIR}" "700 / 600"
    fi
}

check_backup() {
    local last_ok="" candidate file now last_epoch age_hours
    if [[ ! -f /etc/cron.d/vps-stack-backup ]]; then
        report_add "WARN" "Backup: schedule" "no /etc/cron.d/vps-stack-backup (vps-stack backup setup)"
        return 0
    fi
    report_add "OK" "Backup: schedule" "cron installed"

    # The last rotated log (kept uncompressed) first, then the current one,
    # so the newest entry wins.
    for file in "${BACKUP_LOG_FILE}.1" "${BACKUP_LOG_FILE}"; do
        [[ -r "${file}" ]] || continue
        candidate="$(grep ' BACKUP_OK$' "${file}" | tail -n 1 | awk '{ print $1 }' || true)"
        if [[ -n "${candidate}" ]]; then
            last_ok="${candidate}"
        fi
    done
    if [[ -z "${last_ok}" ]]; then
        report_add "WARN" "Backup: last successful" "no successful backup in the log"
        return 0
    fi
    now="$(date -u +%s)"
    if ! last_epoch="$(date -u -d "${last_ok}" +%s 2>/dev/null)"; then
        report_add "WARN" "Backup: last successful" "${last_ok} (cannot compute its age)"
        return 0
    fi
    age_hours=$(((now - last_epoch) / 3600))
    if [[ "${age_hours}" -gt 48 ]]; then
        report_add "ERROR" "Backup: last successful" "${age_hours} h ago (${last_ok})"
    elif [[ "${age_hours}" -gt 13 ]]; then
        report_add "WARN" "Backup: last successful" "${age_hours} h ago (${last_ok})"
    else
        report_add "OK" "Backup: last successful" "${age_hours} h ago"
    fi
}

# check_monitor: only when the optional status page is enabled.
check_monitor() {
    local status_file="${MONITOR_RUN_DIR}/status.json" age
    [[ -f "${MONITOR_ENV_FILE}" ]] || return 0
    if systemctl is-active --quiet vps-stack-monitor.service 2>/dev/null; then
        report_add "OK" "Status page: collector" "running"
    else
        report_add "ERROR" "Status page: collector" "not running (journalctl -u vps-stack-monitor)"
    fi
    if [[ -f "${status_file}" ]]; then
        age=$(($(date +%s) - $(date -r "${status_file}" +%s)))
        if [[ "${age}" -le 60 ]]; then
            report_add "OK" "Status page: data" "${age} s old"
        else
            report_add "WARN" "Status page: data" "${age} s old (written every 10 s)"
        fi
    else
        report_add "WARN" "Status page: data" "${status_file} does not exist"
    fi
    if have_cmd fail2ban-client && fail2ban-client status vps-stack-monitor >/dev/null 2>&1; then
        report_add "OK" "Status page: fail2ban" "jail vps-stack-monitor active"
    else
        report_add "WARN" "Status page: fail2ban" "jail vps-stack-monitor not running"
    fi
}

main() {
    case "${1:-}" in
        -h | --help)
            usage
            exit 0
            ;;
        "") ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
    [[ "$(id -u)" -eq 0 ]] || die "verify needs root privileges (it reads the sshd and ufw configuration and ${ETC_DIR}). Run it with sudo."
    os_detect
    case "$(os_check_supported)" in
        ok | untested) ;;
        *) die "System ${OS_PRETTY_NAME} is not supported." ;;
    esac
    stack_config_load "${STACK_ENV_FILE}"

    check_sshd
    check_ufw
    check_fail2ban
    check_docker
    check_memory_and_disk
    check_ports
    check_permissions
    check_backup
    check_monitor

    report_print
    if [[ "${REPORT_ERRORS}" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
