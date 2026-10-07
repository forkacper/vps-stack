#!/usr/bin/env bash
# Shared setup for the bats suites. Loads only the pure-logic libraries.

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SITE_TEMPLATE="${REPO_ROOT}/templates/site-standard.caddy.tmpl"
export NO_COLOR=1

# lib/common.sh defines its own run() (the dry-run wrapper), which would
# shadow the bats `run` helper. Keep the bats one for the tests.
bats_run_definition="$(declare -f run)"
# shellcheck source=lib/common.sh
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source /dev/stdin <<<"${bats_run_definition}"
# shellcheck source=lib/validate.sh
source "${REPO_ROOT}/lib/validate.sh"
# shellcheck source=lib/monitor.sh
source "${REPO_ROOT}/lib/monitor.sh"
# shellcheck source=lib/backup.sh
source "${REPO_ROOT}/lib/backup.sh"

# render <domain> <upstream> [aliases] [redirects] [max_body]
render() {
    site_render "${SITE_TEMPLATE}" "$@"
}

# A string of N copies of a character.
repeat_char() {
    local char="$1" count="$2" out=""
    while [[ "${count}" -gt 0 ]]; do
        out="${out}${char}"
        count=$((count - 1))
    done
    printf '%s' "${out}"
}
