#!/usr/bin/env bash
# Status page (vps-stack monitor): rendering of the Caddy files and building
# of status.json. Pure logic: no root, no Docker, no network; the collector in
# scripts/monitor.sh feeds it. Covered by tests/monitor.bats.
#
# Requires lib/common.sh (render_template), lib/validate.sh and jq.

if [[ -n "${VPS_STACK_MONITOR_LOADED:-}" ]]; then
    return 0
fi
VPS_STACK_MONITOR_LOADED=1

# The only container fields the collector ever asks Docker for. Environment,
# labels, mounts, ports, networks, commands and logs are never requested, so
# they cannot reach status.json. The separator is "|", which can appear
# neither in container names nor in image references.
# shellcheck disable=SC2034  # read by scripts/monitor.sh and the tests
MONITOR_INSPECT_FORMAT='{{.Name}}|{{.Config.Image}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.State.StartedAt}}|{{.RestartCount}}'
# shellcheck disable=SC2034  # read by scripts/monitor.sh and the tests
MONITOR_STATS_FORMAT='{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}'

# monitor_cpu_sample <stat file>: print "<total> <idle>" jiffies from the
# aggregate cpu line of /proc/stat (idle includes iowait).
monitor_cpu_sample() {
    LC_ALL=C awk '$1 == "cpu" {
        total = 0
        for (i = 2; i <= NF; i++) total += $i
        print total, $5 + $6
        exit
    }' "$1"
}

# monitor_cpu_percent <prev total> <prev idle> <total> <idle>: busy share
# between two samples with one decimal, or nothing when there is no interval.
monitor_cpu_percent() {
    # LC_ALL=C: a locale with a decimal comma would print "25,0", which is
    # not a JSON number.
    LC_ALL=C awk -v pt="$1" -v pi="$2" -v t="$3" -v i="$4" 'BEGIN {
        dt = t - pt
        if (dt <= 0) exit
        busy = (dt - (i - pi)) / dt * 100
        if (busy < 0) busy = 0
        printf "%.1f\n", busy
    }'
}

# monitor_meminfo <meminfo file>: print "<total> <available> <swap total>
# <swap free>" in bytes.
monitor_meminfo() {
    LC_ALL=C awk '
        $1 == "MemTotal:" { total = $2 }
        $1 == "MemAvailable:" { available = $2 }
        $1 == "SwapTotal:" { swap_total = $2 }
        $1 == "SwapFree:" { swap_free = $2 }
        END { printf "%.0f %.0f %.0f %.0f\n", total * 1024, available * 1024, swap_total * 1024, swap_free * 1024 }
    ' "$1"
}

# monitor_host_json <proc dir> <hostname> <cpus> <cpu percent or empty>
#                   <disk total> <disk used> <reboot required: true|false>
# Print the "host" object. Every value is passed to jq as an argument, never
# spliced into the program text.
monitor_host_json() {
    local proc="$1" hostname="$2" cpus="$3" cpu_percent="$4" disk_total="$5" disk_used="$6" reboot="$7"
    local mem_total mem_available swap_total swap_free load1 load5 load15 uptime
    read -r mem_total mem_available swap_total swap_free < <(monitor_meminfo "${proc}/meminfo")
    read -r load1 load5 load15 _ <"${proc}/loadavg"
    read -r uptime _ <"${proc}/uptime"
    jq -n \
        --arg hostname "${hostname}" \
        --arg cpus "${cpus}" \
        --arg cpu_percent "${cpu_percent}" \
        --arg load1 "${load1}" --arg load5 "${load5}" --arg load15 "${load15}" \
        --arg uptime "${uptime}" \
        --arg mem_total "${mem_total}" --arg mem_available "${mem_available}" \
        --arg swap_total "${swap_total}" --arg swap_free "${swap_free}" \
        --arg disk_total "${disk_total}" --arg disk_used "${disk_used}" \
        --arg reboot "${reboot}" '
        def num: if . == "" then null else (tonumber? // null) end;
        {
            hostname: $hostname,
            uptime_seconds: ($uptime | num | if . == null then null else floor end),
            cpus: ($cpus | num),
            cpu_percent: ($cpu_percent | num),
            load: [($load1 | num), ($load5 | num), ($load15 | num)],
            memory: {
                total: ($mem_total | num),
                available: ($mem_available | num),
                used: (($mem_total | num) - ($mem_available | num))
            },
            swap: {
                total: ($swap_total | num),
                used: (($swap_total | num) - ($swap_free | num))
            },
            disk: {
                path: "/",
                total: ($disk_total | num),
                used: ($disk_used | num)
            },
            reboot_required: ($reboot == "true")
        }'
}

# monitor_containers_json <inspect lines> <stats lines>
# Inputs are the outputs of `docker inspect --format MONITOR_INSPECT_FORMAT`
# (all containers) and `docker stats --no-stream --format
# MONITOR_STATS_FORMAT` (running ones). Prints a JSON array sorted by name.
# Each object is built field by field: nothing else from the input survives.
monitor_containers_json() {
    jq -n --arg inspect "${1:-}" --arg stats "${2:-}" '
        def rows($text): $text | split("\n") | map(select(length > 0) | split("|"));
        def num: (tonumber? // null);
        def percent: if . == null then null else (rtrimstr("%") | num) end;
        def bytes:
            if . == null then null else
                (capture("^(?<n>[0-9.]+)\\s*(?<u>[A-Za-z]*)$")? // null) as $m
                | if $m == null then null else
                    ({"B": 1, "kB": 1000, "KB": 1000, "KiB": 1024,
                      "MB": 1000000, "MiB": 1048576,
                      "GB": 1000000000, "GiB": 1073741824,
                      "TB": 1000000000000, "TiB": 1099511627776}[$m.u]) as $unit
                    | if $unit == null then null else (($m.n | num) * $unit | floor) end
                  end
            end;
        (rows($stats) | map({key: .[0], value: .}) | from_entries) as $usage
        | [rows($inspect)[] | select(length == 6) | . as $row
            | ($row[0] | ltrimstr("/")) as $name
            | ($usage[$name] // null) as $u
            | ($u[2] // null | if . == null then [null, null] else split(" / ") end) as $mem
            | {
                name: $name,
                image: $row[1],
                state: $row[2],
                health: (if $row[3] == "none" then null else $row[3] end),
                started_at: $row[4],
                restarts: ($row[5] | num),
                cpu_percent: ($u[1] // null | percent),
                memory_used: ($mem[0] | bytes),
                memory_limit: ($mem[1] | bytes),
                memory_percent: ($u[3] // null | percent)
            }]
        | sort_by(.name)'
}

# monitor_status_json <generated at> <interval> <docker available: true|false>
#                     <host json> <containers json>
monitor_status_json() {
    jq -n \
        --arg generated_at "$1" \
        --arg interval "$2" \
        --arg docker "$3" \
        --argjson host "$4" \
        --argjson containers "$5" '
        {
            version: 1,
            generated_at: $generated_at,
            interval_seconds: ($interval | tonumber),
            docker_available: ($docker == "true"),
            host: $host,
            containers: $containers
        }'
}

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
