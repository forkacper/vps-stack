#!/usr/bin/env bats

load helpers

# --- domains: valid ---------------------------------------------------------

@test "domain: example.com is valid" {
    run normalize_domain "example.com"
    [ "$status" -eq 0 ]
    [ "$output" = "example.com" ]
}

@test "domain: subdomain is valid" {
    run normalize_domain "app.example.com"
    [ "$status" -eq 0 ]
    [ "$output" = "app.example.com" ]
}

@test "domain: hyphen inside a label is valid" {
    run normalize_domain "a-b.example.co"
    [ "$status" -eq 0 ]
    [ "$output" = "a-b.example.co" ]
}

@test "domain: punycode is valid" {
    run normalize_domain "xn--bcher-kva.example.com"
    [ "$status" -eq 0 ]
    [ "$output" = "xn--bcher-kva.example.com" ]
}

@test "domain: uppercase is normalized to lowercase" {
    run normalize_domain "Example.com"
    [ "$status" -eq 0 ]
    [ "$output" = "example.com" ]
}

@test "domain: label of exactly 63 characters is valid" {
    run normalize_domain "$(repeat_char a 63).example.com"
    [ "$status" -eq 0 ]
}

# --- domains: invalid -------------------------------------------------------

@test "domain: space is rejected" {
    run normalize_domain "exa mple.com"
    [ "$status" -ne 0 ]
}

@test "domain: brace is rejected" {
    run normalize_domain "example.com{"
    [ "$status" -ne 0 ]
}

@test "domain: newline is rejected" {
    run normalize_domain $'example.com\nevil.example.com'
    [ "$status" -ne 0 ]
}

@test "domain: trailing newline is rejected" {
    run normalize_domain $'example.com\n'
    [ "$status" -ne 0 ]
}

@test "domain: wildcard is rejected" {
    run normalize_domain "*.example.com"
    [ "$status" -ne 0 ]
    [[ "$output" == *"wildcard"* ]]
}

@test "domain: leading hyphen is rejected" {
    run normalize_domain "-a.com"
    [ "$status" -ne 0 ]
}

@test "domain: trailing hyphen is rejected" {
    run normalize_domain "a-.com"
    [ "$status" -ne 0 ]
}

@test "domain: single label is rejected" {
    run normalize_domain "localhost"
    [ "$status" -ne 0 ]
}

@test "domain: IPv4 address is rejected" {
    run normalize_domain "1.2.3.4"
    [ "$status" -ne 0 ]
}

@test "domain: IPv6 address is rejected" {
    run normalize_domain "2001:db8::1"
    [ "$status" -ne 0 ]
}

@test "domain: empty string is rejected" {
    run normalize_domain ""
    [ "$status" -ne 0 ]
}

@test "domain: double dot is rejected" {
    run normalize_domain "example..com"
    [ "$status" -ne 0 ]
}

@test "domain: leading dot is rejected" {
    run normalize_domain ".example.com"
    [ "$status" -ne 0 ]
}

@test "domain: trailing dot is rejected" {
    run normalize_domain "example.com."
    [ "$status" -ne 0 ]
}

@test "domain: label longer than 63 characters is rejected" {
    run normalize_domain "$(repeat_char a 64).example.com"
    [ "$status" -ne 0 ]
}

@test "domain: name longer than 253 characters is rejected" {
    local label
    label="$(repeat_char a 60)"
    run normalize_domain "${label}.${label}.${label}.${label}.${label}.com"
    [ "$status" -ne 0 ]
}

@test "domain: port is rejected" {
    run normalize_domain "example.com:8080"
    [ "$status" -ne 0 ]
}

@test "domain: scheme is rejected" {
    run normalize_domain "https://example.com"
    [ "$status" -ne 0 ]
}

@test "domain: path is rejected" {
    run normalize_domain "example.com/admin"
    [ "$status" -ne 0 ]
}

@test "domain: unicode is rejected with a punycode hint" {
    run normalize_domain "bücher.example.com"
    [ "$status" -ne 0 ]
    [[ "$output" == *"xn--"* ]]
}

@test "domain: underscore is rejected" {
    run normalize_domain "my_app.example.com"
    [ "$status" -ne 0 ]
}

@test "domain: shell metacharacters are rejected" {
    local value
    for value in 'example.com;id' 'example.com$(id)' 'example.com`id`' 'example.com"' "example.com'" \
        'example.com#x' 'example.com\x' $'example.com\tx'; do
        run normalize_domain "${value}"
        [ "$status" -ne 0 ]
    done
}

# --- upstreams --------------------------------------------------------------

@test "upstream: web:80 is valid" {
    run validate_upstream "web:80"
    [ "$status" -eq 0 ]
}

@test "upstream: my-app_web:8080 is valid" {
    run validate_upstream "my-app_web:8080"
    [ "$status" -eq 0 ]
}

@test "upstream: port 65535 is valid" {
    run validate_upstream "web:65535"
    [ "$status" -eq 0 ]
}

@test "upstream: missing port is rejected" {
    run validate_upstream "web"
    [ "$status" -ne 0 ]
}

@test "upstream: port 0 is rejected" {
    run validate_upstream "web:0"
    [ "$status" -ne 0 ]
}

@test "upstream: port 99999 is rejected" {
    run validate_upstream "web:99999"
    [ "$status" -ne 0 ]
}

@test "upstream: port 65536 is rejected" {
    run validate_upstream "web:65536"
    [ "$status" -ne 0 ]
}

@test "upstream: trailing words are rejected" {
    run validate_upstream "web:80 evil"
    [ "$status" -ne 0 ]
}

@test "upstream: scheme is rejected" {
    run validate_upstream "http://web:80"
    [ "$status" -ne 0 ]
}

@test "upstream: brace is rejected" {
    run validate_upstream "web:80}"
    [ "$status" -ne 0 ]
}

@test "upstream: command substitution is rejected" {
    run validate_upstream '$(id):80'
    [ "$status" -ne 0 ]
}

@test "upstream: semicolon is rejected" {
    run validate_upstream "web:80;id"
    [ "$status" -ne 0 ]
}

@test "upstream: uppercase is rejected" {
    run validate_upstream "Web:80"
    [ "$status" -ne 0 ]
}

@test "upstream: newline is rejected" {
    run validate_upstream $'web:80\nevil:80'
    [ "$status" -ne 0 ]
}

@test "upstream: empty string is rejected" {
    run validate_upstream ""
    [ "$status" -ne 0 ]
}

# --- sizes ------------------------------------------------------------------

@test "size: 50MB is valid" {
    run validate_size "50MB"
    [ "$status" -eq 0 ]
}

@test "size: KB and GB units are valid" {
    run validate_size "512KB"
    [ "$status" -eq 0 ]
    run validate_size "2GB"
    [ "$status" -eq 0 ]
}

@test "size: space is rejected" {
    run validate_size "50 MB"
    [ "$status" -ne 0 ]
}

@test "size: negative value is rejected" {
    run validate_size "-1MB"
    [ "$status" -ne 0 ]
}

@test "size: unknown unit is rejected" {
    run validate_size "50TB"
    [ "$status" -ne 0 ]
}

@test "size: brace is rejected" {
    run validate_size "50MB}"
    [ "$status" -ne 0 ]
}

@test "size: lowercase unit is rejected" {
    run validate_size "50mb"
    [ "$status" -ne 0 ]
}

@test "size: empty string is rejected" {
    run validate_size ""
    [ "$status" -ne 0 ]
}

# --- ports ------------------------------------------------------------------

@test "port: bounds" {
    run validate_port "1"
    [ "$status" -eq 0 ]
    run validate_port "65535"
    [ "$status" -eq 0 ]
    run validate_port "0"
    [ "$status" -ne 0 ]
    run validate_port "65536"
    [ "$status" -ne 0 ]
    run validate_port "22a"
    [ "$status" -ne 0 ]
    run validate_port ""
    [ "$status" -ne 0 ]
}

# --- unsafe characters ------------------------------------------------------

@test "has_unsafe_chars: every forbidden character is detected" {
    local value
    for value in 'a b' $'a\tb' $'a\nb' $'a\rb' 'a{b' 'a}b' 'a"b' "a'b" 'a#b' 'a$b' 'a\b' 'a`b'; do
        run has_unsafe_chars "${value}"
        [ "$status" -eq 0 ]
    done
}

@test "has_unsafe_chars: plain values pass" {
    run has_unsafe_chars "app.example.com"
    [ "$status" -ne 0 ]
    run has_unsafe_chars "my-app_web:8080"
    [ "$status" -ne 0 ]
}
