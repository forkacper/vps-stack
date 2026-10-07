#!/usr/bin/env bats

load helpers

MONITOR_TEMPLATE="${REPO_ROOT}/templates/site-monitor.caddy.tmpl"
# The example hash from the Caddy documentation (password "hiccup").
HASH='$2a$14$Zkx19XLiW6VYouLHR5NmfOFU0z2GTNmpkT/5qqR7hx4IjWJPDhjvG'

monitor_render() {
    monitor_site_render "${MONITOR_TEMPLATE}" "$@"
}

# --- login and hash ---------------------------------------------------------

@test "monitor user: generated-style and simple logins are valid" {
    local value
    for value in "monitor-k3f9" "admin" "ops_team" "a1b"; do
        run validate_monitor_user "${value}"
        [ "$status" -eq 0 ]
    done
}

@test "monitor user: invalid logins are rejected" {
    local value
    for value in "" "ab" "-admin" "Admin" "adm in" "adm:in" 'adm$in' "adm{in" \
        "$(repeat_char a 33)" $'admin\nevil'; do
        run validate_monitor_user "${value}"
        [ "$status" -ne 0 ]
    done
}

@test "bcrypt hash: a hash printed by caddy hash-password is valid" {
    run validate_bcrypt_hash "${HASH}"
    [ "$status" -eq 0 ]
}

@test "bcrypt hash: anything else is rejected" {
    local value
    for value in "" "hiccup" "${HASH}x" "${HASH%?}" "${HASH} extra" "${HASH}"$'\n' \
        '$2a$14$Zkx19XLiW6VYouLHR5NmfOFU0z2GTNmpkT/5qqR7hx4IjWJPDhjv}' \
        '$argon2id$v=19$m=47104,t=1,p=1$abc$def'; do
        run validate_bcrypt_hash "${value}"
        [ "$status" -ne 0 ]
    done
}

# --- IP addresses -----------------------------------------------------------

@test "ip: valid addresses are normalized" {
    run normalize_ip "203.0.113.7"
    [ "$status" -eq 0 ]
    [ "$output" = "203.0.113.7" ]
    run normalize_ip "2001:DB8::1"
    [ "$status" -eq 0 ]
    [ "$output" = "2001:db8::1" ]
    run normalize_ip "2001:db8:0:0:0:0:0:1"
    [ "$status" -eq 0 ]
    run normalize_ip "::1"
    [ "$status" -eq 0 ]
    run normalize_ip "fe80::"
    [ "$status" -eq 0 ]
}

@test "ip: invalid addresses are rejected" {
    local value
    for value in "" "256.1.1.1" "1.2.3" "1.2.3.4.5" "01.2.3.4" "1.2.3.4/24" "example.com" \
        "2001:db8::1::2" "2001:db8:::1" "12345::1" ":1" "1:" "1:2:3:4:5:6:7" "1:2:3:4:5:6:7:8:9" \
        "1::2:3:4:5:6:7:8" "::ffff:1.2.3.4" "fe80::1%eth0" "2001:db8::1/64" "1.2.3.4 5.6.7.8" \
        $'1.2.3.4\n5.6.7.8' "1.2.3.4}" "g::1"; do
        run normalize_ip "${value}"
        [ "$status" -ne 0 ]
    done
}

@test "ip: public addresses" {
    local value
    for value in "203.0.113.7" "8.8.8.8" "172.15.0.1" "172.32.0.1" "100.63.0.1" "100.128.0.1" \
        "2001:db8::1" "2a00:1450::1" "fd::1" "fe7f::1"; do
        run ip_is_public "${value}"
        [ "$status" -eq 0 ]
    done
}

@test "ip: private, Docker and reserved addresses are never public" {
    local value
    for value in "10.0.0.1" "127.0.0.1" "172.16.0.1" "172.17.0.1" "172.31.255.254" "192.168.1.1" \
        "169.254.1.1" "100.64.0.1" "100.127.255.1" "0.0.0.0" "224.0.0.1" "255.255.255.255" \
        "::" "::1" "fd00::1" "fc00::1" "fe80::1" "febf::1" "ff02::1"; do
        run ip_is_public "${value}"
        [ "$status" -ne 0 ]
    done
}

# --- site file --------------------------------------------------------------

@test "monitor site: rendered file" {
    run monitor_render "Status.Example.com" "monitor-k3f9" "${HASH}"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nstatus.example.com {\n    import common\n'* ]]
    [[ "$output" == *$'\n            monitor-k3f9 '"${HASH}"$'\n'* ]]
    [[ "$output" == *"import /etc/caddy/sites/.monitor-banned"* ]]
    [[ "$output" != *"{{"* ]]
}

@test "monitor site: the ban comes before the password inside route" {
    run monitor_render "status.example.com" "monitor-k3f9" "${HASH}"
    [ "$status" -eq 0 ]
    local route="${output#*    route {}"
    local before_auth="${route%%basic_auth*}"
    [[ "${before_auth}" == *"import /etc/caddy/sites/.monitor-banned"* ]]
}

@test "monitor site: the host line is found by the site tools" {
    local file="${BATS_TEST_TMPDIR}/_monitor.caddy"
    monitor_render "status.example.com" "monitor-k3f9" "${HASH}" >"${file}"
    run site_file_hosts "${file}"
    [ "$status" -eq 0 ]
    [ "$output" = "status.example.com" ]
}

@test "monitor site: injection through any value is refused" {
    run monitor_render $'status.example.com {\n    respond "pwned"\n}\nevil.example.com' "monitor-k3f9" "${HASH}"
    [ "$status" -ne 0 ]
    run monitor_render "status.example.com" $'monitor\n    respond "pwned"' "${HASH}"
    [ "$status" -ne 0 ]
    run monitor_render "status.example.com" "monitor-k3f9" "${HASH}"$'\n            evil '"${HASH}"
    [ "$status" -ne 0 ]
    run monitor_render "status.example.com" "monitor-k3f9" "{env.SECRET}"
    [ "$status" -ne 0 ]
    run monitor_render "status.example.com" "{{USER}}" "${HASH}"
    [ "$status" -ne 0 ]
    [[ "$output" != *"basic_auth"* ]]
}

@test "monitor site: a missing hash is refused" {
    run monitor_render "status.example.com" "monitor-k3f9" ""
    [ "$status" -ne 0 ]
    [[ "$output" != *"basic_auth"* ]]
}

# --- ban list ---------------------------------------------------------------

@test "ban snippet: empty list holds only the header" {
    run monitor_ban_snippet
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "${lines[0]}" == "# "* ]]
}

@test "ban snippet: addresses become one matcher and an abort" {
    run monitor_ban_snippet "203.0.113.7" "2001:DB8::1"
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = "@vps_stack_banned remote_ip 203.0.113.7 2001:db8::1" ]
    [ "${lines[2]}" = "abort @vps_stack_banned" ]
}

@test "ban snippet: an invalid address refuses the whole list" {
    run monitor_ban_snippet "203.0.113.7" $'198.51.100.1\nrespond "pwned"'
    [ "$status" -ne 0 ]
    [[ "$output" != *"@vps_stack_banned"* ]]
    run monitor_ban_snippet "203.0.113.0/24"
    [ "$status" -ne 0 ]
}

# --- status.json ------------------------------------------------------------

PROC="${REPO_ROOT}/tests/fixtures/proc"

# Real output of the two Docker commands (MONITOR_*_FORMAT), one container
# running with a health check, one without, one stopped.
INSPECT=$'/example-app-web|nginx:1.27-alpine|running|healthy|2026-10-07T16:07:02.297006011Z|0\n/example-app-db|mysql:8.0|running|none|2026-10-06T20:27:59.05089189Z|2\n/old-job|example/job:1.2|exited|none|2026-10-01T10:00:00Z|0'
STATS=$'example-app-web|0.05%|10.86MiB / 128MiB|8.48%\nexample-app-db|1.20%|525.7MiB / 768MiB|68.45%'

@test "cpu: sample sums every column and counts iowait as idle" {
    run monitor_cpu_sample "${PROC}/stat"
    [ "$status" -eq 0 ]
    [ "$output" = "10000 8500" ]
}

@test "cpu: percent between two samples" {
    # A decimal-comma locale must not leak into the number. Where pl_PL is
    # not installed, awk falls back to C and the check still holds.
    LC_ALL=pl_PL.UTF-8 run monitor_cpu_percent 10000 8500 11000 9250
    [ "$output" = "25.0" ]
    run monitor_cpu_percent 10000 8500 10000 8500
    [ "$output" = "" ]
}

@test "meminfo: values in bytes" {
    run monitor_meminfo "${PROC}/meminfo"
    [ "$output" = "4111978496 2055989248 2147479552 1073739776" ]
}

@test "host json: fields and values" {
    local json
    json="$(monitor_host_json "${PROC}" "vps-1" 2 "25.0" 42949672960 10737418240 true)"
    [ "$(jq -c 'keys' <<<"${json}")" = '["cpu_percent","cpus","disk","hostname","load","memory","reboot_required","swap","uptime_seconds"]' ]
    [ "$(jq -r '.hostname' <<<"${json}")" = "vps-1" ]
    [ "$(jq '.load == [0.42, 0.35, 0.3]' <<<"${json}")" = "true" ]
    [ "$(jq '.uptime_seconds' <<<"${json}")" = "93784" ]
    [ "$(jq '.memory.used' <<<"${json}")" = "2055989248" ]
    [ "$(jq '.swap.used' <<<"${json}")" = "1073739776" ]
    [ "$(jq '.cpu_percent == 25' <<<"${json}")" = "true" ]
    [ "$(jq '.reboot_required' <<<"${json}")" = "true" ]
}

@test "host json: the first sample has no cpu percent" {
    run monitor_host_json "${PROC}" "vps-1" 2 "" 1 1 false
    [ "$status" -eq 0 ]
    [ "$(jq '.cpu_percent' <<<"${output}")" = "null" ]
}

@test "host json: a hostile hostname stays a plain string" {
    local json
    json="$(monitor_host_json "${PROC}" '"}, "x": "<script>' 1 "" 1 1 false)"
    [ "$(jq -r '.hostname' <<<"${json}")" = '"}, "x": "<script>' ]
    [ "$(jq 'has("x")' <<<"${json}")" = "false" ]
}

@test "containers json: only the allowed fields, sorted by name" {
    local json
    json="$(monitor_containers_json "${INSPECT}" "${STATS}")"
    [ "$(jq -c '[.[].name]' <<<"${json}")" = '["example-app-db","example-app-web","old-job"]' ]
    [ "$(jq -c '[.[] | keys] | unique' <<<"${json}")" = '[["cpu_percent","health","image","memory_limit","memory_percent","memory_used","name","restarts","started_at","state"]]' ]
}

@test "containers json: values of a running container" {
    local web
    web="$(monitor_containers_json "${INSPECT}" "${STATS}" | jq -c '.[] | select(.name == "example-app-web")')"
    [ "${web}" = '{"name":"example-app-web","image":"nginx:1.27-alpine","state":"running","health":"healthy","started_at":"2026-10-07T16:07:02.297006011Z","restarts":0,"cpu_percent":0.05,"memory_used":11387535,"memory_limit":134217728,"memory_percent":8.48}' ]
}

@test "containers json: a stopped container has no usage and no health" {
    local job
    job="$(monitor_containers_json "${INSPECT}" "${STATS}" | jq -c '.[] | select(.name == "old-job")')"
    [ "$(jq -c '[.health, .cpu_percent, .memory_used, .memory_percent]' <<<"${job}")" = "[null,null,null,null]" ]
}

@test "containers json: malformed lines are dropped, odd units become null" {
    local json
    json="$(monitor_containers_json $'garbage\n/a|img|running|none|t|0|extra\n/b|img|running|none|t|x' $'b|--|1.5ZiB / weird|n/a')"
    [ "$(jq -c '[.[].name]' <<<"${json}")" = '["b"]' ]
    [ "$(jq -c '.[0] | [.restarts, .cpu_percent, .memory_used, .memory_limit, .memory_percent]' <<<"${json}")" = "[null,null,null,null,null]" ]
}

@test "containers json: no containers is an empty array" {
    run monitor_containers_json "" ""
    [ "$status" -eq 0 ]
    [ "$(jq -c . <<<"${output}")" = "[]" ]
}

@test "status json: top-level document" {
    local host containers json
    host="$(monitor_host_json "${PROC}" "vps-1" 2 "" 1 1 false)"
    containers="$(monitor_containers_json "${INSPECT}" "${STATS}")"
    json="$(monitor_status_json "2026-10-07T16:10:00Z" 10 true "${host}" "${containers}")"
    [ "$(jq -c 'keys' <<<"${json}")" = '["containers","docker_available","generated_at","host","interval_seconds","version"]' ]
    [ "$(jq -c '[.version, .interval_seconds, .docker_available, (.containers | length)]' <<<"${json}")" = "[1,10,true,3]" ]
}

@test "docker formats: no field outside the allow list is requested" {
    local field
    for field in Env Labels Mounts Ports Networks Cmd Entrypoint Args LogPath HostConfig NetworkSettings Volumes; do
        [[ "${MONITOR_INSPECT_FORMAT}" != *"${field}"* ]]
        [[ "${MONITOR_STATS_FORMAT}" != *"${field}"* ]]
    done
}

# --- ban list updates -------------------------------------------------------

@test "ban list: add keeps the list sorted and unique" {
    run monitor_banlist_apply add "203.0.113.7" <<<$'198.51.100.2\n203.0.113.7\n2001:db8::1'
    [ "$status" -eq 0 ]
    [ "$output" = $'198.51.100.2\n2001:db8::1\n203.0.113.7' ]
}

@test "ban list: add to an empty list" {
    run monitor_banlist_apply add "2001:DB8::1" </dev/null
    [ "$status" -eq 0 ]
    [ "$output" = "2001:db8::1" ]
}

@test "ban list: remove the address and nothing else" {
    run monitor_banlist_apply remove "203.0.113.7" <<<$'198.51.100.2\n203.0.113.7'
    [ "$status" -eq 0 ]
    [ "$output" = "198.51.100.2" ]
    run monitor_banlist_apply remove "203.0.113.7" <<<"203.0.113.7"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "ban list: private and Docker addresses are never added" {
    local ip
    for ip in "172.17.0.1" "10.0.0.5" "127.0.0.1" "fd00::1" "::1"; do
        run monitor_banlist_apply add "${ip}" <<<"198.51.100.2"
        [ "$status" -eq 0 ]
        [ "$output" = "198.51.100.2" ]
    done
}

@test "ban list: an invalid address is refused" {
    run monitor_banlist_apply add $'203.0.113.7\nrespond "pwned"' <<<"198.51.100.2"
    [ "$status" -ne 0 ]
    run monitor_banlist_apply add "203.0.113.0/24" </dev/null
    [ "$status" -ne 0 ]
    run monitor_banlist_apply drop "203.0.113.7" </dev/null
    [ "$status" -ne 0 ]
}

@test "ban list: garbage lines in the stored list are dropped" {
    run monitor_banlist_apply add "203.0.113.7" <<<$'# comment\n\nnot-an-ip\n198.51.100.2 }'
    [ "$status" -eq 0 ]
    [ "$output" = "203.0.113.7" ]
}

# --- fail2ban templates ------------------------------------------------------

@test "fail2ban jail: rendered with the log file and extra ignored addresses" {
    run render_template "${REPO_ROOT}/templates/fail2ban-monitor-jail.conf" \
        "LOG_FILE=/var/log/vps-stack-monitor/access.log" "IGNOREIP= 198.51.100.2"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nlogpath = /var/log/vps-stack-monitor/access.log\n'* ]]
    [[ "$output" == *" fe80::/10 198.51.100.2" ]]
}

@test "fail2ban action: every call goes through vps-stack monitor" {
    run render_template "${REPO_ROOT}/templates/fail2ban-monitor-action.conf" "VPS_STACK_BIN=/usr/local/bin/vps-stack"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nactionban = /usr/local/bin/vps-stack monitor ban <ip>\n'* ]]
    [[ "$output" == *$'\nactionunban = /usr/local/bin/vps-stack monitor unban <ip>'* ]]
}

# --- history ----------------------------------------------------------------

@test "history sample: only the allowed fields, running containers only" {
    local host containers sample
    host="$(monitor_host_json "${PROC}" "vps-1" 2 "25.0" 42949672960 10737418240 false)"
    containers="$(monitor_containers_json "${INSPECT}" "${STATS}")"
    sample="$(monitor_history_sample 1791400800 "12.5" "80.0" "${host}" "${containers}")"
    [ "$(jq -c 'keys' <<<"${sample}")" = '["containers","cpu","cpu_max","disk","disk_total","load","mem","mem_total","swap","swap_total","t"]' ]
    [ "$(jq -c '[.t, .cpu, .cpu_max, .mem, .disk]' <<<"${sample}")" = "[1791400800,12.5,80.0,2055989248,10737418240]" ]
    [ "$(jq -c '.containers' <<<"${sample}")" = '{"example-app-db":551236403,"example-app-web":11387535}' ]
    [ "$(wc -l <<<"${sample}")" -eq 1 ]
}

@test "history sample: the first window has no CPU values" {
    local host sample
    host="$(monitor_host_json "${PROC}" "vps-1" 2 "" 1 1 false)"
    sample="$(monitor_history_sample 1791400800 "" "" "${host}" "[]")"
    [ "$(jq -c '[.cpu, .cpu_max, .containers]' <<<"${sample}")" = "[null,null,{}]" ]
}

@test "history trim: keeps the newest lines" {
    local file="${BATS_TEST_TMPDIR}/history.jsonl"
    seq 1 10 >"${file}"
    monitor_history_trim "${file}" 4
    [ "$(cat "${file}")" = $'7\n8\n9\n10' ]
    monitor_history_trim "${file}" 4
    [ "$(wc -l <"${file}")" -eq 4 ]
    run monitor_history_trim "${BATS_TEST_TMPDIR}/missing" 4
    [ "$status" -eq 0 ]
}

@test "history json: valid samples only, a cut last line is skipped" {
    local file="${BATS_TEST_TMPDIR}/history.jsonl"
    printf '%s\n' '{"t":1,"cpu":1}' 'garbage' '[1,2]' '{"cpu":5}' '{"t":2,"cpu":2}' '{"t":3,"cp' >"${file}"
    run monitor_history_json "${file}" 300
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.version, .interval_seconds, [.samples[].t]]' <<<"${output}")" = "[1,300,[1,2]]" ]
}

@test "history json: no file yet is an empty history" {
    run monitor_history_json "${BATS_TEST_TMPDIR}/missing" 300
    [ "$status" -eq 0 ]
    [ "$(jq -c '.samples' <<<"${output}")" = "[]" ]
}

@test "monitor_max: decimals, and an empty value counts as missing" {
    [ "$(monitor_max 12.5 9.75)" = "12.5" ]
    [ "$(monitor_max 2.0 10.1)" = "10.1" ]
    [ "$(monitor_max "" 3.0)" = "3.0" ]
    [ "$(monitor_max 4.0 "")" = "4.0" ]
    [ "$(LC_ALL=pl_PL.UTF-8 monitor_max 1.5 1.25)" = "1.5" ]
}
