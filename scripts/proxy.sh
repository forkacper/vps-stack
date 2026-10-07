#!/usr/bin/env bash
# Manage the shared Caddy reverse proxy stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

COMPOSE_FILE="${REPO_ROOT}/proxy/docker-compose.yml"
# Mounts of the status page; used only while it is enabled.
COMPOSE_MONITOR_FILE="${REPO_ROOT}/proxy/docker-compose.monitor.yml"
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
  network-ipv6 [--dry-run] [--yes]
             recreate an IPv4-only proxy network with IPv6, so that Caddy
             sees the real address of IPv6 clients (a short outage of all
             sites; attached containers are reconnected)
USAGE
}

compose() {
    local -a files=(-f "${COMPOSE_FILE}")
    if [[ -f "${MONITOR_ENV_FILE}" ]]; then
        files+=(-f "${COMPOSE_MONITOR_FILE}")
    fi
    docker compose -p "${PROXY_PROJECT_NAME}" --env-file "${PROXY_ENV_FILE}" "${files[@]}" "$@"
}

prepare() {
    require_cmd docker
    require_etc_access read
    [[ -r "${PROXY_ENV_FILE}" ]] || die "${PROXY_ENV_FILE} not found. Copy config/proxy.env.example and fill in ACME_EMAIL."
    local ACME_EMAIL=""
    load_env_file "${PROXY_ENV_FILE}"
    [[ -n "${ACME_EMAIL}" ]] || die "ACME_EMAIL in ${PROXY_ENV_FILE} is empty. Fill it in and try again."
    stack_config_load "${STACK_ENV_FILE}"
    # Read by docker compose when it interpolates the compose files.
    export SITES_DIR CADDY_DATA_DIR PROXY_NETWORK MONITOR_RUN_DIR MONITOR_LOG_DIR
}

# The proxy network has IPv6 enabled (Docker picks a private ULA /64). On an
# IPv4-only network Docker publishes Caddy's ports on the host's IPv6
# addresses through its userland proxy, and every IPv6 client reaches Caddy
# as the network gateway: fail2ban cannot ban it and the applications see the
# gateway in X-Forwarded-For. With IPv6 on the network, ip6tables forwards
# the traffic and keeps the client address. This relies on ip6tables being
# enabled in the Docker daemon, the default since Docker Engine 27.0.1.
ensure_network() {
    if ! docker network inspect "${PROXY_NETWORK}" >/dev/null 2>&1; then
        run docker network create --ipv6 "${PROXY_NETWORK}" >/dev/null
        log_info "Created Docker network: ${PROXY_NETWORK} (IPv4 and IPv6)"
    fi
}

network_has_ipv6() {
    [[ "$(docker network inspect -f '{{.EnableIPv6}}' "${PROXY_NETWORK}" 2>/dev/null)" == "true" ]]
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

# network_aliases <container>: the aliases of the container on the proxy
# network, one per line, without the container's own short ID (Docker adds
# that one by itself).
network_aliases() {
    local container="$1" id alias
    id="$(docker inspect -f '{{.Id}}' "${container}" 2>/dev/null)" || return 0
    while IFS= read -r alias; do
        [[ -n "${alias}" && "${id}" != "${alias}"* ]] && printf '%s\n' "${alias}"
    done < <(docker inspect -f "{{with index .NetworkSettings.Networks \"${PROXY_NETWORK}\"}}{{range .Aliases}}{{println .}}{{end}}{{end}}" \
        "${container}" 2>/dev/null)
    return 0
}

# Filled by cmd_network_ipv6: the containers to reconnect and their aliases.
NETWORK_MEMBERS=()
declare -A NETWORK_ALIASES=()

# reconnect_command <container>: the docker command that reconnects it.
reconnect_command() {
    local name="$1" alias
    local -a args=(docker network connect)
    while IFS= read -r alias; do
        [[ -n "${alias}" ]] && args+=(--alias "${alias}")
    done <<<"${NETWORK_ALIASES[${name}]:-}"
    args+=("${PROXY_NETWORK}" "${name}")
    printf '%q ' "${args[@]}"
}

# network_ipv6_failed <step>: stop and say how to finish by hand.
network_ipv6_failed() {
    local name
    log_error "Recreating the network failed at: $1."
    printf 'Check the state and finish by hand, in this order:\n'
    printf '  docker network inspect %q >/dev/null || docker network create --ipv6 %q\n' "${PROXY_NETWORK}" "${PROXY_NETWORK}"
    printf '  sudo vps-stack proxy up\n'
    for name in "${NETWORK_MEMBERS[@]+"${NETWORK_MEMBERS[@]}"}"; do
        printf '  %s\n' "$(reconnect_command "${name}")"
    done
    printf '(A "already exists" or "already connected" error in one of these means that step was done.)\n'
    exit 1
}

# cmd_network_ipv6: move an existing IPv4-only proxy network to IPv6. A
# network cannot be changed in place, so it is recreated: every attached
# container, running or stopped, is disconnected; the proxy stops; the
# network is removed and created again with IPv6; the proxy starts; the
# containers are reconnected with the same aliases.
cmd_network_ipv6() {
    local name alias version
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --yes | -y) ASSUME_YES=1 ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
    require_root

    if ! docker network inspect "${PROXY_NETWORK}" >/dev/null 2>&1; then
        ensure_network
        log_ok "Network ${PROXY_NETWORK} did not exist and is created with IPv6. Start the proxy: vps-stack proxy up"
        return 0
    fi
    if network_has_ipv6; then
        log_ok "Network ${PROXY_NETWORK} already has IPv6. Nothing to do."
        return 0
    fi

    version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
    if [[ "${version%%.*}" =~ ^[0-9]+$ ]] && [[ "${version%%.*}" -lt 27 ]]; then
        log_warn "Docker ${version}: ip6tables is enabled by default only since Docker Engine 27.0.1. Without it IPv6 clients keep reaching Caddy as the gateway; see \"ip6tables\" in the Docker daemon documentation."
    fi

    # `docker ps -a --filter network=` also finds stopped containers: they
    # would not start any more if left pointing at the removed network.
    while IFS= read -r name; do
        [[ -n "${name}" && "${name}" != "${CADDY_CONTAINER}" ]] || continue
        NETWORK_MEMBERS+=("${name}")
        NETWORK_ALIASES["${name}"]="$(network_aliases "${name}")"
    done < <(docker ps -a --filter "network=${PROXY_NETWORK}" --format '{{.Names}}')

    cat <<PLAN
Network ${PROXY_NETWORK} is IPv4 only: IPv6 clients reach the sites as the
Docker gateway. It is recreated with IPv6:
  1. disconnect the attached containers: ${NETWORK_MEMBERS[*]:-(none besides ${CADDY_CONTAINER})}
  2. stop the proxy, remove the network, create it again with IPv6
  3. start the proxy, reconnect the containers with their aliases
Every site is unreachable meanwhile, usually for less than a minute.
PLAN
    for name in "${NETWORK_MEMBERS[@]+"${NETWORK_MEMBERS[@]}"}"; do
        printf '  afterwards: %s\n' "$(reconnect_command "${name}")"
    done
    confirm "Recreate the network ${PROXY_NETWORK} with IPv6?" || die "Aborted. Nothing was changed."

    for name in "${NETWORK_MEMBERS[@]+"${NETWORK_MEMBERS[@]}"}"; do
        run docker network disconnect "${PROXY_NETWORK}" "${name}" || network_ipv6_failed "disconnecting ${name}"
    done
    run compose down || network_ipv6_failed "stopping the proxy"
    run docker network rm "${PROXY_NETWORK}" >/dev/null || network_ipv6_failed "removing the network"
    run docker network create --ipv6 "${PROXY_NETWORK}" >/dev/null || network_ipv6_failed "creating the network with IPv6"
    cmd_up || network_ipv6_failed "starting the proxy"
    for name in "${NETWORK_MEMBERS[@]+"${NETWORK_MEMBERS[@]}"}"; do
        local -a args=(docker network connect)
        while IFS= read -r alias; do
            [[ -n "${alias}" ]] && args+=(--alias "${alias}")
        done <<<"${NETWORK_ALIASES[${name}]:-}"
        run "${args[@]}" "${PROXY_NETWORK}" "${name}" || network_ipv6_failed "reconnecting ${name}"
    done
    is_dry_run && return 0
    network_has_ipv6 || network_ipv6_failed "checking the new network"
    log_ok "Network ${PROXY_NETWORK} has IPv6. Caddy now sees the real address of IPv6 clients."
}

main() {
    local command="${1:-}"
    [[ $# -gt 0 ]] && shift
    case "${command}" in
        "" | help | -h | --help)
            usage
            return 0
            ;;
        up | down | restart | reload | validate | status | logs | network-ipv6) ;;
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
        network-ipv6) cmd_network_ipv6 "$@" ;;
        *) ;;
    esac
}

main "$@"
