#!/usr/bin/env bash
# Remove a site from the proxy. The file is moved aside, never deleted.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=lib/validate.sh
source "${SCRIPT_DIR}/../lib/validate.sh"

usage() {
    cat <<USAGE
Usage: vps-stack remove-site <domain> [--dry-run] [--yes]

Moves the site file to ${SITES_DIR}/.removed/ (it is not deleted), validates
the configuration and reloads the proxy.
USAGE
}

main() {
    local raw_domain="" domain file removed_dir target
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
                [[ -z "${raw_domain}" ]] || die "Give exactly one domain."
                raw_domain="$1"
                ;;
        esac
        shift
    done
    [[ -n "${raw_domain}" ]] || {
        usage >&2
        exit 2
    }
    domain="$(normalize_domain "${raw_domain}")" || exit 2
    require_etc_access write

    file="${SITES_DIR}/${domain}.caddy"
    if [[ ! -f "${file}" && -f "${MONITOR_SITE_FILE}" ]] && grep -qxF -- "${domain}" <<<"$(site_file_hosts "${MONITOR_SITE_FILE}")"; then
        die "${domain} serves the status page. To remove it: vps-stack monitor disable"
    fi
    [[ -f "${file}" ]] || die "File ${file} does not exist. To list sites: vps-stack list-sites"

    removed_dir="${SITES_DIR}/.removed"
    target="${removed_dir}/${domain}.caddy.$(date +%Y%m%d-%H%M%S)"

    log_info "Hosts served by this file:"
    site_file_hosts "${file}" | sed 's/^/  /'
    confirm "Remove site ${domain} from the proxy?" || die "Aborted."

    run install -d -m 700 "${removed_dir}"
    run mv "${file}" "${target}"

    if is_dry_run; then
        log_dry "validate and reload the proxy"
        exit 0
    fi

    if caddy_running; then
        if ! "${SCRIPT_DIR}/proxy.sh" validate live; then
            mv "${target}" "${file}"
            die "Validation failed. ${file} was restored, nothing was changed."
        fi
        "${SCRIPT_DIR}/proxy.sh" reload
    else
        log_warn "Container ${CADDY_CONTAINER} is not running. The change takes effect after: vps-stack proxy up"
    fi

    log_ok "Removed ${domain}. Copy of the file: ${target}"
    log_info "DNS records and issued certificates stay. Remove the DNS records at your domain provider if they are no longer needed."
}

main "$@"
