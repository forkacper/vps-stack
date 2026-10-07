#!/usr/bin/env bash
# Change the SSH port in an order that cannot lock you out silently:
# open the new port in ufw, switch sshd, confirm from a NEW session, and only
# then close the old port. Never run from provision.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=lib/validate.sh
source "${SCRIPT_DIR}/../lib/validate.sh"
# shellcheck source=lib/os-detect.sh
source "${SCRIPT_DIR}/../lib/os-detect.sh"

SSHD_HARDENING_FILE="/etc/ssh/sshd_config.d/00-hardening.conf"
SOCKET_DROPIN_DIR="/etc/systemd/system/ssh.socket.d"
SOCKET_DROPIN_FILE="${SOCKET_DROPIN_DIR}/override.conf"

NEW_PORT=""
MODE=""
CHANGED_FILE=""

usage() {
    cat <<USAGE
Usage: sudo vps-stack ssh-port <port> [--dry-run]

Changes the SSH port in a safe order:
  1. opens the new port in ufw,
  2. switches sshd (through ssh.socket or the Port directive, depending on
     what it detects on the system),
  3. waits until you confirm from a NEW SSH session that login works (YES),
  4. only then closes the old port in ufw and saves SSH_PORT in
     ${STACK_ENV_FILE}.

The current SSH session stays open the whole time. Keep your provider's
rescue console at hand (docs/ssh-recovery.md).

Only ufw is changed. If your provider has a firewall in its panel (a cloud
firewall, security groups), open the new port there BEFORE running this.
USAGE
}

port_listening() {
    local listeners
    # Captured first: `producer | grep -q` is unreliable under pipefail.
    listeners="$(ss -H -tln 2>/dev/null | awk '{ print $4 }')"
    grep -qE "[:.]$1\$" <<<"${listeners}"
}

apply_change() {
    local content port_line
    if [[ "${MODE}" == "socket" ]]; then
        # With socket activation the listening port belongs to systemd.
        # `Port` in sshd_config changes nothing in this mode.
        content="# Managed by vps-stack (ssh-port). Manual edits are overwritten.
[Socket]
ListenStream=
ListenStream=0.0.0.0:${NEW_PORT}
ListenStream=[::]:${NEW_PORT}"
        run install -d -m 755 "${SOCKET_DROPIN_DIR}"
        write_file "${SOCKET_DROPIN_FILE}" 644 <<<"${content}"
        CHANGED_FILE="${SOCKET_DROPIN_FILE}"
        run systemctl daemon-reload
        run systemctl restart ssh.socket
    else
        [[ -f "${SSHD_HARDENING_FILE}" ]] ||
            die "${SSHD_HARDENING_FILE} not found. Run 'vps-stack provision' first."
        port_line=""
        if [[ "${NEW_PORT}" != "22" ]]; then
            port_line="Port ${NEW_PORT}"
        fi
        content="$(render_template "${REPO_ROOT}/templates/sshd-hardening.conf.tmpl" \
            "ALLOW_USERS=${ADMIN_USER} ${DEPLOY_USER}" "PORT_LINE=${port_line}")"
        write_file "${SSHD_HARDENING_FILE}" 644 <<<"${content}"
        CHANGED_FILE="${SSHD_HARDENING_FILE}"
        if ! run sshd -t; then
            restore_last_write "${SSHD_HARDENING_FILE}"
            die "sshd -t rejected the configuration. The previous state was restored, nothing was changed."
        fi
        # reload, not restart: existing sessions are never touched.
        run systemctl reload "$(os_ssh_service).service"
    fi
}

rollback_change() {
    log_warn "Rolling back the port change."
    restore_last_write "${CHANGED_FILE}"
    if [[ "${MODE}" == "socket" ]]; then
        run systemctl daemon-reload
        run systemctl restart ssh.socket || true
    else
        run systemctl reload "$(os_ssh_service).service" || true
    fi
    if have_cmd ufw; then
        run ufw delete allow "${NEW_PORT}/tcp" >/dev/null || true
    fi
}

finalize() {
    local old content
    for old in ${OLD_PORTS}; do
        if [[ "${old}" != "${NEW_PORT}" ]] && have_cmd ufw; then
            run ufw delete allow "${old}/tcp" >/dev/null || true
            log_info "Closed the old port ${old}/tcp in ufw."
        fi
    done

    content="$(grep -v '^SSH_PORT=' "${STACK_ENV_FILE}" || true)"$'\n'"SSH_PORT=${NEW_PORT}"
    write_file "${STACK_ENV_FILE}" 600 <<<"${content}"

    if [[ -f /etc/fail2ban/jail.local ]]; then
        content="$(render_template "${REPO_ROOT}/templates/jail.local.tmpl" \
            "BACKEND=$(os_fail2ban_backend)" \
            "IGNOREIP=${FAIL2BAN_IGNOREIP:+ ${FAIL2BAN_IGNOREIP}}" \
            "SSH_PORT=${NEW_PORT}")"
        write_file /etc/fail2ban/jail.local 644 <<<"${content}"
        if [[ "${WRITE_FILE_CHANGED}" == "1" ]]; then
            run systemctl restart fail2ban || log_warn "Restarting fail2ban failed. Check: journalctl -u fail2ban"
        fi
    fi

    if have_cmd ufw && ! is_dry_run; then
        ufw status verbose | sed 's/^/    /'
    fi
    log_ok "SSH runs on port ${NEW_PORT}. Update your ~/.ssh/config."
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            -h | --help)
                usage
                exit 0
                ;;
            -*)
                usage >&2
                die "Unknown option: $1"
                ;;
            *)
                [[ -z "${NEW_PORT}" ]] || die "Give exactly one port."
                NEW_PORT="$1"
                ;;
        esac
        shift
    done
    [[ -n "${NEW_PORT}" ]] || {
        usage >&2
        exit 2
    }
    validate_port "${NEW_PORT}" || die "'${NEW_PORT}' is not a port in the range 1-65535."
    NEW_PORT="$((10#${NEW_PORT}))"
    if [[ "${NEW_PORT}" == "80" || "${NEW_PORT}" == "443" ]]; then
        die "Ports 80 and 443 are taken by the proxy."
    fi

    require_root
    os_detect
    os_require_supported
    require_cmd ss sshd systemctl
    [[ -f "${STACK_ENV_FILE}" ]] || die "${STACK_ENV_FILE} not found. Run 'vps-stack provision' first."
    stack_config_load "${STACK_ENV_FILE}"

    MODE="$(os_ssh_mode)"
    OLD_PORTS="$(os_ssh_ports | tr '\n' ' ')"
    OLD_PORTS="${OLD_PORTS% }"
    [[ -n "${OLD_PORTS}" ]] || die "Cannot tell which port sshd listens on right now. Not guessing, aborting."
    log_info "sshd start mode: ${MODE}. Current port: ${OLD_PORTS}. New port: ${NEW_PORT}."

    if ! is_dry_run && ! has_tty; then
        die "This command needs a terminal: the new session test has to be confirmed by hand."
    fi

    if [[ "${OLD_PORTS}" == "${NEW_PORT}" ]]; then
        # Either nothing to do, or an earlier run stopped before the cleanup.
        if [[ "${SSH_PORT}" == "${NEW_PORT}" ]]; then
            log_ok "sshd already listens on port ${NEW_PORT}. Nothing to do."
            exit 0
        fi
        log_warn "sshd already listens on port ${NEW_PORT}, but the previous change was not finished."
        OLD_PORTS="${SSH_PORT}"
    else
        if port_listening "${NEW_PORT}"; then
            die "Port ${NEW_PORT} is already used by another service."
        fi
        confirm_risky "Change the SSH port from ${OLD_PORTS} to ${NEW_PORT}?" || die "Aborted. Nothing was changed."

        if have_cmd ufw; then
            run ufw allow "${NEW_PORT}/tcp" >/dev/null
            log_info "Opened ${NEW_PORT}/tcp in ufw (the old port stays open)."
        else
            log_warn "ufw is not installed, skipping the firewall rules."
        fi

        apply_change

        if ! is_dry_run; then
            local i listening=0
            for ((i = 0; i < 10; i++)); do
                if port_listening "${NEW_PORT}"; then
                    listening=1
                    break
                fi
                sleep 1
            done
            if [[ "${listening}" != "1" ]]; then
                rollback_change
                die "sshd did not start listening on port ${NEW_PORT}. The change was rolled back."
            fi
            log_ok "sshd listens on port ${NEW_PORT}."
        fi
    fi

    if ! confirm_phrase "YES" "Do NOT close this session. Open a NEW SSH session on the new port:
    ssh -p ${NEW_PORT} ${ADMIN_USER}@<server address>
and check that login works."; then
        log_warn "Not confirmed. The old port stays open in ufw."
        if [[ -n "${CHANGED_FILE}" ]] && confirm_risky "Roll back the port change (return to ${OLD_PORTS})?"; then
            rollback_change
            die "The port change was rolled back."
        fi
        die "The change was NOT finished: sshd listens on ${NEW_PORT} and ufw still allows the old port too. Run this command again to finish, or see docs/ssh-recovery.md."
    fi

    finalize
}

main "$@"
