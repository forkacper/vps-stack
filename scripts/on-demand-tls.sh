#!/usr/bin/env bash
# On-demand TLS of the proxy: the endpoint Caddy asks before it obtains a
# certificate for a host it has not seen yet. Needed by the sites added with
# `add-site --on-demand-tls` (a wildcard or any host). See docs/adding-sites.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=lib/validate.sh
source "${SCRIPT_DIR}/../lib/validate.sh"

TEMPLATE="${REPO_ROOT}/templates/on-demand-tls.caddy.tmpl"

usage() {
    cat <<USAGE
Usage: vps-stack on-demand-tls <command>

Commands:
  set <url>   ask <url> before every new certificate; Caddy adds
              ?domain=<host> and obtains the certificate only on a 2xx
              answer, e.g. http://example-app-web/tls-check (a container on
              a project network) or https://api.example.com/tls-check
  unset       remove it (refused while a site uses on-demand TLS)
  show        print the endpoint, or nothing when it is not set

Options: --dry-run, --yes
USAGE
}

# on_demand_sites: the site files that use on-demand TLS, one per line.
on_demand_sites() {
    local file
    for file in "${SITES_DIR}"/*.caddy; do
        [[ -f "${file}" ]] || continue
        if grep -qxE '[[:space:]]*on_demand' "${file}"; then
            printf '%s\n' "${file}"
        fi
    done
}

# apply_or_restore <path>: validate and reload; on a rejected configuration
# undo the last write of <path> and stop.
apply_or_restore() {
    local path="$1"
    if is_dry_run; then
        log_dry "validate and reload the proxy"
        return 0
    fi
    if ! caddy_running; then
        log_warn "Container ${CADDY_CONTAINER} is not running. The change takes effect after: vps-stack proxy up"
        return 0
    fi
    if ! "${SCRIPT_DIR}/proxy.sh" validate live; then
        restore_last_write "${path}"
        die "Caddy rejected the new configuration. The previous state was restored, the proxy runs unchanged."
    fi
    "${SCRIPT_DIR}/proxy.sh" reload
}

cmd_set() {
    local url="${1:-}" content
    [[ -n "${url}" ]] || die "Give the URL: vps-stack on-demand-tls set <url>"
    validate_permission_url "${url}" || die "Invalid URL. Nothing was changed."
    require_etc_access write
    [[ -d "${SITES_DIR}" ]] || die "Directory ${SITES_DIR} does not exist. Run 'vps-stack provision' first."
    content="$(render_template "${TEMPLATE}" "URL=${url}")"

    if [[ -f "${ON_DEMAND_TLS_FILE}" && "$(cat "${ON_DEMAND_TLS_FILE}")" == "${content}" ]]; then
        log_ok "On-demand TLS already asks ${url}. Nothing to do."
        return 0
    fi
    run install -d -m 755 "${GLOBAL_OPTIONS_DIR}"
    write_file "${ON_DEMAND_TLS_FILE}" 644 <<<"${content}"
    apply_or_restore "${ON_DEMAND_TLS_FILE}"
    is_dry_run || log_ok "On-demand TLS asks ${url}"
    log_info "Check that it refuses an unknown host: vps-stack verify"
}

cmd_unset() {
    local sites target file
    require_etc_access write
    if [[ ! -f "${ON_DEMAND_TLS_FILE}" ]]; then
        log_ok "On-demand TLS is not set. Nothing to do."
        return 0
    fi
    sites="$(on_demand_sites)"
    if [[ -n "${sites}" ]]; then
        log_error "These sites use on-demand TLS:"
        while IFS= read -r file; do
            printf '  %s\n' "${file}" >&2
        done <<<"${sites}"
        die "Remove them first (vps-stack remove-site), then unset it."
    fi
    confirm "Remove the on-demand TLS endpoint?" || die "Aborted."
    target="${SITES_DIR}/.removed/on-demand-tls.caddy.$(date +%Y%m%d-%H%M%S)"
    run install -d -m 700 "${SITES_DIR}/.removed"
    run mv "${ON_DEMAND_TLS_FILE}" "${target}"
    if is_dry_run; then
        log_dry "validate and reload the proxy"
        return 0
    fi
    if caddy_running; then
        if ! "${SCRIPT_DIR}/proxy.sh" validate live; then
            mv "${target}" "${ON_DEMAND_TLS_FILE}"
            die "Validation failed. ${ON_DEMAND_TLS_FILE} was restored, nothing was changed."
        fi
        "${SCRIPT_DIR}/proxy.sh" reload
    fi
    log_ok "On-demand TLS removed. Copy of the file: ${target}"
}

cmd_show() {
    require_etc_access read
    [[ -f "${ON_DEMAND_TLS_FILE}" ]] || return 0
    on_demand_tls_url "${ON_DEMAND_TLS_FILE}"
}

main() {
    local command="" arg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
                if [[ -z "${command}" ]]; then
                    command="$1"
                elif [[ -z "${arg}" ]]; then
                    arg="$1"
                else
                    die "Too many arguments: $1"
                fi
                ;;
        esac
        shift
    done
    case "${command}" in
        set) cmd_set "${arg}" ;;
        unset)
            [[ -z "${arg}" ]] || die "Too many arguments: ${arg}"
            cmd_unset
            ;;
        show)
            [[ -z "${arg}" ]] || die "Too many arguments: ${arg}"
            cmd_show
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
