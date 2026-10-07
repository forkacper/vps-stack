#!/usr/bin/env bash
# Print the CHANGELOG.md section of one version, without its heading: the
# notes of the GitHub release. Fails when the section is missing or empty.
# Used by the CI and release workflows; see docs/releasing.md.
set -euo pipefail

version="${1:-}"
changelog="${2:-CHANGELOG.md}"

if [[ ! "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    printf 'Not a version (MAJOR.MINOR.PATCH): %s\n' "${version}" >&2
    exit 2
fi

# The section starts at "## [<version>]" and ends at the next "## [" heading
# or at the link references at the bottom of the file.
notes="$(awk -v heading="## [${version}]" '
    index($0, "## [") == 1 {
        if (found) exit
        if (index($0, heading) == 1) { found = 1; next }
    }
    /^\[[^]]+\]: / { if (found) exit }
    found
' "${changelog}")"

# Trim the blank lines around the section.
notes="$(printf '%s\n' "${notes}" | sed -e '/./,$!d')"
while [[ "${notes}" == *$'\n' ]]; do
    notes="${notes%$'\n'}"
done

if [[ -z "${notes}" ]]; then
    printf 'No notes for %s in %s (expected a "## [%s]" section).\n' "${version}" "${changelog}" "${version}" >&2
    exit 1
fi
printf '%s\n' "${notes}"
