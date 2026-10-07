#!/usr/bin/env bats

load helpers

@test "render: minimal site" {
    run render "app.example.com" "example-app-web:80"
    [ "$status" -eq 0 ]
    local expected
    expected="$(printf '%s\n' \
        'app.example.com {' \
        '    import common' \
        '    reverse_proxy example-app-web:80' \
        '}')"
    [ "$output" = "$expected" ]
}

@test "render: domain is lowercased" {
    run render "App.Example.COM" "example-app-web:80"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "app.example.com {" ]
}

@test "render: aliases share the block with the main domain" {
    run render "example.com" "example-app-web:80" "www.example.com,app.example.com"
    [ "$status" -eq 0 ]
    local expected
    expected="$(printf '%s\n' \
        'example.com, www.example.com, app.example.com {' \
        '    import common' \
        '    reverse_proxy example-app-web:80' \
        '}')"
    [ "$output" = "$expected" ]
}

@test "render: redirects get their own block" {
    run render "example.com" "example-app-web:80" "" "www.example.com,example.org"
    [ "$status" -eq 0 ]
    local expected
    expected="$(printf '%s\n' \
        'example.com {' \
        '    import common' \
        '    reverse_proxy example-app-web:80' \
        '}' \
        '' \
        'www.example.com, example.org {' \
        '    redir https://example.com{uri} permanent' \
        '}')"
    [ "$output" = "$expected" ]
}

@test "render: body limit" {
    run render "example.com" "example-app-web:80" "" "" "50MB"
    [ "$status" -eq 0 ]
    local expected
    expected="$(printf '%s\n' \
        'example.com {' \
        '    import common' \
        '    request_body {' \
        '        max_size 50MB' \
        '    }' \
        '    reverse_proxy example-app-web:80' \
        '}')"
    [ "$output" = "$expected" ]
}

@test "render: aliases, redirects and body limit together" {
    run render "example.com" "example-app-web:8080" "app.example.com" "www.example.com" "2GB"
    [ "$status" -eq 0 ]
    local expected
    expected="$(printf '%s\n' \
        'example.com, app.example.com {' \
        '    import common' \
        '    request_body {' \
        '        max_size 2GB' \
        '    }' \
        '    reverse_proxy example-app-web:8080' \
        '}' \
        '' \
        'www.example.com {' \
        '    redir https://example.com{uri} permanent' \
        '}')"
    [ "$output" = "$expected" ]
}

@test "render: output has no leftover placeholders" {
    run render "example.com" "example-app-web:80" "app.example.com" "www.example.com" "50MB"
    [ "$status" -eq 0 ]
    [[ "$output" != *"{{"* ]]
    [[ "$output" != *"}}"* ]]
}

@test "render: ampersand-free literal substitution keeps {uri} intact" {
    run render "example.com" "example-app-web:80" "" "www.example.com"
    [ "$status" -eq 0 ]
    [[ "$output" == *'redir https://example.com{uri} permanent'* ]]
}

# --- injection attempts: refused before anything is rendered ----------------

# Asserts a refusal that produced no config text at all.
assert_refused() {
    [ "$status" -ne 0 ]
    [[ "$output" != *"reverse_proxy"* ]]
    [[ "$output" != *"import common"* ]]
}

@test "injection: block injected through the domain" {
    run render $'example.com {\n    respond "pwned"\n}\nevil.example.com' "web:80"
    assert_refused
}

@test "injection: brace in the domain" {
    run render "example.com{" "web:80"
    assert_refused
}

@test "injection: directive injected through the upstream" {
    run render "example.com" $'web:80\n    respond "pwned"'
    assert_refused
}

@test "injection: closing brace in the upstream" {
    run render "example.com" "web:80}"
    assert_refused
}

@test "injection: command substitution in the upstream is not executed" {
    local marker="${BATS_TEST_TMPDIR}/pwned"
    run render "example.com" "\$(touch ${marker}):80"
    assert_refused
    [ ! -e "${marker}" ]
}

@test "injection: backticks in the domain are not executed" {
    local marker="${BATS_TEST_TMPDIR}/pwned"
    run render "\`touch ${marker}\`.example.com" "web:80"
    assert_refused
    [ ! -e "${marker}" ]
}

@test "injection: Caddy placeholder in the upstream" {
    run render "example.com" "{env.SECRET}:80"
    assert_refused
}

@test "injection: environment substitution in the domain" {
    run render '{$HOME}.example.com' "web:80"
    assert_refused
}

@test "injection: brace in an alias" {
    run render "example.com" "web:80" "www.example.com,evil.example.com {"
    assert_refused
}

@test "injection: newline in a redirect" {
    run render "example.com" "web:80" "" $'www.example.com\nevil.example.com'
    assert_refused
}

@test "injection: brace in the body limit" {
    run render "example.com" "web:80" "" "" "50MB}"
    assert_refused
}

@test "injection: directive in the body limit" {
    run render "example.com" "web:80" "" "" $'50MB\n    respond "pwned"'
    assert_refused
}

@test "injection: template placeholder passed as a value" {
    run render "example.com" "{{UPSTREAM}}:80"
    assert_refused
}

# --- other refusals ---------------------------------------------------------

@test "render: the same host as domain and alias is refused" {
    run render "example.com" "web:80" "example.com"
    assert_refused
}

@test "render: the same host as alias and redirect is refused" {
    run render "example.com" "web:80" "www.example.com" "www.example.com"
    assert_refused
}

@test "render: empty element in a list is refused" {
    run render "example.com" "web:80" "www.example.com,,app.example.com"
    assert_refused
}

@test "render: wildcard alias is refused" {
    run render "example.com" "web:80" "*.example.com"
    assert_refused
}

@test "render: missing upstream is refused" {
    run render "example.com" ""
    assert_refused
}

# --- generic template helpers -----------------------------------------------

@test "tpl_replace: replaces every occurrence literally" {
    tpl_replace "a {{X}} b {{X}} c" "{{X}}" "1&2"
    [ "$REPLY" = "a 1&2 b 1&2 c" ]
}

@test "render_template: unknown placeholder is an error" {
    local template="${BATS_TEST_TMPDIR}/t.tmpl"
    printf 'value: {{MISSING}}\n' >"${template}"
    run render_template "${template}" "OTHER=1"
    [ "$status" -ne 0 ]
}

@test "render_template: values are not expanded by the shell" {
    local template="${BATS_TEST_TMPDIR}/t.tmpl"
    printf 'value: {{V}}\n' >"${template}"
    run render_template "${template}" 'V=$HOME `id` $(id)'
    [ "$status" -eq 0 ]
    [ "$output" = 'value: $HOME `id` $(id)' ]
}
