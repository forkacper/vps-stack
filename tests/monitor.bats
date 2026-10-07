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
