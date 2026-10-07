#!/usr/bin/env bash
# shellcheck disable=SC2034
# (SC2034: this file defines variables that only the sourcing scripts read.)
#
# Shared helpers for all vps-stack scripts. Sourced, never executed.
#
# Everything that changes the system goes through run(), write_file() or
# append_line(), so --dry-run is implemented in exactly one place.

if [[ -n "${VPS_STACK_COMMON_LOADED:-}" ]]; then
    return 0
fi
VPS_STACK_COMMON_LOADED=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Paths are overridable so tests and CI can point them at a scratch directory.
ETC_DIR="${VPS_STACK_ETC_DIR:-/etc/vps-stack}"
SITES_DIR="${VPS_STACK_SITES_DIR:-${ETC_DIR}/sites}"
HOOKS_DIR="${VPS_STACK_HOOKS_DIR:-${ETC_DIR}/hooks}"
CADDY_DATA_DIR="${VPS_STACK_CADDY_DATA_DIR:-/srv/data/caddy}"
STAGING_DIR="${VPS_STACK_STAGING_DIR:-/srv/backup-staging}"
STACK_ENV_FILE="${ETC_DIR}/stack.env"
PROXY_ENV_FILE="${ETC_DIR}/proxy.env"
# Backup groups (lib/backup.sh): configuration, and the local repositories.
BACKUP_CONF_DIR="${VPS_STACK_BACKUP_CONF_DIR:-${ETC_DIR}/backup}"
BACKUP_REPO_ROOT="${VPS_STACK_BACKUP_ROOT:-/srv/backups}"
# The single repository of vps-stack 0.2 and older. Only detected, so that
# `backup` can point at the migration instead of ignoring it.
LEGACY_RESTIC_ENV_FILE="${ETC_DIR}/restic.env"
PROVISION_LOG_FILE="${VPS_STACK_PROVISION_LOG:-/var/log/vps-stack-provision.log}"
BACKUP_LOG_FILE="${VPS_STACK_BACKUP_LOG:-/var/log/vps-stack-backup.log}"
CADDY_CONTAINER="caddy"
PROXY_PROJECT_NAME="vps-stack-proxy"

# Status page (vps-stack monitor). Present only while it is enabled.
MONITOR_ENV_FILE="${ETC_DIR}/monitor.env"
MONITOR_BAN_LIST="${ETC_DIR}/monitor-banned.list"
MONITOR_SITE_FILE="${SITES_DIR}/_monitor.caddy"
# Imported by the status page site file; deliberately not *.caddy, so the
# `import sites/*.caddy` of the Caddyfile does not load it on its own.
MONITOR_BAN_SNIPPET="${SITES_DIR}/.monitor-banned"
MONITOR_RUN_DIR="${VPS_STACK_MONITOR_RUN_DIR:-/run/vps-stack-monitor}"
MONITOR_LOG_DIR="${VPS_STACK_MONITOR_LOG_DIR:-/var/log/vps-stack-monitor}"
# History of the status page: survives reboots, unlike the runtime directory.
MONITOR_STATE_DIR="${VPS_STACK_MONITOR_STATE_DIR:-/var/lib/vps-stack-monitor}"

DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

# --- output -----------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_BOLD=""
    C_RESET=""
fi

log_info() { printf '%s\n' "$*"; }
log_ok() { printf '%sOK%s    %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
log_warn() { printf '%sWARN%s  %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
log_error() { printf '%sERROR%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
log_step() { printf '\n%s%s[%s]%s %s%s\n' "${C_BOLD}" "${C_BLUE}" "$1" "${C_RESET}${C_BOLD}" "$2" "${C_RESET}"; }
log_dry() { printf '%s[dry-run]%s %s\n' "${C_BLUE}" "${C_RESET}" "$*" >&2; }

die() {
    log_error "$*"
    exit 1
}

# --- environment checks -----------------------------------------------------

is_dry_run() { [[ "${DRY_RUN}" == "1" ]]; }

has_tty() { [[ -t 0 ]]; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
    local cmd
    for cmd in "$@"; do
        have_cmd "${cmd}" || die "Command '${cmd}' not found. A server prepared by 'vps-stack provision' has it; otherwise install the package."
    done
}

require_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi
    if is_dry_run; then
        log_warn "--dry-run without root privileges: some reads may fail."
        return 0
    fi
    die "This command needs root privileges. Run it with sudo."
}

# require_etc_access [write]: the local configuration is root-only (700), so
# this is what actually decides whether a command can work.
require_etc_access() {
    if [[ ! -d "${ETC_DIR}" ]]; then
        die "Directory ${ETC_DIR} does not exist. Run 'vps-stack provision' first."
    fi
    if [[ ! -r "${ETC_DIR}" || ! -x "${ETC_DIR}" ]]; then
        die "No access to ${ETC_DIR}. Run this command with sudo."
    fi
    if [[ "${1:-}" == "write" && ! -w "${ETC_DIR}" ]] && ! is_dry_run; then
        die "No write access to ${ETC_DIR}. Run this command with sudo."
    fi
}

# --- dry-run aware primitives -----------------------------------------------

# run <command...>: execute the command, or only print it in dry-run mode.
# The dry-run line goes to stderr so `run cmd >/dev/null` still shows it.
run() {
    if is_dry_run; then
        local quoted
        quoted="$(printf ' %q' "$@")"
        log_dry "${quoted# }"
        return 0
    fi
    "$@"
}

# backup_file <path>: copy an existing file to <path>.bak.<timestamp>.
# The created path is left in BACKUP_FILE_PATH.
backup_file() {
    local path="$1"
    BACKUP_FILE_PATH=""
    [[ -e "${path}" ]] || return 0
    BACKUP_FILE_PATH="${path}.bak.$(date +%Y%m%d-%H%M%S)"
    if is_dry_run; then
        log_dry "backup ${path} -> ${BACKUP_FILE_PATH}"
        return 0
    fi
    cp -p "${path}" "${BACKUP_FILE_PATH}"
}

# write_file [--no-backup] <path> <mode> [owner:group]
# Content comes from stdin. Call it as
#     content="$(producer)"; write_file <path> <mode> <<<"${content}"
# and never as `producer | write_file ...`: in a pipeline it would run in a
# subshell, losing the result variables, and a failed producer would go
# unnoticed. Nothing happens when the target already has the
# same content. Otherwise the old file is backed up first.
# Results: WRITE_FILE_CHANGED (0/1), WRITE_FILE_BACKUP (path or empty),
# WRITE_FILE_CREATED (1 when the file did not exist before).
#
# --no-backup is for directories whose readers load every file regardless of
# its extension (logrotate.d), where a *.bak.* copy would be parsed as config.
write_file() {
    local do_backup=1
    if [[ "${1:-}" == "--no-backup" ]]; then
        do_backup=0
        shift
    fi
    local path="$1" mode="$2" owner="${3:-}" tmp
    WRITE_FILE_CHANGED=0
    WRITE_FILE_BACKUP=""
    WRITE_FILE_CREATED=0

    tmp="$(mktemp)"
    cat >"${tmp}"
    if [[ ! -s "${tmp}" ]]; then
        rm -f "${tmp}"
        die "Refusing to write empty content to ${path} (internal error)."
    fi

    if [[ -f "${path}" ]] && cmp -s "${tmp}" "${path}"; then
        rm -f "${tmp}"
        log_info "unchanged: ${path}"
        return 0
    fi

    WRITE_FILE_CHANGED=1
    if is_dry_run; then
        log_dry "write file ${path} (mode ${mode}${owner:+, owner ${owner}}):"
        sed 's/^/    | /' "${tmp}" >&2
        rm -f "${tmp}"
        return 0
    fi

    if [[ -e "${path}" ]]; then
        if [[ "${do_backup}" == "1" ]]; then
            backup_file "${path}"
            WRITE_FILE_BACKUP="${BACKUP_FILE_PATH}"
        fi
    else
        WRITE_FILE_CREATED=1
    fi

    if [[ -n "${owner}" ]]; then
        install -m "${mode}" -o "${owner%%:*}" -g "${owner##*:}" "${tmp}" "${path}"
    else
        install -m "${mode}" "${tmp}" "${path}"
    fi
    rm -f "${tmp}"
    log_info "written: ${path}"
}

# restore_last_write <path>: undo the most recent write_file call for <path>.
restore_last_write() {
    local path="$1"
    if is_dry_run; then
        return 0
    fi
    if [[ -n "${WRITE_FILE_BACKUP:-}" && -e "${WRITE_FILE_BACKUP}" ]]; then
        cp -p "${WRITE_FILE_BACKUP}" "${path}"
        log_warn "Restored the previous version: ${path}"
    elif [[ "${WRITE_FILE_CREATED:-0}" == "1" ]]; then
        rm -f "${path}"
        log_warn "Removed the newly created file: ${path}"
    fi
}

# append_line <path> <line>: append the line unless an identical one exists.
append_line() {
    local path="$1" line="$2"
    if [[ -f "${path}" ]] && grep -qxF -- "${line}" "${path}"; then
        return 0
    fi
    if is_dry_run; then
        log_dry "append to ${path}: ${line}"
        return 0
    fi
    backup_file "${path}"
    printf '%s\n' "${line}" >>"${path}"
}

# --- questions --------------------------------------------------------------

_ask_yes_no() {
    local question="$1" answer=""
    if ! has_tty; then
        log_warn "No terminal, cannot ask: ${question}"
        return 1
    fi
    read -r -p "${question} [y/N] " answer || return 1
    case "${answer}" in
        y | Y | yes | YES | Yes) return 0 ;;
        *) return 1 ;;
    esac
}

# confirm <question>: ordinary question, skipped by --yes.
confirm() {
    if is_dry_run; then
        log_dry "question: $1"
        return 0
    fi
    if [[ "${ASSUME_YES}" == "1" ]]; then
        log_info "$1 [y/N] y (--yes)"
        return 0
    fi
    _ask_yes_no "$1"
}

# confirm_risky <question>: for steps that can cut off access. NOT skipped
# by --yes.
confirm_risky() {
    if is_dry_run; then
        log_dry "question (not skipped by --yes): $1"
        return 0
    fi
    _ask_yes_no "$1"
}

# confirm_phrase <phrase> <message>: the user has to type the exact phrase.
# Never skipped by --yes; callers decide which dedicated flag may skip it.
confirm_phrase() {
    local phrase="$1" message="$2" answer=""
    if is_dry_run; then
        log_dry "confirmation required by typing ${phrase}: ${message}"
        return 0
    fi
    if ! has_tty; then
        log_warn "No terminal, cannot ask you to type ${phrase}."
        return 1
    fi
    printf '\n%s%s%s\n' "${C_BOLD}" "${message}" "${C_RESET}"
    read -r -p "Type ${phrase} to continue: " answer || return 1
    [[ "${answer}" == "${phrase}" ]]
}

# --- env files and templates ------------------------------------------------

# load_env_file <file> [export]
# Parses KEY=VALUE lines without sourcing the file, so its content is never
# executed. Supports comments on their own line, blank lines and values
# wrapped in single or double quotes. Inline comments are not supported.
load_env_file() {
    local file="$1" do_export="${2:-}" line key value
    local re_skip='^[[:space:]]*(#.*)?$'
    local re_pair='^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
    local re_dq='^"(.*)"$'
    local re_sq="^'(.*)'\$"
    [[ -r "${file}" ]] || die "Cannot read the configuration file: ${file}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        if [[ "${line}" =~ ${re_skip} ]]; then
            continue
        fi
        if [[ ! "${line}" =~ ${re_pair} ]]; then
            die "Invalid line in ${file} (expected KEY=value): ${line}"
        fi
        key="${BASH_REMATCH[2]}"
        value="${BASH_REMATCH[3]}"
        # Trim trailing whitespace of unquoted values.
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "${value}" =~ ${re_dq} || "${value}" =~ ${re_sq} ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        case "${key}" in
            PATH | IFS | HOME | SHELL | BASH* | LD_*)
                die "Key ${key} is not allowed in ${file}."
                ;;
        esac
        printf -v "${key}" '%s' "${value}"
        if [[ -n "${do_export}" ]]; then
            export "${key?}"
        fi
    done <"${file}"
}

# stack_config_defaults: defaults documented in config/stack.env.example.
stack_config_defaults() {
    ADMIN_USER="admin"
    DEPLOY_USER="deploy"
    DEPLOY_IN_DOCKER_GROUP="false"
    ADMIN_SSH_PUBKEY_FILE=""
    DEPLOY_SSH_PUBKEY_FILE=""
    SSH_PORT="22"
    FAIL2BAN_IGNOREIP=""
    SWAP_SIZE="2G"
    TIMEZONE="Etc/UTC"
    AUTO_REBOOT="false"
    PROXY_NETWORK="proxy"
}

# stack_config_load [file]: defaults, then the given file (default: the
# installed /etc/vps-stack/stack.env when it exists and is readable).
stack_config_load() {
    local file="${1:-${STACK_ENV_FILE}}"
    stack_config_defaults
    if [[ -r "${file}" ]]; then
        load_env_file "${file}"
    fi
}

# tpl_replace <text> <needle> <replacement>: literal replace-all, result in
# REPLY. Deliberately avoids ${var//pattern/replacement}: its handling of
# quotes and of '&' in the replacement differs between bash versions.
tpl_replace() {
    local rest="$1" needle="$2" replacement="$3" out="" head
    while [[ "${rest}" == *"${needle}"* ]]; do
        head=${rest%%"${needle}"*}
        out="${out}${head}${replacement}"
        rest=${rest#*"${needle}"}
    done
    REPLY="${out}${rest}"
}

# render_template <file> [KEY=VALUE ...]: print the template with every
# {{KEY}} replaced by VALUE. Pure text substitution: no eval, no shell
# expansion of the template or of the values.
render_template() {
    local file="$1" content pair
    shift
    [[ -r "${file}" ]] || die "Template not found: ${file}"
    content="$(cat "${file}")"
    for pair in "$@"; do
        tpl_replace "${content}" "{{${pair%%=*}}}" "${pair#*=}"
        content="${REPLY}"
    done
    # A placeholder replaced by an empty value at the end of the template
    # must not leave trailing blank lines behind.
    while [[ "${content}" == *$'\n' ]]; do
        content="${content%$'\n'}"
    done
    if [[ "${content}" == *"{{"*"}}"* ]]; then
        die "Template ${file} has unreplaced {{...}} placeholders."
    fi
    printf '%s\n' "${content}"
}

# --- status report (used by provision and verify) ---------------------------

REPORT_NAMES=()
REPORT_STATUSES=()
REPORT_NOTES=()
REPORT_ERRORS=0
REPORT_WARNINGS=0

# report_add <OK|WARN|ERROR> <name> [note]
report_add() {
    REPORT_STATUSES+=("$1")
    REPORT_NAMES+=("$2")
    REPORT_NOTES+=("${3:-}")
    case "$1" in
        "ERROR") REPORT_ERRORS=$((REPORT_ERRORS + 1)) ;;
        "WARN") REPORT_WARNINGS=$((REPORT_WARNINGS + 1)) ;;
        *) ;;
    esac
}

# _pad <text> <width>: pad by characters. printf's %-Ns pads by bytes, which
# misaligns columns containing non-ASCII letters. Characters are counted by
# dropping UTF-8 continuation bytes, so it works in the C locale too.
_pad() {
    local LC_ALL=C
    local text="$1" width="$2" visible fill=""
    visible="${text//[$'\x80'-$'\xbf']/}"
    while [[ $((${#visible} + ${#fill})) -lt "${width}" ]]; do
        fill="${fill} "
    done
    printf '%s%s' "${text}" "${fill}"
}

report_print() {
    local i color
    printf '\n%s%s %s %s%s\n' "${C_BOLD}" "$(_pad "STATUS" 6)" "$(_pad "ITEM" 34)" "NOTES" "${C_RESET}"
    for ((i = 0; i < ${#REPORT_NAMES[@]}; i++)); do
        case "${REPORT_STATUSES[i]}" in
            "OK") color="${C_GREEN}" ;;
            "WARN") color="${C_YELLOW}" ;;
            *) color="${C_RED}" ;;
        esac
        printf '%s%s%s %s %s\n' "${color}" "$(_pad "${REPORT_STATUSES[i]}" 6)" "${C_RESET}" \
            "$(_pad "${REPORT_NAMES[i]}" 34)" "${REPORT_NOTES[i]}"
    done
    printf '\nTotal: %s errors, %s warnings.\n' "${REPORT_ERRORS}" "${REPORT_WARNINGS}"
}

# --- small shared helpers ---------------------------------------------------

# file_has_mode <path> <octal mode>: portable replacement for `stat -c %a`.
file_has_mode() {
    [[ -n "$(find "$1" -maxdepth 0 -perm "$2" 2>/dev/null)" ]]
}

caddy_running() {
    have_cmd docker || return 1
    [[ "$(docker inspect -f '{{.State.Running}}' "${CADDY_CONTAINER}" 2>/dev/null)" == "true" ]]
}

# site_file_hosts <file>: print every host named in the site address lines
# of a generated *.caddy file, one per line.
site_file_hosts() {
    local line
    while IFS= read -r line; do
        case "${line}" in
            "" | "#"* | " "* | "}"*) continue ;;
            *"{")
                line="${line% \{}"
                printf '%s\n' "${line}" | tr -d ' ' | tr ',' '\n'
                ;;
            *) ;;
        esac
    done <"$1"
}

# site_refuse_duplicates <target file> <hosts...>: a host served by two site
# blocks makes the whole Caddy config invalid.
site_refuse_duplicates() {
    local target="$1" file host existing hint
    shift
    for file in "${SITES_DIR}"/*.caddy; do
        [[ -f "${file}" && "${file}" != "${target}" ]] || continue
        existing="$(site_file_hosts "${file}")"
        for host in "$@"; do
            if grep -qxF -- "${host}" <<<"${existing}"; then
                hint="vps-stack remove-site ${host}"
                if [[ "${file}" == "${MONITOR_SITE_FILE}" ]]; then
                    hint="vps-stack monitor disable"
                fi
                die "Domain ${host} is already configured in ${file}. Remove it first: ${hint}"
            fi
        done
    done
}

# dns_check_or_confirm <hosts...>: check that the hosts point at this server
# (scripts/check-dns.sh, with --server-ip taken from the SERVER_IPS array when
# the caller set it). A mismatch needs a confirmation; with --yes it is a
# refusal, so that only an explicit --no-dns-check skips the check.
dns_check_or_confirm() {
    local -a args=()
    local ip code=0
    for ip in "${SERVER_IPS[@]+"${SERVER_IPS[@]}"}"; do
        args+=(--server-ip "${ip}")
    done
    "${REPO_ROOT}/scripts/check-dns.sh" "${args[@]+"${args[@]}"}" "$@" || code=$?
    case "${code}" in
        0) return 0 ;;
        3) die "Could not determine the public address of the server. Pass it with --server-ip <address> or use --no-dns-check." ;;
        1) ;;
        *) die "The DNS check failed (exit code ${code})." ;;
    esac
    log_warn "DNS does not point at this server. Caddy will try to obtain a certificate right away, and failed"
    log_warn "attempts count against the Let's Encrypt rate limits. Fix the DNS records and wait for them to propagate."
    if is_dry_run; then
        return 0
    fi
    if [[ "${ASSUME_YES}" == "1" ]]; then
        die "Refusing: DNS does not match. Use --no-dns-check if you are sure you want to continue."
    fi
    confirm "Continue despite the DNS mismatch?" || die "Aborted. Nothing was changed."
}
