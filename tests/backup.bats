#!/usr/bin/env bats

load helpers

setup() {
    BACKUP_CONF_DIR="${BATS_TEST_TMPDIR}/backup"
    BACKUP_REPO_ROOT="/srv/backups"
    HOOKS_DIR="/etc/vps-stack/hooks"
    STAGING_DIR="/srv/backup-staging"
    mkdir -p "${BACKUP_CONF_DIR}"
}

# --- group names and paths --------------------------------------------------

@test "backup group: project names and system are valid" {
    local value
    for value in "system" "example-app" "shop_2" "a" "$(repeat_char a 63)"; do
        run validate_backup_group "${value}"
        [ "$status" -eq 0 ]
    done
}

@test "backup group: invalid names are rejected" {
    local value
    for value in "" "-app" "_app" "App" "my app" "../etc" "a/b" "app.env" "$(repeat_char a 64)" \
        $'app\nother' 'app$(id)'; do
        run validate_backup_group "${value}"
        [ "$status" -ne 0 ]
    done
}

@test "backup group: paths" {
    [ "$(backup_group_conf example-app)" = "${BACKUP_CONF_DIR}/example-app.env" ]
    [ "$(backup_group_password example-app)" = "${BACKUP_CONF_DIR}/example-app.password" ]
    [ "$(backup_group_hooks example-app)" = "/etc/vps-stack/hooks/example-app" ]
    [ "$(backup_group_staging example-app)" = "/srv/backup-staging/example-app" ]
    [ "$(backup_group_default_repo example-app)" = "/srv/backups/example-app" ]
}

@test "backup groups: system first, then projects sorted; other files ignored" {
    touch "${BACKUP_CONF_DIR}/shop.env" "${BACKUP_CONF_DIR}/blog.env" "${BACKUP_CONF_DIR}/system.env" \
        "${BACKUP_CONF_DIR}/blog.password" "${BACKUP_CONF_DIR}/Bad Name.env" "${BACKUP_CONF_DIR}/notes.txt"
    run backup_groups
    [ "$status" -eq 0 ]
    [ "$output" = $'system\nblog\nshop' ]
}

@test "backup groups: none configured" {
    run backup_groups
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    BACKUP_CONF_DIR="${BATS_TEST_TMPDIR}/missing"
    run backup_groups
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "repository location: local paths and remote backends" {
    run backup_repo_is_local "/srv/backups/shop"
    [ "$status" -eq 0 ]
    run backup_repo_is_local "local:/srv/backups/shop"
    [ "$status" -eq 0 ]
    local value
    for value in "s3:https://s3.example.com/bucket/shop" "sftp:backup@backup.example.com:/srv/restic" \
        "rest:https://backup.example.com/shop" "b2:bucket:shop" "relative/path" ""; do
        run backup_repo_is_local "${value}"
        [ "$status" -ne 0 ]
    done
}

# --- last successful backup -------------------------------------------------

@test "last ok: the newest entry of the group, across rotated logs" {
    local old="${BATS_TEST_TMPDIR}/backup.log.1" new="${BATS_TEST_TMPDIR}/backup.log"
    printf '%s\n' "2026-10-06T00:15:01Z BACKUP_OK shop" "2026-10-06T06:15:01Z BACKUP_OK blog" >"${old}"
    printf '%s\n' "2026-10-07T00:15:01Z backup shop: start" "2026-10-07T00:15:09Z BACKUP_OK shop" \
        "2026-10-07T06:15:02Z BACKUP_OK shopping" >"${new}"
    run backup_last_ok shop "${old}" "${new}"
    [ "$output" = "2026-10-07T00:15:09Z" ]
    run backup_last_ok blog "${old}" "${new}"
    [ "$output" = "2026-10-06T06:15:01Z" ]
    run backup_last_ok system "${old}" "${new}"
    [ "$output" = "" ]
}

@test "last ok: a line from a hook cannot fake a success" {
    local log="${BATS_TEST_TMPDIR}/backup.log"
    printf '%s\n' "2026-10-07T00:15:03Z hook db: BACKUP_OK shop" "2026-10-07T00:15:04Z BACKUP_OK shop extra" >"${log}"
    run backup_last_ok shop "${log}" "${BATS_TEST_TMPDIR}/missing.log"
    [ "$output" = "" ]
}

@test "age state: ok, then a warning, then an error" {
    local now=1791446400
    run backup_age_state $((now - 3 * 3600)) "${now}"
    [ "$output" = "ok 3" ]
    run backup_age_state $((now - 13 * 3600)) "${now}"
    [ "$output" = "ok 13" ]
    run backup_age_state $((now - 14 * 3600)) "${now}"
    [ "$output" = "warn 14" ]
    run backup_age_state $((now - 48 * 3600)) "${now}"
    [ "$output" = "warn 48" ]
    run backup_age_state $((now - 49 * 3600)) "${now}"
    [ "$output" = "error 49" ]
}

@test "age state: never backed up or an unreadable time is a warning without an age" {
    run backup_age_state "" 1791446400
    [ "$output" = "warn " ]
    run backup_age_state "2026-10-08T00:00:00Z" 1791446400
    [ "$output" = "warn " ]
}

# --- restore target and export ----------------------------------------------

@test "restore target: a new or empty absolute directory" {
    run backup_target_ok "${BATS_TEST_TMPDIR}/new"
    [ "$status" -eq 0 ]
    mkdir "${BATS_TEST_TMPDIR}/empty"
    run backup_target_ok "${BATS_TEST_TMPDIR}/empty"
    [ "$status" -eq 0 ]
}

@test "restore target: never over existing data" {
    mkdir -p "${BATS_TEST_TMPDIR}/full"
    touch "${BATS_TEST_TMPDIR}/full/.hidden" "${BATS_TEST_TMPDIR}/file"
    local value
    for value in "/" "relative/dir" "" "${BATS_TEST_TMPDIR}/full" "${BATS_TEST_TMPDIR}/file"; do
        run backup_target_ok "${value}"
        [ "$status" -ne 0 ]
    done
}

@test "export format: from the extension of an absolute path" {
    run backup_export_format "/tmp/shop.tar"
    [ "$output" = "tar" ]
    run backup_export_format "/tmp/shop.zip"
    [ "$output" = "zip" ]
    local value
    for value in "shop.tar" "/tmp/shop.tar.gz" "/tmp/shop" ""; do
        run backup_export_format "${value}"
        [ "$status" -ne 0 ]
    done
}

# --- staging ----------------------------------------------------------------

@test "staging: keep the newest dump of every hook" {
    local dir="${BATS_TEST_TMPDIR}/staging"
    mkdir -p "${dir}/db" "${dir}/other"
    touch -t 202610070000 "${dir}/db/shop-1.sql"
    touch -t 202610070600 "${dir}/db/shop-2.sql"
    touch -t 202610071200 "${dir}/db/shop-3.sql"
    touch -t 202610070000 "${dir}/other/only.sql"
    run backup_prune_staging "${dir}" 1
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "${lines[@]}" | sort)" = "$(printf '%s\n' "${dir}/db/shop-1.sql" "${dir}/db/shop-2.sql")" ]
}

@test "staging: nothing to prune" {
    run backup_prune_staging "${BATS_TEST_TMPDIR}/missing" 1
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}
