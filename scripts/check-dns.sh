#!/usr/bin/env bash
# Check that domains resolve to this server before a certificate is requested.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=lib/validate.sh
source "${SCRIPT_DIR}/../lib/validate.sh"

usage() {
    cat <<USAGE
Usage: vps-stack check-dns [--server-ip <address>]... <domain>...

Compares the A and AAAA records of the domains with the public address of
this server.

Options:
  --server-ip <address> public address of the server (IPv4 or IPv6); may be
                        given twice. Without it the address is fetched from
                        an external service.

Exit codes: 0 match, 1 mismatch, 2 usage error, 3 the server address could
not be determined.
USAGE
}

SERVER_V4=""
SERVER_V6=""
DOMAINS=()

is_ipv4() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
is_ipv6() { [[ "$1" == *:* && "$1" =~ ^[0-9a-f:.]+$ ]]; }

add_server_ip() {
    local ip
    ip="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    if is_ipv4 "${ip}"; then
        SERVER_V4="${ip}"
    elif is_ipv6 "${ip}"; then
        SERVER_V6="${ip}"
    else
        log_error "--server-ip: '${1}' does not look like an IP address."
        exit 2
    fi
}

# The public address is asked from one external service (ipify). That is a
# convenience, not a dependency: when the service is unreachable or you do
# not want to rely on it, pass --server-ip and no request is made at all.
detect_server_ips() {
    local ip
    ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if is_ipv4 "${ip}"; then
        SERVER_V4="${ip}"
    fi
    ip="$(curl -6 -fsS --max-time 8 https://api6.ipify.org 2>/dev/null || true)"
    if is_ipv6 "${ip}"; then
        SERVER_V6="${ip}"
    fi
}

# resolve <A|AAAA> <domain>: addresses only (dig also prints CNAME targets).
resolve() {
    dig +short +time=3 +tries=2 "$1" "$2" 2>/dev/null | tr '[:upper:]' '[:lower:]' |
        grep -E '^[0-9a-f:.]+$' | grep -vE '^[a-z.]*$' || true
}

check_domain() {
    local domain="$1" a_records aaaa_records record problems=""
    a_records="$(resolve A "${domain}")"
    aaaa_records="$(resolve AAAA "${domain}")"

    if [[ -z "${a_records}" && -z "${aaaa_records}" ]]; then
        problems="no A or AAAA records"
    fi
    for record in ${a_records}; do
        if [[ "${record}" != "${SERVER_V4}" ]]; then
            problems="${problems:+${problems}; }A ${record} (server: ${SERVER_V4:-unknown})"
        fi
    done
    # A stale AAAA record breaks certificate issuance even when A is right,
    # because the CA may validate over IPv6.
    for record in ${aaaa_records}; do
        if [[ "${record}" != "${SERVER_V6}" ]]; then
            problems="${problems:+${problems}; }AAAA ${record} (server: ${SERVER_V6:-no IPv6})"
        fi
    done

    if [[ -n "${problems}" ]]; then
        printf '%sMISMATCH%s %s: %s\n' "${C_RED}" "${C_RESET}" "${domain}" "${problems}"
        return 1
    fi
    printf '%sOK%s       %s -> %s\n' "${C_GREEN}" "${C_RESET}" "${domain}" \
        "$(printf '%s %s' "${a_records}" "${aaaa_records}" | tr '\n' ' ')"
}

main() {
    local domain normalized failed=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server-ip)
                [[ $# -ge 2 ]] || {
                    log_error "--server-ip needs a value."
                    exit 2
                }
                add_server_ip "$2"
                shift 2
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            -*)
                usage >&2
                log_error "Unknown option: $1"
                exit 2
                ;;
            *)
                DOMAINS+=("$1")
                shift
                ;;
        esac
    done
    if [[ "${#DOMAINS[@]}" -eq 0 ]]; then
        usage >&2
        exit 2
    fi
    require_cmd dig

    if [[ -z "${SERVER_V4}" && -z "${SERVER_V6}" ]]; then
        require_cmd curl
        detect_server_ips
    fi
    if [[ -z "${SERVER_V4}" && -z "${SERVER_V6}" ]]; then
        log_error "Could not determine the public address of the server. Pass it with --server-ip <address>."
        exit 3
    fi
    log_info "Server address: IPv4 ${SERVER_V4:-none}, IPv6 ${SERVER_V6:-none}"

    for domain in "${DOMAINS[@]}"; do
        if ! normalized="$(normalize_domain "${domain}")"; then
            exit 2
        fi
        check_domain "${normalized}" || failed=1
    done
    exit "${failed}"
}

main "$@"
