#!/usr/bin/env bash
# Project networks: create, remove and list them, and attach the proxy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=lib/validate.sh
source "${SCRIPT_DIR}/../lib/validate.sh"
# shellcheck source=lib/deploy.sh
source "${SCRIPT_DIR}/../lib/deploy.sh"
# shellcheck source=lib/network.sh
source "${SCRIPT_DIR}/../lib/network.sh"

usage() {
    cat <<USAGE
Usage: vps-stack network <command>

Every project gets its own network, shared by its web container and the
proxy only, so web containers of different projects cannot reach each other.

Commands:
  create <project>   create the network ${EDGE_PREFIX}<project> and attach the proxy
  remove <project>   detach the proxy and remove the network; refused while
                     a container of the project is still attached
  list               the project networks, and the containers still on the
                     shared ${PROXY_NETWORK} network
  sync               attach the proxy to every project network it is missing
                     from ('vps-stack proxy up' does it by itself)

Options: --dry-run, --yes (remove only)
USAGE
}

require_docker() {
    require_cmd docker
    docker info >/dev/null 2>&1 || die "Docker is not available. Run this command with sudo."
}

# project_arg <value>: the validated project name, or exit 2.
project_arg() {
    [[ -n "${1:-}" ]] || {
        usage >&2
        exit 2
    }
    validate_project_name "$1" || exit 2
}

compose_snippet() {
    cat <<SNIPPET
In the project's compose file, put the web container on this network instead
of ${PROXY_NETWORK} (docs/project-contract.md):

  services:
    web:
      networks:
        - edge
        - internal

  networks:
    edge:
      name: $1
      external: true
SNIPPET
}

cmd_create() {
    local project="$1" network label
    network="$(edge_network_name "${project}")"
    label="$(edge_network_project "${network}")"
    if docker network inspect "${network}" >/dev/null 2>&1; then
        [[ "${label}" == "${project}" ]] ||
            die "Network ${network} exists but was not created by vps-stack. Remove or rename it first."
        log_ok "Network ${network} already exists."
    else
        run docker network create --internal --label "${EDGE_LABEL}=${project}" "${network}" >/dev/null
        is_dry_run || log_ok "Created network ${network} (internal: no route to the internet)."
    fi
    if ! docker inspect "${CADDY_CONTAINER}" >/dev/null 2>&1 && ! is_dry_run; then
        log_warn "Container ${CADDY_CONTAINER} does not exist. 'vps-stack proxy up' attaches it."
    elif grep -qxF -- "${network}" <<<"$(container_networks "${CADDY_CONTAINER}")"; then
        log_ok "The proxy is attached to ${network}."
    else
        run docker network connect "${network}" "${CADDY_CONTAINER}" ||
            die "Attaching the proxy to ${network} failed. Try again: sudo vps-stack network sync"
        is_dry_run || log_ok "Proxy attached to ${network}."
    fi
    printf '\n'
    compose_snippet "${network}"
}

cmd_remove() {
    local project="$1" network members
    network="$(edge_network_name "${project}")"
    if ! docker network inspect "${network}" >/dev/null 2>&1; then
        log_ok "Network ${network} does not exist. Nothing to do."
        return 0
    fi
    [[ "$(edge_network_project "${network}")" == "${project}" ]] ||
        die "Network ${network} was not created by vps-stack. Not removing it."

    # A container left pointing at a removed network does not start any more.
    members="$(network_members "${network}")"
    if [[ -n "${members}" ]]; then
        log_error "These containers are still attached to ${network}:"
        printf '    %s\n' "${members//$'\n'/$'\n'    }" >&2
        die "Stop the project (docker compose down) or take the network out of its compose file first."
    fi
    confirm "Detach the proxy from ${network} and remove the network?" || die "Aborted. Nothing was changed."

    if grep -qxF -- "${network}" <<<"$(container_networks "${CADDY_CONTAINER}")"; then
        run docker network disconnect "${network}" "${CADDY_CONTAINER}" ||
            die "Detaching the proxy from ${network} failed. Nothing was removed."
    fi
    run docker network rm "${network}" >/dev/null || die "Removing ${network} failed."
    is_dry_run || log_ok "Removed network ${network}."
}

cmd_list() {
    local network attached members caddy_nets shared
    local -a networks=()
    mapfile -t networks < <(edge_networks)
    caddy_nets="$(container_networks "${CADDY_CONTAINER}")"
    if [[ "${#networks[@]}" -eq 0 ]]; then
        log_info "No project networks. To create one: vps-stack network create <project>"
    else
        printf '%s %s %s\n' "$(_pad NETWORK 32)" "$(_pad PROXY 9)" "CONTAINERS"
        for network in "${networks[@]}"; do
            attached="attached"
            grep -qxF -- "${network}" <<<"${caddy_nets}" || attached="MISSING"
            members="$(network_members "${network}" | tr '\n' ' ')"
            printf '%s %s %s\n' "$(_pad "${network}" 32)" "$(_pad "${attached}" 9)" "${members:-(none)}"
        done
    fi
    shared="$(network_members "${PROXY_NETWORK}" | tr '\n' ' ')"
    if [[ -n "${shared}" ]]; then
        printf '\n'
        log_warn "Still on the shared ${PROXY_NETWORK} network, where they can reach each other: ${shared% }"
    fi
}

cmd_sync() {
    edge_attach_all || die "The proxy could not be attached to every project network."
    if ! is_dry_run && [[ -z "$(edge_missing_from_caddy)" ]]; then
        log_ok "The proxy is attached to every project network."
    fi
}

main() {
    local command="${1:-}"
    local -a args=()
    [[ $# -gt 0 ]] && shift
    case "${command}" in
        "" | help | -h | --help)
            stack_config_load "${STACK_ENV_FILE}"
            usage
            return 0
            ;;
        create | remove | list | sync) ;;
        *)
            usage >&2
            die "Unknown command: ${command}"
            ;;
    esac
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --yes | -y) ASSUME_YES=1 ;;
            -*)
                usage >&2
                die "Unknown option: $1"
                ;;
            *) args+=("$1") ;;
        esac
        shift
    done
    case "${command}" in
        create | remove) [[ "${#args[@]}" -le 1 ]] || die "Give exactly one project." ;;
        *) [[ "${#args[@]}" -eq 0 ]] || die "Too many arguments: ${args[*]}" ;;
    esac

    stack_config_load "${STACK_ENV_FILE}"
    require_docker
    case "${command}" in
        create)
            project_arg "${args[0]:-}"
            cmd_create "${args[0]}"
            ;;
        remove)
            project_arg "${args[0]:-}"
            cmd_remove "${args[0]}"
            ;;
        list) cmd_list ;;
        sync) cmd_sync ;;
        *) ;;
    esac
}

main "$@"
