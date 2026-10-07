#!/usr/bin/env bash
# Report listening ports and published container ports that should not be
# reachable from the internet. Read-only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=lib/os-detect.sh
source "${SCRIPT_DIR}/../lib/os-detect.sh"

usage() {
    cat <<USAGE
Usage: vps-stack check-ports

Lists ports listening on all interfaces (0.0.0.0 or ::) other than SSH, 80
and 443, and containers with published ports other than caddy.

Ports published by Docker (ports:) BYPASS ufw.

Exit codes: 0 clean, 1 unexpected ports on the host, 2 a container with a
port published to the outside.
USAGE
}

allowed_ports() {
    printf '80\n443\n%s\n' "${SSH_PORT}"
    # Also whatever sshd really listens on, in case stack.env is out of date.
    if [[ -r /etc/os-release ]]; then
        os_detect
        if declare -F os_ssh_ports >/dev/null 2>&1 && [[ "$(os_check_supported)" != "planned" ]]; then
            os_ssh_ports 2>/dev/null || true
        fi
    fi
}

check_host_ports() {
    local allowed line proto local_addr addr port process found=0
    allowed=" $(allowed_ports | tr '\n' ' ')"
    log_info "Ports listening on all interfaces:"
    while IFS= read -r line; do
        # Columns: Netid State Recv-Q Send-Q Local-Address:Port Peer ... Process
        proto="$(printf '%s' "${line}" | awk '{ print $1 }')"
        local_addr="$(printf '%s' "${line}" | awk '{ print $5 }')"
        process="$(printf '%s' "${line}" | awk '{ print $7 }')"
        port="${local_addr##*:}"
        addr="${local_addr%:*}"
        case "${addr}" in
            "0.0.0.0" | "*" | "[::]" | "::") ;;
            *) continue ;;
        esac
        if [[ "${allowed}" == *" ${port} "* ]]; then
            printf '  %sOK%s     %s/%s %s\n' "${C_GREEN}" "${C_RESET}" "${port}" "${proto}" "${process}"
        else
            printf '  %sWARN%s   %s/%s on %s %s\n' "${C_YELLOW}" "${C_RESET}" "${port}" "${proto}" "${addr}" "${process}"
            found=1
        fi
    done < <(ss -H -tulnp 2>/dev/null | sort -u)
    if [[ "${found}" == "1" ]]; then
        log_info "  Ports outside the list are blocked by ufw unless Docker publishes them. Disable the services you do not need."
    fi
    return "${found}"
}

check_container_ports() {
    local name ports entry found=0
    if ! have_cmd docker || ! docker info >/dev/null 2>&1; then
        log_warn "Docker is not available, skipping the container check."
        return 0
    fi
    log_info "Containers with published ports:"
    while IFS=$'\t' read -r name ports; do
        [[ -n "${name}" && "${ports}" == *"->"* ]] || continue
        if [[ "${name}" == "${CADDY_CONTAINER}" ]]; then
            printf '  %sOK%s     %s: %s\n' "${C_GREEN}" "${C_RESET}" "${name}" "${ports}"
            continue
        fi
        while IFS= read -r entry; do
            entry="${entry# }"
            [[ "${entry}" == *"->"* ]] || continue
            case "${entry}" in
                127.* | "[::1]"*)
                    printf '  %sOK%s     %s: %s (localhost only)\n' "${C_GREEN}" "${C_RESET}" "${name}" "${entry}"
                    ;;
                *)
                    printf '  %sERROR%s  %s: %s is reachable from the internet, bypassing ufw\n' \
                        "${C_RED}" "${C_RESET}" "${name}" "${entry}"
                    found=1
                    ;;
            esac
        done < <(printf '%s\n' "${ports}" | tr ',' '\n')
    done < <(docker ps --format '{{.Names}}{{"\t"}}{{.Ports}}')
    if [[ "${found}" == "1" ]]; then
        log_info "  Remove 'ports:' from the project's compose file or change it to 127.0.0.1:port:port. Public traffic has to go through the proxy."
    fi
    return "${found}"
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
    require_cmd ss awk
    stack_config_load "${STACK_ENV_FILE}"
    local code=0
    check_host_ports || code=1
    check_container_ports || code=2
    if [[ "${code}" == "0" ]]; then
        log_ok "No unexpected ports."
    fi
    exit "${code}"
}

main "$@"
