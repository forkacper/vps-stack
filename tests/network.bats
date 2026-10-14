#!/usr/bin/env bats

load helpers

NETWORK="${REPO_ROOT}/scripts/network.sh"

setup() {
    ETC_DIR="${BATS_TEST_TMPDIR}/etc"
    export VPS_STACK_ETC_DIR="${ETC_DIR}"
    mkdir -p "${ETC_DIR}"

    # A docker that keeps networks and containers as files:
    # ${STATE}/net/<network>/label holds the vps-stack.edge label (empty
    # when there is none), ${STATE}/net/<network>/internal marks an internal
    # network, ${STATE}/ctr/<container> lists the networks of a container.
    # Every command that changes something is appended to ${STATE}/calls;
    # ${STATE}/fail-connect makes `network connect` fail.
    STATE="${BATS_TEST_TMPDIR}/docker"
    export STATE
    mkdir -p "${STATE}/bin" "${STATE}/net" "${STATE}/ctr"
    cat >"${STATE}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
net="${STATE}/net"
ctr="${STATE}/ctr"
case "$1 $2" in
    "info "*) exit 0 ;;
    "network ls")
        for dir in "${net}"/*/; do
            [[ -d "${dir}" && -s "${dir}label" ]] && basename "${dir}"
        done
        exit 0
        ;;
    "network inspect")
        name="${*: -1}"
        [[ -d "${net}/${name}" ]] || exit 1
        [[ "$*" == *Labels* ]] && cat "${net}/${name}/label"
        exit 0
        ;;
    "network create")
        echo "$*" >>"${STATE}/calls"
        name="${*: -1}"
        mkdir "${net}/${name}" || exit 1
        label=""
        [[ "$*" =~ --label\ vps-stack\.edge=([^ ]+) ]] && label="${BASH_REMATCH[1]}"
        printf '%s' "${label}" >"${net}/${name}/label"
        [[ "$*" == *--internal* ]] && touch "${net}/${name}/internal"
        exit 0
        ;;
    "network rm")
        echo "$*" >>"${STATE}/calls"
        rm -r "${net:?}/$3"
        ;;
    "network connect")
        echo "$*" >>"${STATE}/calls"
        [[ -e "${STATE}/fail-connect" ]] && exit 1
        [[ -d "${net}/$3" && -f "${ctr}/$4" ]] || exit 1
        echo "$3" >>"${ctr}/$4"
        ;;
    "network disconnect")
        echo "$*" >>"${STATE}/calls"
        grep -vxF "$3" "${ctr}/$4" >"${ctr}/$4.new"
        mv "${ctr}/$4.new" "${ctr}/$4"
        ;;
    "ps -a")
        args="$*"
        filter="${args#*--filter network=}"
        filter="${filter%% *}"
        for file in "${ctr}"/*; do
            [[ -f "${file}" ]] && grep -qxF "${filter}" "${file}" && basename "${file}"
        done
        exit 0
        ;;
    "inspect "*)
        name="${*: -1}"
        [[ -f "${ctr}/${name}" ]] || exit 1
        if [[ "$*" == *State.Running* ]]; then
            echo true
        elif [[ "$*" == *Networks* ]]; then
            cat "${ctr}/${name}"
        fi
        exit 0
        ;;
    *)
        echo "fake docker: unexpected call: $*" >&2
        exit 1
        ;;
esac
FAKE
    chmod +x "${STATE}/bin/docker"
    PATH="${STATE}/bin:${PATH}"
}

# container <name> [networks...]: a container attached to these networks.
container() {
    local name="$1"
    shift
    printf '%s\n' "$@" >"${STATE}/ctr/${name}"
    sed -i.bak '/^$/d' "${STATE}/ctr/${name}" && rm -f "${STATE}/ctr/${name}.bak"
}

# network <name> [project]: an existing network, with the label when a
# project is given.
network() {
    mkdir -p "${STATE}/net/$1"
    printf '%s' "${2:-}" >"${STATE}/net/$1/label"
}

calls() { cat "${STATE}/calls" 2>/dev/null; }

@test "edge_network_name: edge-<project>" {
    run edge_network_name example-app
    [ "$output" = "edge-example-app" ]
}

@test "create: an internal, labelled network with the proxy attached" {
    network proxy
    container caddy proxy
    run "${NETWORK}" create example-app
    [ "$status" -eq 0 ]
    [ -f "${STATE}/net/edge-example-app/internal" ]
    [ "$(cat "${STATE}/net/edge-example-app/label")" = "example-app" ]
    grep -qx "edge-example-app" "${STATE}/ctr/caddy"
    [[ "$output" == *"name: edge-example-app"* ]]
    [[ "$output" == *"external: true"* ]]
}

@test "create: a second run changes nothing" {
    network proxy
    container caddy proxy
    "${NETWORK}" create example-app >/dev/null
    : >"${STATE}/calls"
    run "${NETWORK}" create example-app
    [ "$status" -eq 0 ]
    [ -z "$(calls)" ]
    [[ "$output" == *"already exists"* ]]
}

@test "create: a network of the same name not made by vps-stack is refused" {
    container caddy proxy
    network edge-example-app
    run "${NETWORK}" create example-app
    [ "$status" -ne 0 ]
    [[ "$output" == *"not created by vps-stack"* ]]
    [ -z "$(calls)" ]
}

@test "create: without the proxy container the network is still created" {
    run "${NETWORK}" create example-app
    [ "$status" -eq 0 ]
    [ -d "${STATE}/net/edge-example-app" ]
    [[ "$output" == *"vps-stack proxy up"* ]]
}

@test "create: invalid project names are refused before Docker is asked" {
    local value
    for value in "" "App" "../etc" "a b" 'a$(id)' "-x"; do
        run "${NETWORK}" create "${value}"
        [ "$status" -ne 0 ]
    done
    [ -z "$(calls)" ]
}

@test "create --dry-run: changes nothing" {
    container caddy proxy
    run "${NETWORK}" create example-app --dry-run
    [ "$status" -eq 0 ]
    [ ! -d "${STATE}/net/edge-example-app" ]
    [ -z "$(calls)" ]
    [[ "$output" == *"network create --internal --label vps-stack.edge=example-app edge-example-app"* ]]
    [[ "$output" == *"network connect edge-example-app caddy"* ]]
}

@test "remove: detaches the proxy, then removes the network" {
    network proxy
    network edge-example-app example-app
    container caddy proxy edge-example-app
    run "${NETWORK}" remove example-app --yes
    [ "$status" -eq 0 ]
    [ ! -d "${STATE}/net/edge-example-app" ]
    [ "$(cat "${STATE}/ctr/caddy")" = "proxy" ]
    [ "$(calls)" = "$(printf 'network disconnect edge-example-app caddy\nnetwork rm edge-example-app')" ]
}

@test "remove: refused while a container of the project is attached" {
    network edge-example-app example-app
    container caddy proxy edge-example-app
    container example-app-web edge-example-app
    run "${NETWORK}" remove example-app --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"example-app-web"* ]]
    [ -z "$(calls)" ]
}

@test "remove: a network not made by vps-stack is left alone" {
    network edge-example-app
    run "${NETWORK}" remove example-app --yes
    [ "$status" -ne 0 ]
    [ -d "${STATE}/net/edge-example-app" ]
}

@test "remove: a missing network is nothing to do" {
    run "${NETWORK}" remove example-app --yes
    [ "$status" -eq 0 ]
    [ -z "$(calls)" ]
}

@test "sync: attaches the proxy to the project networks it lost" {
    network proxy
    network edge-a a
    network edge-b b
    network other-network
    container caddy proxy edge-a
    run "${NETWORK}" sync
    [ "$status" -eq 0 ]
    [ "$(calls)" = "network connect edge-b caddy" ]
    run "${NETWORK}" sync
    [ "$status" -eq 0 ]
    [ "$(calls)" = "network connect edge-b caddy" ]
}

@test "sync: a failed attach is an error" {
    network edge-a a
    container caddy proxy
    touch "${STATE}/fail-connect"
    run "${NETWORK}" sync
    [ "$status" -ne 0 ]
}

@test "list: networks, proxy state, members and the shared network" {
    network proxy
    network edge-a a
    network edge-b b
    container caddy proxy edge-a
    container a-web edge-a
    container old-web proxy
    run "${NETWORK}" list
    [ "$status" -eq 0 ]
    [[ "$output" == *"edge-a"*"attached"*"a-web"* ]]
    [[ "$output" == *"edge-b"*"MISSING"*"(none)"* ]]
    [[ "$output" == *"Still on the shared proxy network"*"old-web"* ]]
    [[ "$output" != *"caddy"* ]]
}

@test "edge_attach_all: nothing to do without the proxy container" {
    network edge-a a
    run edge_attach_all
    [ "$status" -eq 0 ]
    [ -z "$(calls)" ]
}
