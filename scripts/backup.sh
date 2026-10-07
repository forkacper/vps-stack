#!/usr/bin/env bash
# Backup with restic: one repository per project, plus "system" for the
# vps-stack configuration and the certificates. See docs/backup-restore.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=lib/backup.sh
source "${SCRIPT_DIR}/../lib/backup.sh"

LOCK_FILE="${VPS_STACK_BACKUP_LOCK:-/run/lock/vps-stack-backup.lock}"
CRON_FILE="/etc/cron.d/vps-stack-backup"
PROJECTS_ROOT="${VPS_STACK_PROJECTS_ROOT:-/srv}"
# Dumps kept in the staging directory of every hook, pruned right before the
# snapshot. The copies live in the repository; staging only feeds it.
STAGING_KEEP=1

usage() {
    cat <<USAGE
Usage: sudo vps-stack backup <command> [arguments] [--dry-run]

One restic repository per project, plus "system" (vps-stack configuration
and certificates). By default the repositories live in ${BACKUP_REPO_ROOT}.

Commands:
  init <group>          set up a group: "system", or a project name
                        (configuration, generated password, repository)
  run [<group>]         back up every group, or one
  list                  groups, location, last successful backup, snapshots
  snapshots <group>     the snapshots of a group
  restore <group> --target <directory> [--snapshot <id>] [--path <path>]
                        unpack a snapshot (default: latest) into a NEW or
                        empty directory; never over live data
  export <group> --output <file.tar|file.zip> [--snapshot <id>] [--path <path>]
                        an archive of a snapshot, e.g. to move a project
  setup                 install the cron job (every 6 hours, all groups)

Configuration: ${BACKUP_CONF_DIR}/<group>.env
Hooks of a project: ${HOOKS_DIR}/<project>/*.sh
Log: ${BACKUP_LOG_FILE}
USAGE
}

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

note() { printf '%s %s\n' "$(stamp)" "$*"; }

refuse_legacy() {
    if [[ -f "${LEGACY_RESTIC_ENV_FILE}" ]]; then
        die "Found ${LEGACY_RESTIC_ENV_FILE} from vps-stack 0.2 or older. Backups are per project now; see \"Moving from vps-stack 0.2\" in docs/backup-restore.md, then move that file away."
    fi
}

require_group() {
    validate_backup_group "$1" || exit 2
    [[ -f "$(backup_group_conf "$1")" ]] ||
        die "Backup group $1 is not set up. Set it up: sudo vps-stack backup init $1"
}

# load_group <group>: read the group configuration and export what restic
# needs. Called inside a subshell, so nothing leaks into the next group.
load_group() {
    local group="$1" conf name
    conf="$(backup_group_conf "${group}")"
    file_has_mode "${conf}" 600 || die "${conf} must have mode 600. Fix: chmod 600 ${conf}"
    RESTIC_REPOSITORY=""
    RESTIC_PASSWORD_FILE=""
    KEEP_DAILY=14
    KEEP_WEEKLY=8
    KEEP_MONTHLY=6
    HC_URL=""
    load_env_file "${conf}" export
    [[ -n "${RESTIC_REPOSITORY}" ]] || die "RESTIC_REPOSITORY in ${conf} is empty."
    [[ -s "${RESTIC_PASSWORD_FILE}" ]] || die "The password file of group ${group} is missing or empty: ${RESTIC_PASSWORD_FILE}"
    file_has_mode "${RESTIC_PASSWORD_FILE}" 600 || die "${RESTIC_PASSWORD_FILE} must have mode 600."
    for name in KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY; do
        [[ "${!name}" =~ ^[0-9]{1,4}$ ]] || die "${name} in ${conf} must be a number."
    done
    export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
}

# hc_ping <suffix>: healthchecks.io style ping; silent no-op without HC_URL.
hc_ping() {
    [[ -n "${HC_URL:-}" ]] || return 0
    if is_dry_run; then
        log_dry "ping ${HC_URL}$1"
        return 0
    fi
    curl -fsS -m 10 --retry 3 -o /dev/null "${HC_URL}$1" || note "WARN: monitoring ping failed"
}

# --- init -------------------------------------------------------------------

cmd_init() {
    local group="${1:-}" conf password content
    [[ -n "${group}" ]] || die "Give the group: sudo vps-stack backup init system|<project>"
    validate_backup_group "${group}" || exit 2
    require_root
    refuse_legacy
    require_cmd restic
    [[ -d "${ETC_DIR}" ]] || die "${ETC_DIR} does not exist. Run 'vps-stack provision' first."

    conf="$(backup_group_conf "${group}")"
    password="$(backup_group_password "${group}")"
    run install -d -m 700 -o root -g root "${BACKUP_CONF_DIR}" "${BACKUP_REPO_ROOT}"
    if [[ "${group}" != "${BACKUP_SYSTEM_GROUP}" ]]; then
        run install -d -m 700 -o root -g root "${HOOKS_DIR}" "$(backup_group_hooks "${group}")"
        if [[ ! -d "${PROJECTS_ROOT}/${group}" ]]; then
            log_warn "${PROJECTS_ROOT}/${group} does not exist. That is fine if the project lives elsewhere: its hooks name the paths to back up."
        fi
    fi

    if [[ -f "${password}" ]]; then
        log_info "unchanged: ${password}"
    elif is_dry_run; then
        log_dry "generate a random password into ${password} (mode 600)"
    else
        # 32 random bytes. Written with a restrictive umask, never shown.
        (umask 077 && head -c 32 /dev/urandom | base64 >"${password}")
        log_info "written: ${password}"
    fi

    if [[ -f "${conf}" ]]; then
        log_info "unchanged: ${conf}"
    else
        content="$(render_template "${REPO_ROOT}/templates/backup-group.env.tmpl" \
            "NAME=${group}" "REPOSITORY=$(backup_group_default_repo "${group}")" "PASSWORD_FILE=${password}")"
        write_file "${conf}" 600 <<<"${content}"
    fi

    if is_dry_run; then
        log_dry "restic init (unless the repository already exists)"
        return 0
    fi
    (
        load_group "${group}"
        if restic cat config >/dev/null 2>&1; then
            log_ok "Repository of ${group} already exists: ${RESTIC_REPOSITORY}"
        else
            # restic init refuses to touch an existing repository, so a wrong
            # password or a network error cannot overwrite anything.
            restic init >/dev/null || die "restic init failed for ${RESTIC_REPOSITORY}."
            log_ok "Repository of ${group} created: ${RESTIC_REPOSITORY}"
        fi
    )

    if [[ "${group}" == "${BACKUP_SYSTEM_GROUP}" ]]; then
        log_info "Group system backs up ${ETC_DIR} and the certificates in ${CADDY_DATA_DIR}/data."
    else
        cat <<NEXT
Next steps for ${group}:
  1. Hooks: database dump and paths of user files, in $(backup_group_hooks "${group}")/
     (examples: ${REPO_ROOT}/examples/backup-hook-*.sh.example)
  2. The first backup by hand: sudo vps-stack backup run ${group}
  3. The schedule, once for all groups: sudo vps-stack backup setup
NEXT
    fi
}

# --- run --------------------------------------------------------------------

# run_hooks <group> <staging dir> <extra paths file>: a failing hook stops
# neither the other hooks nor the backup, but the run is reported as failed.
run_hooks() {
    local group="$1" staging="$2" extra="$3" hook name
    for hook in "$(backup_group_hooks "${group}")"/*.sh; do
        [[ -f "${hook}" && -x "${hook}" ]] || continue
        name="$(basename "${hook}" .sh)"
        note "backup ${group}: hook ${name}: start"
        run install -d -m 700 "${staging}/${name}"
        if STAGING_DIR="${staging}" HOOK_NAME="${name}" HOOK_EXTRA_PATHS_FILE="${extra}" BACKUP_GROUP="${group}" \
            PROJECT_DIR="${PROJECTS_ROOT}/${group}" run "${hook}"; then
            note "backup ${group}: hook ${name}: OK"
        else
            note "backup ${group}: hook ${name}: ERROR"
            FAILURES+=("hook ${name}")
        fi
    done
}

# run_group <group>: back up one group. Runs in a subshell started in a
# `||` list, where `set -e` does not apply: every step is checked here.
run_group() {
    local group="$1" staging extra path code=0 file
    local -a paths=() restic_args=()
    FAILURES=()

    load_group "${group}"
    note "backup ${group}: start (${RESTIC_REPOSITORY})"
    hc_ping "/start"

    restic_args=(backup --tag vps-stack --tag "${group}")
    if [[ "${group}" == "${BACKUP_SYSTEM_GROUP}" ]]; then
        # Repository credentials never go into a repository, so neither the
        # group configurations nor the passwords are part of "system".
        restic_args+=(--exclude "${BACKUP_CONF_DIR}" --exclude "${ETC_DIR}/restic*")
        for path in "${ETC_DIR}" "${CADDY_DATA_DIR}/data"; do
            [[ -e "${path}" ]] && paths+=("${path}")
        done
    else
        staging="$(backup_group_staging "${group}")"
        extra="$(mktemp)" || return 1
        # shellcheck disable=SC2064  # the path is fixed now, on purpose
        trap "rm -f '${extra}'" EXIT
        run install -d -m 700 "${STAGING_DIR}" "${staging}"
        run_hooks "${group}" "${staging}" "${extra}"
        # Before the snapshot, so that it holds exactly the newest dump of
        # every hook. When a hook failed, its previous dump stays.
        while IFS= read -r file; do
            run rm -f "${file}"
        done < <(backup_prune_staging "${staging}" "${STAGING_KEEP}")
        [[ -d "${staging}" ]] && paths+=("${staging}")
        [[ -f "${PROJECTS_ROOT}/${group}/.env" ]] && paths+=("${PROJECTS_ROOT}/${group}/.env")
        while IFS= read -r path || [[ -n "${path}" ]]; do
            [[ -n "${path}" ]] || continue
            if [[ "${path}" == /* && -e "${path}" ]]; then
                paths+=("${path}")
            else
                note "backup ${group}: WARN: path from a hook does not exist or is not absolute: ${path}"
                FAILURES+=("path ${path}")
            fi
        done <"${extra}"
    fi

    if [[ "${#paths[@]}" -eq 0 ]]; then
        note "backup ${group}: ERROR: nothing to back up"
        FAILURES+=("no paths")
    else
        run restic "${restic_args[@]}" "${paths[@]}" || code=$?
        case "${code}" in
            0) note "backup ${group}: restic backup OK" ;;
            3)
                note "backup ${group}: restic backup: some files could not be read"
                FAILURES+=("restic backup (incomplete)")
                ;;
            *)
                note "backup ${group}: restic backup: ERROR (exit code ${code})"
                FAILURES+=("restic backup")
                ;;
        esac
    fi

    if [[ "${code}" == "0" || "${code}" == "3" ]] && [[ "${#paths[@]}" -gt 0 ]]; then
        run restic forget --tag vps-stack --group-by host \
            --keep-daily "${KEEP_DAILY}" --keep-weekly "${KEEP_WEEKLY}" --keep-monthly "${KEEP_MONTHLY}" >/dev/null ||
            FAILURES+=("restic forget")
        # Weekly maintenance: the first run on Sunday (UTC).
        if [[ "$(date -u +%u)" == "7" && "$((10#$(date -u +%H)))" -lt 6 ]]; then
            run restic prune >/dev/null || FAILURES+=("restic prune")
            run restic check --read-data-subset=5% >/dev/null || FAILURES+=("restic check")
        fi
    fi

    if [[ "${#FAILURES[@]}" -gt 0 ]]; then
        note "backup ${group}: ERROR (${FAILURES[*]})"
        hc_ping "/fail"
        return 1
    fi
    if is_dry_run; then
        note "backup ${group}: dry-run finished"
    else
        # verify and `backup list` look for this exact line.
        note "BACKUP_OK ${group}"
    fi
    hc_ping ""
}

cmd_run() {
    local group failed=0
    local -a groups=()
    require_root
    refuse_legacy
    require_cmd restic flock
    if [[ -n "${1:-}" ]]; then
        require_group "$1"
        groups=("$1")
    else
        mapfile -t groups < <(backup_groups)
        [[ "${#groups[@]}" -gt 0 ]] ||
            die "No backup groups are set up. Start with: sudo vps-stack backup init system, then backup init <project>."
    fi

    if ! is_dry_run; then
        exec 9>"${LOCK_FILE}"
        flock -n 9 || die "Another backup is in progress (${LOCK_FILE})."
        touch "${BACKUP_LOG_FILE}"
        chmod 600 "${BACKUP_LOG_FILE}"
        exec > >(tee -a "${BACKUP_LOG_FILE}") 2>&1
    fi

    for group in "${groups[@]}"; do
        (run_group "${group}") || failed=1
    done
    if [[ "${failed}" == "1" ]]; then
        note "backup: finished WITH ERRORS (see above)"
        exit 1
    fi
}

# --- list, snapshots --------------------------------------------------------

cmd_list() {
    local group
    local -a groups=()
    require_root
    refuse_legacy
    require_cmd restic jq
    mapfile -t groups < <(backup_groups)
    if [[ "${#groups[@]}" -eq 0 ]]; then
        log_info "No backup groups are set up. Start with: sudo vps-stack backup init system"
        return 0
    fi
    printf '%s%-20s %-10s %-22s %-10s %-10s %s%s\n' "${C_BOLD}" "GROUP" "LOCATION" "LAST SUCCESS (UTC)" "SNAPSHOTS" "SIZE" "REPOSITORY" "${C_RESET}"
    for group in "${groups[@]}"; do
        (
            local last location count size
            load_group "${group}"
            last="$(backup_last_ok "${group}" "${BACKUP_LOG_FILE}.1" "${BACKUP_LOG_FILE}")"
            if backup_repo_is_local "${RESTIC_REPOSITORY}"; then
                location="local"
                size="$(du -sh "${RESTIC_REPOSITORY#local:}" 2>/dev/null | awk '{ print $1 }')"
            else
                location="remote"
                size="-"
            fi
            count="$(restic snapshots --json 2>/dev/null | jq 'length' 2>/dev/null || true)"
            printf '%-20s %-10s %-22s %-10s %-10s %s\n' "${group}" "${location}" "${last:-never}" \
                "${count:-error}" "${size:--}" "${RESTIC_REPOSITORY}"
        )
    done
}

cmd_snapshots() {
    local group="${1:-}"
    [[ -n "${group}" ]] || die "Give the group: sudo vps-stack backup snapshots <group>"
    require_root
    require_group "${group}"
    require_cmd restic
    (
        load_group "${group}"
        restic snapshots
    )
}

# --- restore, export --------------------------------------------------------

# parse_snapshot_args: --snapshot, --path and one extra option (--target or
# --output) into SNAPSHOT, SNAPSHOT_PATH and EXTRA_VALUE.
parse_snapshot_args() {
    local extra_option="$1"
    shift
    SNAPSHOT="latest"
    SNAPSHOT_PATH=""
    EXTRA_VALUE=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --snapshot | --path | "${extra_option}")
                [[ $# -ge 2 ]] || die "Option $1 needs a value."
                case "$1" in
                    --snapshot) SNAPSHOT="$2" ;;
                    --path) SNAPSHOT_PATH="$2" ;;
                    *) EXTRA_VALUE="$2" ;;
                esac
                shift
                ;;
            *) die "Unknown argument: $1" ;;
        esac
        shift
    done
    [[ "${SNAPSHOT}" =~ ^(latest|[0-9a-f]{8,64})$ ]] ||
        die "--snapshot: give 'latest' or a snapshot ID from: vps-stack backup snapshots <group>"
    if [[ -n "${SNAPSHOT_PATH}" ]] && [[ "${SNAPSHOT_PATH}" != /* || "${SNAPSHOT_PATH}" == *$'\n'* ]]; then
        die "--path must be an absolute path inside the snapshot, e.g. /srv/example-app/storage/uploads"
    fi
    [[ -n "${EXTRA_VALUE}" ]] || die "Option ${extra_option} is required."
}

cmd_restore() {
    local group="${1:-}"
    [[ -n "${group}" ]] || die "Give the group: sudo vps-stack backup restore <group> --target <directory>"
    shift
    parse_snapshot_args --target "$@"
    backup_target_ok "${EXTRA_VALUE}" || exit 2
    require_root
    require_group "${group}"
    require_cmd restic
    (
        local -a args=(restore "${SNAPSHOT}" --target "${EXTRA_VALUE}")
        load_group "${group}"
        [[ -n "${SNAPSHOT_PATH}" ]] && args+=(--include "${SNAPSHOT_PATH}")
        run install -d -m 700 "${EXTRA_VALUE}"
        run restic "${args[@]}" || die "restic restore failed."
        is_dry_run && return 0
        log_ok "Restored ${group} (${SNAPSHOT}${SNAPSHOT_PATH:+, ${SNAPSHOT_PATH}}) into ${EXTRA_VALUE}."
        log_info "The files keep their full paths below that directory, e.g. ${EXTRA_VALUE}$(backup_group_staging "${group}")/."
        log_info "Nothing live was changed. Importing a dump or copying files back: docs/backup-restore.md."
    )
}

cmd_export() {
    local group="${1:-}" format
    [[ -n "${group}" ]] || die "Give the group: sudo vps-stack backup export <group> --output <file.tar|file.zip>"
    shift
    parse_snapshot_args --output "$@"
    format="$(backup_export_format "${EXTRA_VALUE}")" || exit 2
    [[ ! -e "${EXTRA_VALUE}" ]] || die "${EXTRA_VALUE} already exists. Give a new file."
    [[ -d "$(dirname "${EXTRA_VALUE}")" ]] || die "Directory $(dirname "${EXTRA_VALUE}") does not exist."
    require_root
    require_group "${group}"
    require_cmd restic
    (
        load_group "${group}"
        if is_dry_run; then
            log_dry "restic dump --archive ${format} ${SNAPSHOT} ${SNAPSHOT_PATH:-/} > ${EXTRA_VALUE}"
            return 0
        fi
        # Written under a temporary name: an interrupted export never looks
        # complete. The archive holds the project's data: root only.
        umask 077
        if ! restic dump --archive "${format}" "${SNAPSHOT}" "${SNAPSHOT_PATH:-/}" >"${EXTRA_VALUE}.partial"; then
            rm -f "${EXTRA_VALUE}.partial"
            die "restic dump failed."
        fi
        mv "${EXTRA_VALUE}.partial" "${EXTRA_VALUE}"
        log_ok "Archive of ${group} (${SNAPSHOT}${SNAPSHOT_PATH:+, ${SNAPSHOT_PATH}}): ${EXTRA_VALUE} ($(du -h "${EXTRA_VALUE}" | awk '{ print $1 }'))"
        log_warn "The archive is not encrypted and holds the project's data and .env. Move it over an encrypted channel (scp) and delete it afterwards."
    )
}

# --- setup ------------------------------------------------------------------

cmd_setup() {
    local content
    require_root
    refuse_legacy
    [[ -n "$(backup_groups)" ]] ||
        die "No backup groups are set up yet. Start with: sudo vps-stack backup init system"
    content="$(render_template "${REPO_ROOT}/templates/cron-backup.tmpl" \
        "VPS_STACK_BIN=${REPO_ROOT}/bin/vps-stack")"
    write_file "${CRON_FILE}" 644 <<<"${content}"
    log_ok "Every group is backed up every 6 hours (${CRON_FILE})."
    log_info "Run the first backup by hand and check the result: sudo vps-stack backup run"
}

main() {
    local command=""
    local -a args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            -h | --help | help)
                usage
                exit 0
                ;;
            *)
                if [[ -z "${command}" ]]; then
                    command="$1"
                else
                    args+=("$1")
                fi
                ;;
        esac
        shift
    done
    case "${command}" in
        "")
            usage
            exit 0
            ;;
        init) cmd_init "${args[@]+"${args[@]}"}" ;;
        run) cmd_run "${args[@]+"${args[@]}"}" ;;
        list) cmd_list ;;
        snapshots) cmd_snapshots "${args[@]+"${args[@]}"}" ;;
        restore) cmd_restore "${args[@]+"${args[@]}"}" ;;
        export) cmd_export "${args[@]+"${args[@]}"}" ;;
        setup) cmd_setup ;;
        *)
            usage >&2
            die "Unknown command: ${command}"
            ;;
    esac
}

main "$@"
