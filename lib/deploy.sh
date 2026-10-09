#!/usr/bin/env bash
# Deploys: validation of everything a deploy is told, the project's .env
# line with the image tag, the SSH key that can only start one deploy and
# the bookkeeping. Pure logic: no root, no Docker, no sshd. Covered by
# tests/deploy.bats.
#
# A project <name> has:
#   ${DEPLOY_CONF_DIR}/<name>.env       mode, tag variable, migrations (600)
#   ${DEPLOY_STATE_ROOT}/<name>/        previous version, history, lock
#   ${DEPLOY_LOG_ROOT}/<name>/          one log per deploy
#   ${SUDOERS_DIR}/vps-stack-deploy-<name> and one line in authorized_keys
#   of the deployment account, marked "vps-stack-deploy:<name>" (deploy key)
#
# Requires lib/common.sh and lib/validate.sh (has_unsafe_chars).

if [[ -n "${VPS_STACK_DEPLOY_LOADED:-}" ]]; then
    return 0
fi
VPS_STACK_DEPLOY_LOADED=1

# Logs kept per project; older ones are removed after every deploy.
# shellcheck disable=SC2034  # read by scripts/deploy.sh
DEPLOY_LOG_KEEP=30

# --- names and values -------------------------------------------------------

# validate_project_name <name>: the name of a project directory in /srv.
validate_project_name() {
    local LC_ALL=C
    local re='^[a-z0-9][a-z0-9_-]{0,62}$'
    if [[ ! "${1:-}" =~ ${re} ]]; then
        printf 'Invalid value: the project must be the name of its directory (a-z, 0-9, _ and -, up to 63 characters).\n' >&2
        return 1
    fi
}

# validate_deploy_version <value>: what a deploy may be told to release: an
# image tag or a commit SHA. The grammar of a Docker tag, which also covers
# commit SHAs and version numbers, cannot start an option and has nothing a
# shell could interpret.
validate_deploy_version() {
    local LC_ALL=C
    local re='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
    if [[ ! "${1:-}" =~ ${re} ]]; then
        printf 'Invalid value: the version must be an image tag or a commit SHA (letters, digits, _ . and -, up to 128 characters).\n' >&2
        return 1
    fi
}

validate_deploy_mode() {
    case "${1:-}" in
        image | build) return 0 ;;
        *)
            printf 'Invalid value: the mode must be "image" or "build".\n' >&2
            return 1
            ;;
    esac
}

# validate_deploy_tag_var <name>: an environment variable name.
validate_deploy_tag_var() {
    local LC_ALL=C
    local re='^[A-Z_][A-Z0-9_]{0,63}$'
    if [[ ! "${1:-}" =~ ${re} ]]; then
        printf 'Invalid value: the tag variable must be an environment variable name in capitals, e.g. APP_TAG.\n' >&2
        return 1
    fi
}

# validate_deploy_compose_file <path>: empty, or a path below the project
# directory.
validate_deploy_compose_file() {
    local path="${1:-}"
    [[ -z "${path}" ]] && return 0
    if has_unsafe_chars "${path}" || [[ "${path}" == /* || "${path}" == -* || "/${path}/" == */../* || "${path}" == *:* ]]; then
        printf 'Invalid value: the compose file must be a path relative to the project directory, e.g. docker-compose.prod.yml.\n' >&2
        return 1
    fi
}

# validate_deploy_migrate <service> <command>: both empty, or a compose
# service name and a command of plain words.
validate_deploy_migrate() {
    local LC_ALL=C
    local service="${1:-}" command="${2:-}"
    local re_service='^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$'
    local re_command='^[A-Za-z0-9_./:=@,+-]+( [A-Za-z0-9_./:=@,+-]+)*$'
    if [[ -z "${service}" && -z "${command}" ]]; then
        return 0
    fi
    if [[ ! "${service}" =~ ${re_service} ]]; then
        printf 'Invalid value: the migration service must be the name of a service in the compose file.\n' >&2
        return 1
    fi
    if [[ ! "${command}" =~ ${re_command} || "${command}" == -* ]]; then
        printf 'Invalid value: the migration command must be plain words separated by single spaces (no quotes, pipes or variables), e.g. php artisan migrate --force.\n' >&2
        return 1
    fi
}

validate_deploy_bool() {
    case "${1:-}" in
        true | false) return 0 ;;
        *)
            printf 'Invalid value: expected true or false.\n' >&2
            return 1
            ;;
    esac
}

# validate_deploy_timeout <seconds>: 1 to 3600.
validate_deploy_timeout() {
    local re='^[1-9][0-9]{0,3}$'
    if [[ ! "${1:-}" =~ ${re} || "$1" -gt 3600 ]]; then
        printf 'Invalid value: the health timeout must be a number of seconds from 1 to 3600.\n' >&2
        return 1
    fi
}

# --- paths ------------------------------------------------------------------

deploy_project_dir() { printf '%s/%s\n' "${PROJECTS_ROOT}" "$1"; }
deploy_conf_file() { printf '%s/%s.env\n' "${DEPLOY_CONF_DIR}" "$1"; }
deploy_state_dir() { printf '%s/%s\n' "${DEPLOY_STATE_ROOT}" "$1"; }
deploy_previous_file() { printf '%s/%s/previous\n' "${DEPLOY_STATE_ROOT}" "$1"; }
deploy_history_file() { printf '%s/%s/history.log\n' "${DEPLOY_STATE_ROOT}" "$1"; }
deploy_log_dir() { printf '%s/%s\n' "${DEPLOY_LOG_ROOT}" "$1"; }
deploy_sudoers_file() { printf '%s/vps-stack-deploy-%s\n' "${SUDOERS_DIR}" "$1"; }
deploy_key_comment() { printf 'vps-stack-deploy:%s\n' "$1"; }

# deploy_projects: print the projects that have a deploy configuration, in
# alphabetical order.
deploy_projects() {
    local file name
    [[ -d "${DEPLOY_CONF_DIR}" ]] || return 0
    for file in "${DEPLOY_CONF_DIR}"/*.env; do
        [[ -f "${file}" ]] || continue
        name="$(basename "${file}" .env)"
        validate_project_name "${name}" 2>/dev/null || continue
        printf '%s\n' "${name}"
    done | LC_ALL=C sort
}

# --- the image tag in the project's .env ------------------------------------

# deploy_env_tag <variable>: read a .env file on stdin and print the value of
# the variable (the last assignment wins, as in Compose); nothing when it is
# not set.
deploy_env_tag() {
    local var="$1" line value=""
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        if [[ "${line}" == "${var}="* ]]; then
            value="${line#*=}"
            value="${value%\"}"
            value="${value#\"}"
        fi
    done
    printf '%s\n' "${value}"
}

# deploy_env_with_tag <variable> <version>: copy a .env file from stdin with
# the variable set to the version. Every other line is kept as it is; the
# assignment is appended when the file has none.
deploy_env_with_tag() {
    local var="$1" version="$2" line found=0
    validate_deploy_tag_var "${var}" || return 1
    validate_deploy_version "${version}" || return 1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line%$'\r'}" == "${var}="* ]]; then
            if [[ "${found}" == "0" ]]; then
                printf '%s=%s\n' "${var}" "${version}"
                found=1
            fi
            continue
        fi
        printf '%s\n' "${line}"
    done
    if [[ "${found}" == "0" ]]; then
        printf '%s=%s\n' "${var}" "${version}"
    fi
}

# --- the restricted SSH key -------------------------------------------------

# deploy_version_from_ssh <SSH_ORIGINAL_COMMAND>: print the version a
# restricted key asked for. Whatever the client sent is never executed: it
# has to be exactly one valid version.
deploy_version_from_ssh() {
    validate_deploy_version "${1:-}" || return 1
    printf '%s\n' "$1"
}

# _deploy_bin_ok <vps-stack path>: the path ends up inside quotes in
# authorized_keys and in a sudoers rule.
_deploy_bin_ok() {
    if [[ "$1" != /* ]] || has_unsafe_chars "$1" || [[ "$1" == *[:,=*?\[\]\!\(\)]* ]]; then
        printf 'Invalid value: the path of vps-stack must be absolute, without spaces or special characters.\n' >&2
        return 1
    fi
}

# deploy_authorized_keys_line <vps-stack path> <project> <public key>: the
# authorized_keys line of a key that can only start the deploy of one
# project. `restrict` switches off the terminal, every kind of forwarding
# and ~/.ssh/rc; `command` replaces whatever the client asks to run.
deploy_authorized_keys_line() {
    local bin="$1" project="$2" pubkey="$3" key_type key_body rest
    local re_type='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))$'
    local re_body='^[A-Za-z0-9+/]+=*$'
    validate_project_name "${project}" || return 1
    _deploy_bin_ok "${bin}" || return 1
    read -r key_type key_body rest <<<"${pubkey}"
    if [[ ! "${key_type}" =~ ${re_type} || ! "${key_body}" =~ ${re_body} ]]; then
        printf 'Invalid value: not an SSH public key.\n' >&2
        return 1
    fi
    printf 'restrict,command="%s deploy ssh %s" %s %s %s\n' \
        "${bin}" "${project}" "${key_type}" "${key_body}" "$(deploy_key_comment "${project}")"
}

# deploy_sudoers_rule <user> <vps-stack path> <project>: the deployment
# account may run, as root and without a password, the deploy of this one
# project and nothing else. The trailing * stands for the version;
# `deploy run` itself accepts exactly one valid version and no options.
deploy_sudoers_rule() {
    local user="$1" bin="$2" project="$3"
    local re_user='^[a-z_][a-z0-9_-]{0,31}$'
    validate_project_name "${project}" || return 1
    _deploy_bin_ok "${bin}" || return 1
    if [[ ! "${user}" =~ ${re_user} ]]; then
        printf 'Invalid value: not a user name.\n' >&2
        return 1
    fi
    printf '# vps-stack: deploy key of the project "%s". Created by: vps-stack deploy key %s\n' "${project}" "${project}"
    printf '%s ALL=(root) NOPASSWD: %s deploy run %s *\n' "${user}" "${bin}" "${project}"
}

# deploy_authorized_keys_has <project>: is there a deploy key of the project
# in the authorized_keys content on stdin?
deploy_authorized_keys_has() {
    local comment line
    comment="$(deploy_key_comment "$1")"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" == *" ${comment}" ]] && return 0
    done
    return 1
}

# deploy_authorized_keys_without <project>: copy the authorized_keys content
# on stdin, leaving out the deploy keys of the project.
deploy_authorized_keys_without() {
    local comment line
    comment="$(deploy_key_comment "$1")"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" == *" ${comment}" ]] && continue
        printf '%s\n' "${line}"
    done
}

# deploy_known_hosts_line <host> <port> <host public key>: the line a client
# needs to recognise this server.
deploy_known_hosts_line() {
    local host="$1" port="$2" key_type key_body rest
    read -r key_type key_body rest <<<"$3"
    if [[ "${port}" == "22" ]]; then
        printf '%s %s %s\n' "${host}" "${key_type}" "${key_body}"
    else
        printf '[%s]:%s %s %s\n' "${host}" "${port}" "${key_type}" "${key_body}"
    fi
}

# --- logs and history -------------------------------------------------------

# deploy_prune_logs <directory> <keep>: keep the <keep> newest deploy logs
# and print the paths of the others. Prints only; the caller removes them.
deploy_prune_logs() {
    local dir="$1" keep="$2" file count=0
    [[ -d "${dir}" ]] || return 0
    # Log names start with a UTC timestamp, so the reverse name order is
    # newest first.
    while IFS= read -r file; do
        [[ -f "${file}" ]] || continue
        count=$((count + 1))
        if [[ "${count}" -gt "${keep}" ]]; then
            printf '%s\n' "${file}"
        fi
    done < <(printf '%s\n' "${dir}"/deploy-*.log | LC_ALL=C sort -r)
}

# deploy_last <history file>: print the newest history line,
# "<timestamp> <DEPLOY_OK|DEPLOY_FAILED> <project> <version>".
deploy_last() {
    [[ -r "$1" ]] || return 0
    awk '($2 == "DEPLOY_OK" || $2 == "DEPLOY_FAILED") && NF == 4 { last = $0 } END { if (last != "") print last }' "$1"
}
