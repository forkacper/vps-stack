#!/usr/bin/env bash
# Optional status page: a read-only view of the server's resources and
# containers, served by Caddy under its own domain behind a login. Disabled
# by default. See docs/monitoring.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=lib/validate.sh
source "${SCRIPT_DIR}/../lib/validate.sh"
# shellcheck source=lib/monitor.sh
source "${SCRIPT_DIR}/../lib/monitor.sh"

SERVICE_NAME="vps-stack-monitor"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TMPFILES_FILE="/etc/tmpfiles.d/vps-stack-monitor.conf"
F2B_JAIL_NAME="vps-stack-monitor"
F2B_FILTER_FILE="/etc/fail2ban/filter.d/vps-stack-monitor.conf"
F2B_ACTION_FILE="/etc/fail2ban/action.d/vps-stack-monitor.conf"
F2B_JAIL_FILE="/etc/fail2ban/jail.d/vps-stack-monitor.local"
STATUS_FILE="${MONITOR_RUN_DIR}/status.json"
# History: one sample every HISTORY_INTERVAL seconds, kept for 7 days in a
# file that survives reboots, published for the page as history.json.
HISTORY_FILE="${MONITOR_STATE_DIR}/history.jsonl"
HISTORY_JSON="${MONITOR_RUN_DIR}/history.json"
HISTORY_INTERVAL="${VPS_STACK_MONITOR_HISTORY_INTERVAL:-300}"
HISTORY_SAMPLES=2016
LOG_FILE="${MONITOR_LOG_DIR}/access.log"
BAN_LOCK_FILE="${VPS_STACK_MONITOR_BAN_LOCK:-/run/lock/vps-stack-monitor-ban.lock}"
VPS_STACK_BIN="${REPO_ROOT}/bin/vps-stack"
PROXY_SCRIPT="${SCRIPT_DIR}/proxy.sh"
INTERVAL=10
# The password is 144 random bits, so the bcrypt cost adds nothing against
# guessing; a lower cost only makes a flood of login attempts cheaper for
# the server's CPU.
BCRYPT_COST=10
BAN_LIST_HEADER="# vps-stack monitor: banned addresses, one per line (managed by fail2ban)."

usage() {
    cat <<USAGE
Usage: sudo vps-stack monitor <command> [options]

Optional status page: server resources and containers, read-only, at its own
domain behind a login. Disabled by default.

Commands:
  enable <domain>   enable the status page at https://<domain>
                    --user <login>         login (default: generated)
                    --server-ip <address>  public address for the DNS check
                    --no-dns-check         skip the DNS check
                    --dry-run, --yes
  disable           remove the status page, its collector and fail2ban jail
                    (--dry-run, --yes)
  password          generate a new password (--yes)
  refresh           after updating vps-stack: update the site file and the
                    collector of an enabled status page, keeping the password
  status            state of the status page, collector and bans

Used by the system:
  collect [--once]  write status.json every ${INTERVAL} seconds (the systemd service)
  ban <ip>, unban <ip>, ban-reset
                    update the ban list of the status page (fail2ban action)

What the page shows and how it is protected: ${REPO_ROOT}/docs/monitoring.md
USAGE
}

# --- helpers ----------------------------------------------------------------

monitor_enabled() { [[ -f "${MONITOR_ENV_FILE}" ]]; }

load_monitor_env() {
    MONITOR_DOMAIN=""
    MONITOR_USER=""
    load_env_file "${MONITOR_ENV_FILE}"
    [[ -n "${MONITOR_DOMAIN}" && -n "${MONITOR_USER}" ]] ||
        die "${MONITOR_ENV_FILE} is incomplete (MONITOR_DOMAIN, MONITOR_USER)."
}

require_enabled() {
    monitor_enabled || die "The status page is not enabled. Enable it: sudo vps-stack monitor enable <domain>"
    load_monitor_env
}

# The 3 random bytes give 4 base64 characters, mapped to lowercase.
generate_user() {
    printf 'monitor-%s\n' "$(head -c 3 /dev/urandom | base64 | tr 'A-Z+/' 'a-zxy')"
}

# 18 random bytes: 24 characters, 144 bits.
generate_password() {
    head -c 18 /dev/urandom | base64 | tr '+/' 'xy'
}

caddy_image() {
    awk '$1 == "image:" && $2 ~ /^caddy:/ { print $2; exit }' "${REPO_ROOT}/proxy/docker-compose.yml"
}

# hash_password <password>: print the bcrypt hash. The password goes through
# stdin, never as an argument visible in the process list. `caddy
# hash-password` reads it up to the newline.
hash_password() {
    local hash
    if caddy_running; then
        hash="$(printf '%s\n' "$1" | docker exec -i "${CADDY_CONTAINER}" caddy hash-password --bcrypt-cost "${BCRYPT_COST}")"
    else
        hash="$(printf '%s\n' "$1" | docker run --rm -i "$(caddy_image)" caddy hash-password --bcrypt-cost "${BCRYPT_COST}")"
    fi
    validate_bcrypt_hash "${hash}" || return 1
    printf '%s\n' "${hash}"
}

render_site_file() {
    monitor_site_render "${REPO_ROOT}/templates/site-monitor.caddy.tmpl" "$1" "$2" "$3"
}

service_active() { systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; }

fail2ban_active() { have_cmd fail2ban-client && systemctl is-active --quiet fail2ban 2>/dev/null; }

jail_running() { fail2ban-client status "${F2B_JAIL_NAME}" >/dev/null 2>&1; }

print_credentials() {
    cat <<CREDENTIALS

  Address:  https://${1}
  Login:    ${2}
  Password: ${3}

Save the password in your password manager NOW. It is shown only once and
is not stored anywhere (the server keeps only a hash). A new one:
  sudo vps-stack monitor password
CREDENTIALS
}

# --- collector --------------------------------------------------------------

PREV_CPU_TOTAL=""
PREV_CPU_IDLE=""
# 1 in the collector loop; `collect --once` only refreshes the current state.
COLLECT_HISTORY=0
# The current history window: its start, the CPU counters at its start and
# the highest 10-second CPU value seen in it.
WINDOW_START=""
WINDOW_CPU_TOTAL=""
WINDOW_CPU_IDLE=""
WINDOW_CPU_MAX=""

# publish_history: write history.json for the page from the history file.
publish_history() {
    local json tmp
    json="$(monitor_history_json "${HISTORY_FILE}" "${HISTORY_INTERVAL}")" || return 1
    tmp="$(mktemp "${MONITOR_RUN_DIR}/.history.json.XXXXXX")" || return 1
    if ! printf '%s\n' "${json}" >"${tmp}" || ! chmod 644 "${tmp}" || ! mv -f "${tmp}" "${HISTORY_JSON}"; then
        rm -f "${tmp}"
        return 1
    fi
}

# record_history <total> <idle> <host json> <containers json>: when the
# window is over, append one sample, keep 7 days and publish.
record_history() {
    local total="$1" idle="$2" host="$3" containers="$4" avg sample
    if [[ -z "${WINDOW_START}" ]]; then
        WINDOW_START="${SECONDS}"
        WINDOW_CPU_TOTAL="${total}"
        WINDOW_CPU_IDLE="${idle}"
        return 0
    fi
    [[ $((SECONDS - WINDOW_START)) -ge "${HISTORY_INTERVAL}" ]] || return 0
    avg="$(monitor_cpu_percent "${WINDOW_CPU_TOTAL}" "${WINDOW_CPU_IDLE}" "${total}" "${idle}")"
    sample="$(monitor_history_sample "$(date +%s)" "${avg}" "${WINDOW_CPU_MAX}" "${host}" "${containers}")" || return 1
    WINDOW_START="${SECONDS}"
    WINDOW_CPU_TOTAL="${total}"
    WINDOW_CPU_IDLE="${idle}"
    WINDOW_CPU_MAX=""
    printf '%s\n' "${sample}" >>"${HISTORY_FILE}" || return 1
    monitor_history_trim "${HISTORY_FILE}" "${HISTORY_SAMPLES}" || return 1
    publish_history
}

# collect_once: write status.json. Every step is checked explicitly: the
# loop calls this in a context where `set -e` does not apply.
collect_once() {
    local total idle cpu="" disk_total disk_used reboot=false docker_ok=false
    local ids inspect="" stats="" host containers json tmp

    read -r total idle < <(monitor_cpu_sample /proc/stat) || return 1
    if [[ -z "${PREV_CPU_TOTAL}" ]]; then
        # First sample: take a second one, so the page never starts empty.
        PREV_CPU_TOTAL="${total}"
        PREV_CPU_IDLE="${idle}"
        sleep 1
        read -r total idle < <(monitor_cpu_sample /proc/stat) || return 1
    fi
    cpu="$(monitor_cpu_percent "${PREV_CPU_TOTAL}" "${PREV_CPU_IDLE}" "${total}" "${idle}")"
    PREV_CPU_TOTAL="${total}"
    PREV_CPU_IDLE="${idle}"
    WINDOW_CPU_MAX="$(monitor_max "${WINDOW_CPU_MAX}" "${cpu}")"

    read -r disk_total disk_used < <(df -P -B1 / | awk 'NR == 2 { print $2, $3 }') || return 1
    [[ -e /var/run/reboot-required ]] && reboot=true

    # Only the fields of MONITOR_INSPECT_FORMAT and MONITOR_STATS_FORMAT are
    # asked for. A container that disappears between the calls is skipped.
    if ids="$(docker ps -aq 2>/dev/null)"; then
        docker_ok=true
        if [[ -n "${ids}" ]]; then
            # shellcheck disable=SC2086  # word splitting wanted: list of IDs
            inspect="$(docker inspect --format "${MONITOR_INSPECT_FORMAT}" ${ids} 2>/dev/null || true)"
            stats="$(docker stats --no-stream --format "${MONITOR_STATS_FORMAT}" 2>/dev/null || true)"
        fi
    fi

    host="$(monitor_host_json /proc "$(uname -n)" "$(nproc)" "${cpu}" "${disk_total}" "${disk_used}" "${reboot}")" || return 1
    containers="$(monitor_containers_json "${inspect}" "${stats}")" || return 1
    json="$(monitor_status_json "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${INTERVAL}" "${docker_ok}" "${host}" "${containers}")" || return 1

    # Written next to the target and renamed: a reader never sees half a
    # file, and the directory mount in Caddy sees the new file at once.
    tmp="$(mktemp "${MONITOR_RUN_DIR}/.status.json.XXXXXX")" || return 1
    if ! printf '%s\n' "${json}" >"${tmp}" || ! chmod 644 "${tmp}" || ! mv -f "${tmp}" "${STATUS_FILE}"; then
        rm -f "${tmp}"
        return 1
    fi
    if [[ "${COLLECT_HISTORY}" == "1" ]]; then
        record_history "${total}" "${idle}" "${host}" "${containers}" || return 1
    fi
}

cmd_collect() {
    local once=0 started elapsed
    case "${1:-}" in
        --once) once=1 ;;
        "") ;;
        *) die "Unknown option: $1" ;;
    esac
    require_root
    require_cmd docker jq df nproc
    [[ -d "${MONITOR_RUN_DIR}" ]] || die "${MONITOR_RUN_DIR} does not exist. Enable the status page: vps-stack monitor enable <domain>"
    [[ -d "${MONITOR_STATE_DIR}" ]] || die "${MONITOR_STATE_DIR} does not exist. Run: sudo vps-stack monitor refresh"

    # The history collected before a reboot is on the page right away.
    publish_history || log_warn "Could not write ${HISTORY_JSON}."
    if [[ "${once}" == "1" ]]; then
        COLLECT_HISTORY=0
        collect_once || die "Could not write ${STATUS_FILE}."
        return 0
    fi
    COLLECT_HISTORY=1
    while true; do
        started="${SECONDS}"
        collect_once || log_warn "Could not write ${STATUS_FILE}; trying again in ${INTERVAL} s."
        elapsed=$((SECONDS - started))
        sleep "$((elapsed < INTERVAL ? INTERVAL - elapsed : 1))"
    done
}

# --- bans -------------------------------------------------------------------

# ban_update <add|remove|reset> [ip]: change the ban list and reload Caddy.
# Called by fail2ban. When Caddy rejects the result, both files go back to
# their previous content and the running proxy stays as it was.
ban_update() {
    local operation="$1" ip="${2:-}" old_list="" old_snippet="" new_list snippet
    local -a addresses=()

    if ! monitor_enabled; then
        log_info "The status page is not enabled: nothing to do."
        return 0
    fi
    if [[ "${operation}" != "reset" ]]; then
        ip="$(normalize_ip "${ip}")" || exit 2
        if [[ "${operation}" == "add" ]] && ! ip_is_public "${ip}"; then
            log_warn "Not banning ${ip}: not a public address (private, Docker or reserved)."
            return 0
        fi
    fi

    require_cmd flock
    exec 8>"${BAN_LOCK_FILE}"
    flock -w 60 8 || die "Another ban update is still running (${BAN_LOCK_FILE})."

    [[ -f "${MONITOR_BAN_LIST}" ]] && old_list="$(cat "${MONITOR_BAN_LIST}")"
    [[ -f "${MONITOR_BAN_SNIPPET}" ]] && old_snippet="$(cat "${MONITOR_BAN_SNIPPET}")"

    if [[ "${operation}" == "reset" ]]; then
        new_list=""
    else
        new_list="$(monitor_banlist_apply "${operation}" "${ip}" <<<"${old_list}")" || die "Invalid address: ${ip}"
    fi
    if [[ -n "${new_list}" ]]; then
        mapfile -t addresses <<<"${new_list}"
    fi
    snippet="$(monitor_ban_snippet "${addresses[@]+"${addresses[@]}"}")" || die "Could not render the ban list."

    write_file --no-backup "${MONITOR_BAN_LIST}" 600 <<<"${BAN_LIST_HEADER}${new_list:+$'\n'${new_list}}"
    write_file --no-backup "${MONITOR_BAN_SNIPPET}" 644 <<<"${snippet}"
    if [[ "${WRITE_FILE_CHANGED}" != "1" ]] || is_dry_run || ! caddy_running; then
        return 0
    fi
    if ! "${PROXY_SCRIPT}" reload >/dev/null; then
        if [[ -n "${old_list}" ]]; then
            write_file --no-backup "${MONITOR_BAN_LIST}" 600 <<<"${old_list}"
        fi
        if [[ -n "${old_snippet}" ]]; then
            write_file --no-backup "${MONITOR_BAN_SNIPPET}" 644 <<<"${old_snippet}"
        fi
        die "Caddy rejected the new ban list; the previous one was restored."
    fi
    log_info "Ban list of the status page: ${#addresses[@]} address(es)."
}

# --- enable -----------------------------------------------------------------

write_tmpfiles_and_dirs() {
    local content
    content="$(render_template "${REPO_ROOT}/templates/vps-stack-monitor-tmpfiles.conf" "RUN_DIR=${MONITOR_RUN_DIR}")"
    write_file "${TMPFILES_FILE}" 644 <<<"${content}"
    run install -d -m 755 -o root -g root "${MONITOR_RUN_DIR}"
    run install -d -m 700 -o root -g root "${MONITOR_LOG_DIR}" "${MONITOR_STATE_DIR}"
    if [[ ! -e "${LOG_FILE}" ]]; then
        # fail2ban refuses a jail whose log file does not exist yet.
        run install -m 600 -o root -g root /dev/null "${LOG_FILE}"
    fi
}

install_service() {
    local content
    content="$(render_template "${REPO_ROOT}/templates/vps-stack-monitor.service.tmpl" \
        "VPS_STACK_BIN=${VPS_STACK_BIN}" "RUN_DIR=${MONITOR_RUN_DIR}" "STATE_DIR=${MONITOR_STATE_DIR}")"
    write_file "${SERVICE_FILE}" 644 <<<"${content}"
    run systemctl daemon-reload
    run systemctl enable --quiet "${SERVICE_NAME}.service"
    run systemctl restart "${SERVICE_NAME}.service"
}

remove_service() {
    if [[ -f "${SERVICE_FILE}" ]]; then
        run systemctl disable --quiet --now "${SERVICE_NAME}.service" || true
        run rm -f "${SERVICE_FILE}"
        run systemctl daemon-reload
    fi
}

install_fail2ban() {
    local content ignoreip=""
    if ! have_cmd fail2ban-client; then
        log_warn "fail2ban is not installed: failed logins on the status page will not be banned."
        return 0
    fi
    # FAIL2BAN_IGNOREIP was validated by provision; checked again, because
    # it lands in a configuration file.
    if [[ -n "${FAIL2BAN_IGNOREIP}" ]]; then
        [[ "${FAIL2BAN_IGNOREIP}" =~ ^[0-9a-fA-F.:/\ ]*$ ]] ||
            die "FAIL2BAN_IGNOREIP in ${STACK_ENV_FILE} contains characters that are not allowed."
        ignoreip=" ${FAIL2BAN_IGNOREIP}"
    fi
    write_file "${F2B_FILTER_FILE}" 644 <"${REPO_ROOT}/templates/fail2ban-monitor-filter.conf"
    content="$(render_template "${REPO_ROOT}/templates/fail2ban-monitor-action.conf" "VPS_STACK_BIN=${VPS_STACK_BIN}")"
    write_file "${F2B_ACTION_FILE}" 644 <<<"${content}"
    content="$(render_template "${REPO_ROOT}/templates/fail2ban-monitor-jail.conf" \
        "LOG_FILE=${LOG_FILE}" "IGNOREIP=${ignoreip}")"
    write_file "${F2B_JAIL_FILE}" 644 <<<"${content}"
    if is_dry_run; then
        return 0
    fi
    if ! fail2ban_active; then
        log_warn "fail2ban is not running: the jail ${F2B_JAIL_NAME} starts with it."
        return 0
    fi
    fail2ban-client reload >/dev/null 2>&1 || log_warn "fail2ban-client reload failed. Check: journalctl -u fail2ban"
    local i
    for ((i = 0; i < 10; i++)); do
        if jail_running; then
            log_ok "fail2ban jail ${F2B_JAIL_NAME} is active."
            return 0
        fi
        sleep 1
    done
    log_warn "The fail2ban jail ${F2B_JAIL_NAME} did not start. Check: journalctl -u fail2ban"
}

remove_fail2ban() {
    local file changed=0
    for file in "${F2B_JAIL_FILE}" "${F2B_ACTION_FILE}" "${F2B_FILTER_FILE}"; do
        if [[ -f "${file}" ]]; then
            run rm -f "${file}"
            changed=1
        fi
    done
    if [[ "${changed}" == "1" ]] && ! is_dry_run && fail2ban_active; then
        fail2ban-client reload >/dev/null 2>&1 || log_warn "fail2ban-client reload failed. Check: journalctl -u fail2ban"
    fi
}

# Undo the files written by enable. The proxy is still running its previous
# configuration at this point.
rollback_enable_files() {
    log_warn "Rolling back the status page files."
    rm -f "${MONITOR_SITE_FILE}" "${MONITOR_ENV_FILE}" "${MONITOR_BAN_SNIPPET}" "${MONITOR_BAN_LIST}"
    remove_service
}

cmd_enable() {
    local raw_domain="" domain user="" dns_check=1 password hash content snippet
    SERVER_IPS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)
                [[ $# -ge 2 ]] || die "Option --user needs a value."
                user="$2"
                shift
                ;;
            --server-ip)
                [[ $# -ge 2 ]] || die "Option --server-ip needs a value."
                SERVER_IPS+=("$2")
                shift
                ;;
            --no-dns-check) dns_check=0 ;;
            --dry-run) DRY_RUN=1 ;;
            --yes | -y) ASSUME_YES=1 ;;
            -*) die "Unknown option: $1" ;;
            *)
                [[ -z "${raw_domain}" ]] || die "Give exactly one domain."
                raw_domain="$1"
                ;;
        esac
        shift
    done
    [[ -n "${raw_domain}" ]] || {
        usage >&2
        exit 2
    }
    domain="$(normalize_domain "${raw_domain}")" || exit 2
    if [[ -n "${user}" ]]; then
        validate_monitor_user "${user}" || exit 2
    else
        user="$(generate_user)"
    fi

    require_root
    require_etc_access write
    require_cmd docker jq systemctl flock
    stack_config_load "${STACK_ENV_FILE}"
    [[ -d "${SITES_DIR}" ]] || die "Directory ${SITES_DIR} does not exist. Run 'vps-stack provision' first."
    if monitor_enabled; then
        load_monitor_env
        die "The status page is already enabled at ${MONITOR_DOMAIN}. To move it: vps-stack monitor disable, then enable again."
    fi
    site_refuse_duplicates "${MONITOR_SITE_FILE}" "${domain}"

    if [[ "${dns_check}" == "1" ]]; then
        dns_check_or_confirm "${domain}"
    else
        log_warn "DNS check skipped (--no-dns-check)."
    fi

    cat <<SUMMARY

Status page
  Address:   https://${domain}
  Login:     ${user} (the password is generated and shown once at the end)
  Shows:     CPU, memory, swap, disk, load; containers with image, state,
             health, restarts, CPU and memory. Never environment variables,
             labels, mounts, ports or logs.
  Protects:  login and password; fail2ban bans an address after 5 failed
             logins in 10 minutes, on the status page only.
  Changes:   a collector service (${SERVICE_NAME}), a site file, a fail2ban jail,
             and the proxy container is RESTARTED with two extra mounts
             (a few seconds without any site).
SUMMARY
    confirm "Enable the status page?" || die "Aborted. Nothing was changed."

    if is_dry_run; then
        log_dry "generate a password and its bcrypt hash (caddy hash-password)"
        log_dry "write ${MONITOR_BAN_LIST}, ${MONITOR_BAN_SNIPPET}, ${MONITOR_SITE_FILE} (600), ${MONITOR_ENV_FILE} (600)"
        write_tmpfiles_and_dirs
        install_service
        log_dry "validate the configuration, then: vps-stack proxy restart"
        install_fail2ban
        exit 0
    fi

    password="$(generate_password)"
    hash="$(hash_password "${password}")" || die "Could not hash the password with Caddy."
    content="$(render_site_file "${domain}" "${user}" "${hash}")" || die "Could not render the site file."

    # 1. Files. The ban list comes before the site file that imports it.
    write_tmpfiles_and_dirs
    write_file --no-backup "${MONITOR_BAN_LIST}" 600 <<<"${BAN_LIST_HEADER}"
    snippet="$(monitor_ban_snippet)"
    write_file --no-backup "${MONITOR_BAN_SNIPPET}" 644 <<<"${snippet}"
    write_file --no-backup "${MONITOR_SITE_FILE}" 600 <<<"${content}"
    write_file --no-backup "${MONITOR_ENV_FILE}" 600 <<<"MONITOR_DOMAIN=${domain}"$'\n'"MONITOR_USER=${user}"

    # 2. The collector, so the page has data from the first request.
    install_service
    if ! "${VPS_STACK_BIN}" monitor collect --once; then
        rollback_enable_files
        die "The collector could not write ${STATUS_FILE}. Nothing else was changed."
    fi

    # 3. The proxy: validate with the new mounts first, then recreate.
    if ! "${PROXY_SCRIPT}" validate fresh; then
        rollback_enable_files
        die "Caddy rejected the configuration. The proxy runs unchanged."
    fi
    if ! "${PROXY_SCRIPT}" restart; then
        rollback_enable_files
        "${PROXY_SCRIPT}" restart || true
        die "Restarting the proxy failed. The status page was rolled back. Check: vps-stack proxy logs"
    fi

    # 4. fail2ban. Not fatal: the page works without it.
    install_fail2ban

    log_ok "The status page is enabled."
    print_credentials "${domain}" "${user}" "${password}"
}

# --- disable ----------------------------------------------------------------

cmd_disable() {
    local removed_dir target
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --yes | -y) ASSUME_YES=1 ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
    require_root
    require_etc_access write
    require_enabled

    log_info "The status page at ${MONITOR_DOMAIN} will be removed, together with its collector and fail2ban jail."
    log_info "The proxy container is restarted without the extra mounts (a few seconds without any site)."
    confirm "Disable the status page?" || die "Aborted."

    removed_dir="${SITES_DIR}/.removed"
    target="${removed_dir}/_monitor.caddy.$(date +%Y%m%d-%H%M%S)"

    # 1. The proxy first: if this fails, nothing else has changed.
    run install -d -m 700 "${removed_dir}"
    run mv "${MONITOR_SITE_FILE}" "${target}"
    run mv "${MONITOR_ENV_FILE}" "${MONITOR_ENV_FILE}.disabling"
    if ! is_dry_run && ! "${PROXY_SCRIPT}" restart; then
        mv "${target}" "${MONITOR_SITE_FILE}"
        mv "${MONITOR_ENV_FILE}.disabling" "${MONITOR_ENV_FILE}"
        die "Restarting the proxy failed. The status page files were restored; fix the cause (vps-stack proxy validate fresh) and run this command again."
    fi
    run rm -f "${MONITOR_ENV_FILE}.disabling"

    # 2. Everything else.
    remove_service
    remove_fail2ban
    run rm -f "${MONITOR_BAN_SNIPPET}" "${MONITOR_BAN_LIST}" "${TMPFILES_FILE}"
    run rm -rf "${MONITOR_RUN_DIR}" "${MONITOR_STATE_DIR}"

    log_ok "The status page is disabled. Copy of the site file: ${target}"
    log_info "The access logs stay in ${MONITOR_LOG_DIR}; remove the directory if you do not need them."
    log_info "The DNS record of ${MONITOR_DOMAIN} stays; remove it at your domain provider if it is no longer needed."
}

# --- password ---------------------------------------------------------------

cmd_password() {
    local password hash content old_content
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes | -y) ASSUME_YES=1 ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
    require_root
    require_etc_access write
    require_cmd docker
    require_enabled

    confirm "Generate a new password for ${MONITOR_USER} at ${MONITOR_DOMAIN}? The current one stops working." ||
        die "Aborted."
    password="$(generate_password)"
    hash="$(hash_password "${password}")" || die "Could not hash the password with Caddy."
    content="$(render_site_file "${MONITOR_DOMAIN}" "${MONITOR_USER}" "${hash}")" || die "Could not render the site file."
    old_content="$(cat "${MONITOR_SITE_FILE}")"

    write_file --no-backup "${MONITOR_SITE_FILE}" 600 <<<"${content}"
    if caddy_running && ! "${PROXY_SCRIPT}" reload; then
        write_file --no-backup "${MONITOR_SITE_FILE}" 600 <<<"${old_content}"
        die "Caddy rejected the new configuration. The previous password still works."
    fi
    log_ok "New password set."
    print_credentials "${MONITOR_DOMAIN}" "${MONITOR_USER}" "${password}"
}

# --- refresh ----------------------------------------------------------------

# cmd_refresh: after an update of vps-stack, bring an enabled status page in
# line with the new templates (site file, collector service, fail2ban jail).
# The password stays: its hash is taken from the current site file.
cmd_refresh() {
    local hash content old_content
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes | -y) ASSUME_YES=1 ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
    require_root
    require_etc_access write
    require_cmd docker systemctl
    require_enabled

    hash="$(awk 'found && NF == 2 { print $2; exit } /basic_auth \{/ { found = 1 }' "${MONITOR_SITE_FILE}")"
    validate_bcrypt_hash "${hash}" 2>/dev/null ||
        die "Cannot read the password hash from ${MONITOR_SITE_FILE}. Set a new password instead: vps-stack monitor password"
    content="$(render_site_file "${MONITOR_DOMAIN}" "${MONITOR_USER}" "${hash}")" || die "Could not render the site file."
    old_content="$(cat "${MONITOR_SITE_FILE}")"

    write_tmpfiles_and_dirs
    install_service
    write_file --no-backup "${MONITOR_SITE_FILE}" 600 <<<"${content}"
    if [[ "${WRITE_FILE_CHANGED}" == "1" ]] && caddy_running && ! "${PROXY_SCRIPT}" reload; then
        write_file --no-backup "${MONITOR_SITE_FILE}" 600 <<<"${old_content}"
        die "Caddy rejected the new site file. The previous one was restored."
    fi
    install_fail2ban
    log_ok "The status page at ${MONITOR_DOMAIN} is up to date. The password did not change."
}

# --- status -----------------------------------------------------------------

cmd_status() {
    local age="" bans=0 line
    [[ $# -eq 0 ]] || die "Unknown argument: $1"
    require_root
    if ! monitor_enabled; then
        log_info "The status page is disabled. Enable it: sudo vps-stack monitor enable <domain>"
        return 0
    fi
    load_monitor_env
    printf 'Address:     https://%s\n' "${MONITOR_DOMAIN}"
    printf 'Login:       %s\n' "${MONITOR_USER}"
    if service_active; then
        printf 'Collector:   running (%s)\n' "${SERVICE_NAME}"
    else
        printf 'Collector:   NOT running (journalctl -u %s)\n' "${SERVICE_NAME}"
    fi
    if [[ -f "${STATUS_FILE}" ]]; then
        age=$(($(date +%s) - $(date -r "${STATUS_FILE}" +%s)))
        printf 'Data:        written %s s ago\n' "${age}"
    else
        printf 'Data:        %s does not exist\n' "${STATUS_FILE}"
    fi
    if [[ -s "${HISTORY_FILE}" ]]; then
        printf 'History:     %s samples, the oldest from %s\n' "$(wc -l <"${HISTORY_FILE}" | tr -d ' ')" \
            "$(head -n 1 "${HISTORY_FILE}" | jq -r '.t | todate' 2>/dev/null || printf 'unknown')"
    else
        printf 'History:     none yet (one sample every %s s)\n' "${HISTORY_INTERVAL}"
    fi
    if caddy_running; then
        printf 'Proxy:       running\n'
    else
        printf 'Proxy:       NOT running (vps-stack proxy up)\n'
    fi
    if have_cmd fail2ban-client && jail_running; then
        line="$(fail2ban-client status "${F2B_JAIL_NAME}" 2>/dev/null | grep -i 'currently banned' | awk -F: '{ gsub(/[[:space:]]/, "", $2); print $2 }' || true)"
        printf 'fail2ban:    jail active, %s address(es) banned now\n' "${line:-0}"
    else
        printf 'fail2ban:    jail NOT active\n'
    fi
    if [[ -f "${MONITOR_BAN_LIST}" ]]; then
        bans="$(grep -cvE '^(#|$)' "${MONITOR_BAN_LIST}" || true)"
    fi
    printf 'Ban list:    %s address(es) blocked in Caddy\n' "${bans}"
}

main() {
    local command="${1:-}"
    [[ $# -gt 0 ]] && shift
    case "${command}" in
        "" | help | -h | --help) usage ;;
        enable) cmd_enable "$@" ;;
        disable) cmd_disable "$@" ;;
        password) cmd_password "$@" ;;
        status) cmd_status "$@" ;;
        refresh) cmd_refresh "$@" ;;
        collect) cmd_collect "$@" ;;
        ban)
            require_root
            [[ $# -eq 1 ]] || die "Usage: vps-stack monitor ban <ip>"
            ban_update add "$1"
            ;;
        unban)
            require_root
            [[ $# -eq 1 ]] || die "Usage: vps-stack monitor unban <ip>"
            ban_update remove "$1"
            ;;
        ban-reset)
            require_root
            ban_update reset
            ;;
        *)
            usage >&2
            die "Unknown command: ${command}"
            ;;
    esac
}

main "$@"
