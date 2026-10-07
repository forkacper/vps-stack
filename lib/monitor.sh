#!/usr/bin/env bash
# Status page (vps-stack monitor): rendering of the Caddy files. Pure logic:
# no root, no Docker, no network. Covered by tests/monitor.bats.
#
# Requires lib/common.sh (render_template) and lib/validate.sh.

if [[ -n "${VPS_STACK_MONITOR_LOADED:-}" ]]; then
    return 0
fi
VPS_STACK_MONITOR_LOADED=1

# monitor_site_render <template> <domain> <user> <bcrypt hash>
# Validates every value, then prints the site file.
monitor_site_render() {
    local template="$1" raw_domain="${2:-}" user="${3:-}" hash="${4:-}" domain
    domain="$(normalize_domain "${raw_domain}")" || return 1
    validate_monitor_user "${user}" || return 1
    validate_bcrypt_hash "${hash}" || return 1
    render_template "${template}" "DOMAIN=${domain}" "USER=${user}" "HASH=${hash}"
}

# monitor_ban_snippet [ip...]: print the file imported at the top of the
# status page route. Every address is validated; with no addresses the file
# holds only its header, which Caddy accepts as empty.
monitor_ban_snippet() {
    local ip normalized
    local -a ips=()
    for ip in "$@"; do
        normalized="$(normalize_ip "${ip}")" || return 1
        ips+=("${normalized}")
    done
    printf '# Managed by vps-stack (monitor ban / unban). Manual edits are overwritten.\n'
    if [[ "${#ips[@]}" -gt 0 ]]; then
        printf '@vps_stack_banned remote_ip %s\n' "${ips[*]}"
        printf 'abort @vps_stack_banned\n'
    fi
}
