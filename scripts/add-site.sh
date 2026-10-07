#!/usr/bin/env bash
# Add a domain to the shared proxy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=lib/validate.sh
source "${SCRIPT_DIR}/../lib/validate.sh"

SITE_TEMPLATE="${REPO_ROOT}/templates/site-standard.caddy.tmpl"

usage() {
    cat <<USAGE
Usage: vps-stack add-site <domain> <upstream> [options]

Example: vps-stack add-site app.example.com example-app-web:80

  <domain>     domain name, e.g. app.example.com
  <upstream>   container-name:port on the proxy network, e.g. example-app-web:80

Options:
  --alias <d1,d2>           additional domains served by the same upstream
  --redirect-from <d1,d2>   domains redirected (301) to the main domain
  --max-body <size>         request body size limit, e.g. 50MB (KB, MB, GB)
  --server-ip <address>     public address of the server for the DNS check
                            (may be given twice: IPv4 and IPv6)
  --no-dns-check            skip the DNS check
  --force                   overwrite an existing site file with other content
  --dry-run                 show what would be done, change nothing
  --yes                     ask no questions (a DNS mismatch still needs an
                            explicit --no-dns-check)
USAGE
}

need_value() {
    [[ $# -ge 2 ]] || die "Option $1 needs a value."
}

check_upstream_container() {
    local container="$1" members
    if ! have_cmd docker || ! docker info >/dev/null 2>&1; then
        log_warn "Docker is not available, not checking the upstream container."
        return 0
    fi
    members="$(docker network inspect "${PROXY_NETWORK}" \
        --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' 2>/dev/null || true)"
    if grep -qxF -- "${container}" <<<"${members}"; then
        log_ok "Container ${container} is on the ${PROXY_NETWORK} network."
        return 0
    fi
    log_warn "Container ${container} is not attached to the ${PROXY_NETWORK} network (or is not running)."
    log_warn "Until it is started the site will return a 502 error."
    confirm "Add the site anyway?" || die "Aborted. Nothing was changed."
}

main() {
    local raw_domain="" upstream="" aliases="" redirects="" max_body=""
    local dns_check=1 force=0
    SERVER_IPS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --alias)
                need_value "$@"
                aliases="$2"
                shift
                ;;
            --redirect-from)
                need_value "$@"
                redirects="$2"
                shift
                ;;
            --max-body)
                need_value "$@"
                max_body="$2"
                shift
                ;;
            --server-ip)
                need_value "$@"
                SERVER_IPS+=("$2")
                shift
                ;;
            --no-dns-check) dns_check=0 ;;
            --force) force=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --yes | -y) ASSUME_YES=1 ;;
            -h | --help)
                usage
                exit 0
                ;;
            -*)
                usage >&2
                die "Unknown option: $1"
                ;;
            *)
                if [[ -z "${raw_domain}" ]]; then
                    raw_domain="$1"
                elif [[ -z "${upstream}" ]]; then
                    upstream="$1"
                else
                    die "Too many arguments: $1"
                fi
                ;;
        esac
        shift
    done
    if [[ -z "${raw_domain}" || -z "${upstream}" ]]; then
        usage >&2
        exit 2
    fi

    # 1. Validation. site_render validates every value before rendering.
    local content domain target
    local -a hosts=()
    content="$(site_render "${SITE_TEMPLATE}" "${raw_domain}" "${upstream}" "${aliases}" "${redirects}" "${max_body}")" ||
        die "Invalid arguments. Nothing was changed."
    domain="$(normalize_domain "${raw_domain}")"
    local host
    while IFS= read -r host; do
        [[ -n "${host}" ]] && hosts+=("${host}")
    done < <(
        printf '%s\n' "${domain}"
        normalize_domain_list "${aliases}"
        normalize_domain_list "${redirects}"
    )

    require_etc_access write
    stack_config_load "${STACK_ENV_FILE}"
    [[ -d "${SITES_DIR}" ]] || die "Directory ${SITES_DIR} does not exist. Run 'vps-stack provision' first."
    target="${SITES_DIR}/${domain}.caddy"

    # 2. Duplicates in other site files.
    site_refuse_duplicates "${target}" "${hosts[@]}"

    # Existing file: identical is a no-op, different needs --force.
    if [[ -f "${target}" ]]; then
        if [[ "$(cat "${target}")" == "${content}" ]]; then
            log_ok "Domain ${domain} is already configured identically. Nothing to do."
            exit 0
        fi
        if [[ "${force}" != "1" ]]; then
            log_error "File ${target} already exists with different content:"
            sed 's/^/    | /' "${target}" >&2
            die "Use --force to overwrite it (the previous version is kept as *.bak.<timestamp>)."
        fi
    fi

    # 3. DNS.
    if [[ "${dns_check}" == "1" ]]; then
        dns_check_or_confirm "${hosts[@]}"
    else
        log_warn "DNS check skipped (--no-dns-check)."
    fi

    # 4. Upstream container.
    check_upstream_container "${upstream%%:*}"

    # 5. Write the file.
    write_file "${target}" 644 <<<"${content}"
    if is_dry_run; then
        log_dry "validate and reload the proxy"
        exit 0
    fi

    # 6./7. Validate, roll back on failure, reload on success.
    if ! caddy_running; then
        log_warn "Container ${CADDY_CONTAINER} is not running. The file was written but not validated."
        log_info "Start the proxy: vps-stack proxy up"
        exit 0
    fi
    if ! "${SCRIPT_DIR}/proxy.sh" validate live; then
        restore_last_write "${target}"
        die "Caddy rejected the new configuration. The previous state was restored, the proxy runs unchanged."
    fi
    "${SCRIPT_DIR}/proxy.sh" reload

    log_ok "Added ${domain} -> ${upstream}"
    log_info "The certificate is obtained automatically. To watch: vps-stack proxy logs"
}

main "$@"
