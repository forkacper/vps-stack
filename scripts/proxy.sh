#!/usr/bin/env bash
# Manage the shared Caddy reverse proxy stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

COMPOSE_FILE="${REPO_ROOT}/proxy/docker-compose.yml"
CADDYFILE_IN_CONTAINER="/etc/caddy/Caddyfile"

usage() {
    cat <<USAGE
Usage: vps-stack proxy <command>

Commands:
  up         start the proxy (or apply changes made in proxy.env)
  down       stop and remove the proxy container (certificates stay on disk)
  restart    validate the configuration and recreate the container
             (needed after a 'git pull' that changes proxy/Caddyfile)
  reload     validate the configuration and reload Caddy without downtime
  validate   only validate the configuration
  status     container state
  logs       container logs (extra arguments go to 'docker compose logs')
USAGE
}

compose() {
    docker compose -p "${PROXY_PROJECT_NAME}" --env-file "${PROXY_ENV_FILE}" -f "${COMPOSE_FILE}" "$@"
}

prepare() {
    require_cmd docker
    require_etc_access read
    [[ -r "${PROXY_ENV_FILE}" ]] || die "${PROXY_ENV_FILE} not found. Copy config/proxy.env.example and fill in ACME_EMAIL."
    local ACME_EMAIL=""
    load_env_file "${PROXY_ENV_FILE}"
    [[ -n "${ACME_EMAIL}" ]] || die "ACME_EMAIL in ${PROXY_ENV_FILE} is empty. Fill it in and try again."
    stack_config_load "${STACK_ENV_FILE}"
    # Read by docker compose when it interpolates proxy/docker-compose.yml.
    export SITES_DIR CADDY_DATA_DIR PROXY_NETWORK
}

ensure_network() {
    if ! docker network inspect "${PROXY_NETWORK}" >/dev/null 2>&1; then
        run docker network create "${PROXY_NETWORK}" >/dev/null
        log_info "Created Docker network: ${PROXY_NETWORK}"
    fi
}

# validate_config <live|fresh>
# live:  inside the running container (sees new files in sites/ at once).
# fresh: in a throwaway container with fresh mounts (works when the proxy is
#        stopped and after the Caddyfile itself was replaced on disk).
validate_config() {
    local mode="$1"
    if [[ "${mode}" == "live" ]] && caddy_running; then
        docker exec "${CADDY_CONTAINER}" caddy validate --config "${CADDYFILE_IN_CONTAINER}" --adapter caddyfile
    else
        ensure_network
        compose run --rm --no-deps -T caddy caddy validate --config "${CADDYFILE_IN_CONTAINER}" --adapter caddyfile
    fi
}

wait_healthy() {
    local i state
    for ((i = 0; i < 30; i++)); do
        state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${CADDY_CONTAINER}" 2>/dev/null || true)"
        case "${state}" in
            healthy)
                log_ok "Container ${CADDY_CONTAINER} is running and healthy."
                return 0
                ;;
            unhealthy) break ;;
            *) sleep 2 ;;
        esac
    done
    log_warn "Container ${CADDY_CONTAINER} did not become healthy (state: ${state:-unknown}). Check: vps-stack proxy logs"
    return 1
}

cmd_up() {
    ensure_network
    run compose up -d
    is_dry_run || wait_healthy
}

# check_config <live|fresh>: quiet on success, Caddy's own output on failure.
check_config() {
    local output
    log_info "Validating the Caddy configuration..."
    if ! output="$(validate_config "$1" 2>&1)"; then
        printf '%s\n' "${output}" >&2
        return 1
    fi
}

cmd_restart() {
    check_config fresh || die "The Caddy configuration is invalid. The proxy was not restarted."
    run compose up -d --force-recreate
    is_dry_run || wait_healthy
}

cmd_reload() {
    if ! caddy_running; then
        die "Container ${CADDY_CONTAINER} is not running. Run: vps-stack proxy up"
    fi
    check_config live || die "The Caddy configuration is invalid. Not reloaded."
    run docker exec "${CADDY_CONTAINER}" caddy reload --config "${CADDYFILE_IN_CONTAINER}" --adapter caddyfile >/dev/null 2>&1 ||
        die "Reloading Caddy failed. Check: vps-stack proxy logs"
    log_ok "Caddy configuration reloaded."
}

cmd_validate() {
    check_config "${1:-live}" || die "The Caddy configuration is invalid."
    log_ok "The Caddy configuration is valid."
}

main() {
    local command="${1:-}"
    [[ $# -gt 0 ]] && shift
    case "${command}" in
        "" | help | -h | --help)
            usage
            return 0
            ;;
        up | down | restart | reload | validate | status | logs) ;;
        *)
            usage >&2
            die "Unknown command: ${command}"
            ;;
    esac
    prepare
    case "${command}" in
        up) cmd_up ;;
        down) run compose down ;;
        restart) cmd_restart ;;
        reload) cmd_reload ;;
        validate) cmd_validate "$@" ;;
        status) compose ps ;;
        logs) compose logs --tail 100 "$@" ;;
        *) ;;
    esac
}

main "$@"
