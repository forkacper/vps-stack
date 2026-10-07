#!/usr/bin/env bash
# Input validators and the site config renderer. Pure logic: no root, no
# Docker, no network. Covered by tests/*.bats.
#
# site_render() is the only way a site file gets generated and it validates
# every value itself, so nothing unvalidated can reach the template.
# Requires lib/common.sh (render_template).

if [[ -n "${VPS_STACK_VALIDATE_LOADED:-}" ]]; then
    return 0
fi
VPS_STACK_VALIDATE_LOADED=1

_validate_fail() {
    printf 'Invalid value: %s\n' "$*" >&2
    return 1
}

# has_unsafe_chars <value>: true when the value contains whitespace, a
# control character or one of { } " ' # $ \ `
has_unsafe_chars() {
    local LC_ALL=C
    case "$1" in
        *[[:space:]]* | *[[:cntrl:]]*) return 0 ;;
        *"{"* | *"}"* | *'"'* | *"'"* | *"#"* | *'$'* | *"\\"* | *'`'*) return 0 ;;
        *) return 1 ;;
    esac
}

# normalize_domain <value>: print the lowercased domain, or fail with a
# message on stderr.
normalize_domain() {
    local LC_ALL=C
    local raw="${1:-}" domain label rest
    if [[ -z "${raw}" ]]; then
        _validate_fail "the domain name is empty."
        return 1
    fi
    if has_unsafe_chars "${raw}"; then
        _validate_fail "the domain contains whitespace or special characters."
        return 1
    fi
    domain="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
    case "${domain}" in
        *[!\ -~]*)
            _validate_fail "the domain contains non-ASCII characters. Give it in punycode (xn--...)."
            return 1
            ;;
        *"://"*)
            _validate_fail "give the bare domain, without a scheme (http://, https://)."
            return 1
            ;;
        *"*"*)
            _validate_fail "wildcards (*.example.com) are not supported in version 0.1."
            return 1
            ;;
        *":"*)
            _validate_fail "give the bare domain, without a port."
            return 1
            ;;
        *"/"*)
            _validate_fail "give the bare domain, without a path."
            return 1
            ;;
        *) ;;
    esac
    if [[ ! "${domain}" =~ ^[a-z0-9.-]+$ ]]; then
        _validate_fail "the domain may only contain a-z, 0-9, dots and hyphens."
        return 1
    fi
    if [[ "${#domain}" -gt 253 ]]; then
        _validate_fail "the domain is longer than 253 characters."
        return 1
    fi
    case "${domain}" in
        *..* | .* | *.)
            _validate_fail "the domain has an empty label (double, leading or trailing dot)."
            return 1
            ;;
        *.*) ;;
        *)
            _validate_fail "the domain must contain at least one dot."
            return 1
            ;;
    esac
    if [[ "${domain}" =~ ^[0-9.]+$ ]]; then
        _validate_fail "give a domain name, not an IP address."
        return 1
    fi
    rest="${domain}"
    while [[ -n "${rest}" ]]; do
        label="${rest%%.*}"
        if [[ "${rest}" == *.* ]]; then
            rest="${rest#*.}"
        else
            rest=""
        fi
        if [[ "${#label}" -lt 1 || "${#label}" -gt 63 ]]; then
            _validate_fail "every domain label must be 1 to 63 characters long."
            return 1
        fi
        case "${label}" in
            -* | *-)
                _validate_fail "a domain label must not start or end with a hyphen."
                return 1
                ;;
            *) ;;
        esac
    done
    printf '%s\n' "${domain}"
}

# validate_upstream <value>: <container-name>:<port>
validate_upstream() {
    local LC_ALL=C
    local upstream="${1:-}" port
    if has_unsafe_chars "${upstream}"; then
        _validate_fail "the upstream contains whitespace or special characters."
        return 1
    fi
    if [[ ! "${upstream}" =~ ^[a-z0-9][a-z0-9_.-]{0,62}:[0-9]{1,5}$ ]]; then
        _validate_fail "the upstream must look like container-name:port, e.g. example-app-web:80."
        return 1
    fi
    port="${upstream##*:}"
    port=$((10#${port}))
    if [[ "${port}" -lt 1 || "${port}" -gt 65535 ]]; then
        _validate_fail "the upstream port must be in the range 1-65535."
        return 1
    fi
}

# validate_size <value>: e.g. 50MB
validate_size() {
    local LC_ALL=C
    local size="${1:-}"
    if has_unsafe_chars "${size}"; then
        _validate_fail "the size contains whitespace or special characters."
        return 1
    fi
    if [[ ! "${size}" =~ ^[0-9]{1,5}(KB|MB|GB)$ ]]; then
        _validate_fail "the size must be a number followed by KB, MB or GB, e.g. 50MB."
        return 1
    fi
}

# validate_port <value>: TCP port 1-65535
validate_port() {
    local port="${1:-}"
    [[ "${port}" =~ ^[0-9]{1,5}$ ]] || return 1
    port=$((10#${port}))
    [[ "${port}" -ge 1 && "${port}" -le 65535 ]]
}

# validate_monitor_user <value>: login of the status page.
validate_monitor_user() {
    local LC_ALL=C
    local re='^[a-z0-9][a-z0-9_-]{2,31}$'
    if [[ ! "${1:-}" =~ ${re} ]]; then
        _validate_fail "the login must be 3 to 32 characters: a-z, 0-9, _ and -, starting with a letter or digit."
        return 1
    fi
}

# validate_bcrypt_hash <value>: a hash as printed by `caddy hash-password`.
validate_bcrypt_hash() {
    local LC_ALL=C
    # shellcheck disable=SC2016  # the dollar signs are literal parts of the pattern
    local re='^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$'
    if [[ ! "${1:-}" =~ ${re} ]]; then
        _validate_fail "not a bcrypt hash."
        return 1
    fi
}

# normalize_ip <value>: print a plain IPv4 or IPv6 address in lowercase, or
# fail. No CIDR, no zone, no IPv4-mapped IPv6 forms.
normalize_ip() {
    local LC_ALL=C
    local ip octet group count=0
    local re_v4='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
    local -a groups
    ip="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${ip}" =~ ${re_v4} ]]; then
        for octet in "${BASH_REMATCH[@]:1}"; do
            if [[ "${octet}" == 0?* || "$((10#${octet}))" -gt 255 ]]; then
                _validate_fail "'${1:-}' is not an IPv4 address."
                return 1
            fi
        done
        printf '%s\n' "${ip}"
        return 0
    fi
    # IPv6: hex groups of 1-4 digits, at most one "::", 8 groups without it.
    if [[ ! "${ip}" =~ ^[0-9a-f:]{2,39}$ || "${ip}" != *:* || "${ip}" == *:::* ]]; then
        _validate_fail "'${1:-}' is not an IP address."
        return 1
    fi
    case "${ip}" in
        *::*::*)
            _validate_fail "'${1:-}' is not an IPv6 address."
            return 1
            ;;
        *) ;;
    esac
    IFS=':' read -r -a groups <<<"${ip}"
    for group in "${groups[@]}"; do
        if [[ "${#group}" -gt 4 ]]; then
            _validate_fail "'${1:-}' is not an IPv6 address."
            return 1
        fi
        [[ -n "${group}" ]] && count=$((count + 1))
    done
    if [[ "${ip}" == *::* && "${count}" -gt 7 ]] || [[ "${ip}" != *::* && "${count}" -ne 8 ]]; then
        _validate_fail "'${1:-}' is not an IPv6 address."
        return 1
    fi
    case "${ip}" in
        :[!:]* | *[!:]:)
            _validate_fail "'${1:-}' is not an IPv6 address."
            return 1
            ;;
        *) ;;
    esac
    printf '%s\n' "${ip}"
}

# ip_is_public <normalized ip>: true for an address that can belong to a
# client on the internet. Private, loopback, link-local, shared (CGNAT),
# multicast and reserved ranges are not public. Docker's own networks live in
# the private ranges, so they are never treated as public either.
ip_is_public() {
    local ip="$1" a b first
    if [[ "${ip}" == *.* ]]; then
        a="${ip%%.*}"
        b="${ip#*.}"
        b="${b%%.*}"
        case "${a}" in
            0 | 10 | 127) return 1 ;;
            *) ;;
        esac
        [[ "${a}" -ge 224 ]] && return 1
        [[ "${a}" == "169" && "${b}" == "254" ]] && return 1
        [[ "${a}" == "172" && "${b}" -ge 16 && "${b}" -le 31 ]] && return 1
        [[ "${a}" == "192" && "${b}" == "168" ]] && return 1
        [[ "${a}" == "100" && "${b}" -ge 64 && "${b}" -le 127 ]] && return 1
        return 0
    fi
    # IPv6: look at the first group padded to 4 digits. "::..." starts with
    # 0000 (unspecified, loopback, IPv4-compatible and similar): not public.
    first="${ip%%:*}"
    while [[ "${#first}" -lt 4 ]]; do
        first="0${first}"
    done
    case "${first}" in
        0000 | fc?? | fd?? | fe[89ab]? | ff??) return 1 ;;
        *) return 0 ;;
    esac
}

# normalize_domain_list <csv>: print one normalized domain per line.
normalize_domain_list() {
    local csv="${1:-}" item normalized
    local -a items
    [[ -n "${csv}" ]] || return 0
    # Checked on the whole list first: `read` below only sees the first line,
    # so a newline would otherwise hide everything after it.
    if has_unsafe_chars "${csv}"; then
        _validate_fail "the domain list contains whitespace or special characters."
        return 1
    fi
    case "${csv}" in
        ,* | *, | *,,*)
            _validate_fail "the domain list has an empty item: ${csv}"
            return 1
            ;;
        *) ;;
    esac
    IFS=',' read -r -a items <<<"${csv}"
    for item in "${items[@]}"; do
        normalized="$(normalize_domain "${item}")" || return 1
        printf '%s\n' "${normalized}"
    done
}

# site_render <template> <domain> <upstream> [aliases_csv] [redirects_csv] [max_body]
# Validates every argument and prints the site config. Fails before producing
# any output when a single value is invalid.
site_render() {
    local template="$1" raw_domain="${2:-}" upstream="${3:-}"
    local aliases_csv="${4:-}" redirects_csv="${5:-}" max_body="${6:-}"
    local domain aliases redirects host seen domains body_limit redirect_blocks redirect_hosts

    domain="$(normalize_domain "${raw_domain}")" || return 1
    validate_upstream "${upstream}" || return 1
    aliases="$(normalize_domain_list "${aliases_csv}")" || return 1
    redirects="$(normalize_domain_list "${redirects_csv}")" || return 1
    if [[ -n "${max_body}" ]]; then
        validate_size "${max_body}" || return 1
    fi

    # A host may appear only once across domain, aliases and redirects.
    seen=" ${domain} "
    domains="${domain}"
    for host in ${aliases}; do
        if [[ "${seen}" == *" ${host} "* ]]; then
            _validate_fail "domain ${host} was given more than once."
            return 1
        fi
        seen="${seen}${host} "
        domains="${domains}, ${host}"
    done
    redirect_hosts=""
    for host in ${redirects}; do
        if [[ "${seen}" == *" ${host} "* ]]; then
            _validate_fail "domain ${host} was given more than once."
            return 1
        fi
        seen="${seen}${host} "
        redirect_hosts="${redirect_hosts:+${redirect_hosts}, }${host}"
    done

    body_limit=""
    if [[ -n "${max_body}" ]]; then
        body_limit="    request_body {"$'\n'"        max_size ${max_body}"$'\n'"    }"$'\n'
    fi
    redirect_blocks=""
    if [[ -n "${redirect_hosts}" ]]; then
        redirect_blocks=$'\n'"${redirect_hosts} {"$'\n'"    redir https://${domain}{uri} permanent"$'\n'"}"
    fi

    render_template "${template}" \
        "DOMAINS=${domains}" \
        "BODY_LIMIT=${body_limit}" \
        "UPSTREAM=${upstream}" \
        "REDIRECT_BLOCKS=${redirect_blocks}"
}
