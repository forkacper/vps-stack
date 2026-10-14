#!/usr/bin/env bash
# Project networks: one internal Docker network per project, shared by the
# project's web container and Caddy only. Web containers of different
# projects have no network in common, so they cannot reach each other.
#
# A project network is edge-<project>, created with --internal and the label
# vps-stack.edge=<project>. Docker itself is the record of which networks
# exist: there is no state file. Caddy is attached with `docker network
# connect`, which belongs to the container and is gone when the container is
# recreated, so `vps-stack proxy` attaches it again after every start
# (edge_attach_all).
#
# Requires lib/common.sh (run, log_*).

if [[ -n "${VPS_STACK_NETWORK_LOADED:-}" ]]; then
    return 0
fi
VPS_STACK_NETWORK_LOADED=1

EDGE_LABEL="vps-stack.edge"
EDGE_PREFIX="edge-"

# edge_network_name <project>
edge_network_name() { printf '%s%s\n' "${EDGE_PREFIX}" "$1"; }

# edge_networks: every project network, one per line, sorted.
edge_networks() {
    docker network ls --filter "label=${EDGE_LABEL}" --format '{{.Name}}' 2>/dev/null | sort
}

# edge_network_project <network>: the project in the label; empty when the
# network does not exist or was not created by vps-stack.
edge_network_project() {
    docker network inspect -f "{{index .Labels \"${EDGE_LABEL}\"}}" "$1" 2>/dev/null || true
}

# container_networks <container>: the networks of a container, running or
# stopped, one per line, sorted; nothing when it does not exist.
container_networks() {
    docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "$1" 2>/dev/null |
        sed '/^$/d' | sort
}

# network_members <network>: the containers attached to a network, running
# or stopped, except Caddy, one per line, sorted.
network_members() {
    docker ps -a --filter "network=$1" --format '{{.Names}}' 2>/dev/null |
        grep -vxF -- "${CADDY_CONTAINER}" | sort || true
}

# edge_missing_from_caddy: the project networks Caddy is not attached to.
edge_missing_from_caddy() {
    comm -23 <(edge_networks) <(container_networks "${CADDY_CONTAINER}")
}

# edge_attach_all: attach Caddy to every project network it is missing
# from. Does nothing when the container does not exist yet.
edge_attach_all() {
    local network code=0
    docker inspect "${CADDY_CONTAINER}" >/dev/null 2>&1 || is_dry_run || return 0
    while IFS= read -r network; do
        [[ -n "${network}" ]] || continue
        if run docker network connect "${network}" "${CADDY_CONTAINER}"; then
            is_dry_run || log_ok "Proxy attached to ${network}."
        else
            log_error "Attaching the proxy to ${network} failed."
            code=1
        fi
    done < <(edge_missing_from_caddy)
    return "${code}"
}
