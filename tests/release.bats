#!/usr/bin/env bats

load helpers

NOTES="${REPO_ROOT}/.github/scripts/release-notes.sh"

write_changelog() {
    CHANGELOG="${BATS_TEST_TMPDIR}/CHANGELOG.md"
    cat >"${CHANGELOG}" <<'EOF'
# Changelog

## [Unreleased]

### Added

- Something new.

## [0.2.0] - 2026-10-07

### Added

- Feature two.

## [0.1.0] - 2026-10-01

First version.

[Unreleased]: https://example.com/compare/v0.2.0...HEAD
[0.2.0]: https://example.com/compare/v0.1.0...v0.2.0
[0.1.0]: https://example.com/releases/tag/v0.1.0
EOF
}

@test "release notes: the section of a version, without its heading" {
    write_changelog
    run "${NOTES}" 0.2.0 "${CHANGELOG}"
    [ "$status" -eq 0 ]
    [ "$output" = $'### Added\n\n- Feature two.' ]
}

@test "release notes: the last section stops before the link references" {
    write_changelog
    run "${NOTES}" 0.1.0 "${CHANGELOG}"
    [ "$status" -eq 0 ]
    [ "$output" = "First version." ]
}

@test "release notes: a missing version fails" {
    write_changelog
    run "${NOTES}" 0.3.0 "${CHANGELOG}"
    [ "$status" -eq 1 ]
}

@test "release notes: a prefix of another version does not match" {
    write_changelog
    run "${NOTES}" 0.2.0 "${CHANGELOG}"
    [[ "$output" != *"First version."* ]]
    printf '## [0.2.01] - 2026-10-08\n\n- Not this.\n' >>"${CHANGELOG}"
    run "${NOTES}" 0.2.0 "${CHANGELOG}"
    [[ "$output" != *"Not this."* ]]
}

@test "release notes: anything but MAJOR.MINOR.PATCH is refused" {
    write_changelog
    local value
    for value in "" "v0.2.0" "0.2" "0.2.0-alpha.1" "01.2.0" "0.2.0 " "Unreleased"; do
        run "${NOTES}" "${value}" "${CHANGELOG}"
        [ "$status" -eq 2 ]
    done
}

@test "repository: VERSION is MAJOR.MINOR.PATCH and has its changelog section" {
    local version
    version="$(cat "${REPO_ROOT}/VERSION")"
    run "${NOTES}" "${version}" "${REPO_ROOT}/CHANGELOG.md"
    [ "$status" -eq 0 ]
    grep -qx '## \[Unreleased\]' "${REPO_ROOT}/CHANGELOG.md"
}

@test "release notes: relative links are refused, absolute ones and anchors pass" {
    write_changelog
    printf '## [0.3.0] - 2026-10-08\n\n- See [the guide](docs/releasing.md).\n' >>"${CHANGELOG}"
    run "${NOTES}" 0.3.0 "${CHANGELOG}"
    [ "$status" -eq 1 ]
    [[ "$output" == *"](docs/releasing.md)"* ]]
    printf '## [0.4.0] - 2026-10-09\n\n- See [the guide](https://example.com/docs/releasing.md), [below](#notes) and [mail](mailto:admin@example.com).\n' >>"${CHANGELOG}"
    run "${NOTES}" 0.4.0 "${CHANGELOG}"
    [ "$status" -eq 0 ]
}
