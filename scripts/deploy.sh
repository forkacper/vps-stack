#!/usr/bin/env bash
# Deploy a version of a project: pull or build its image, migrate, replace
# the containers, and go back to the previous version when that fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=lib/validate.sh
source "${SCRIPT_DIR}/../lib/validate.sh"
# shellcheck source=lib/backup.sh
source "${SCRIPT_DIR}/../lib/backup.sh"
# shellcheck source=lib/deploy.sh
source "${SCRIPT_DIR}/../lib/deploy.sh"

HOST_KEY_FILE="${VPS_STACK_SSH_HOST_KEY:-/etc/ssh/ssh_host_ed25519_key.pub}"
KEY_DIR=""

usage() {
    cat <<USAGE
Usage: sudo vps-stack deploy <command> [arguments]

Commands:
  init <project> [options]   set up the deploy of a project
      --mode image|build       image (default): the image is built elsewhere
                               and the server pulls it; build: the project
                               directory is a git clone and the server
                               builds the image from the given commit
      --tag-var <NAME>         variable in the project's .env used as the
                               image tag in its compose file (default APP_TAG)
      --compose-file <path>    compose file, relative to the project
                               directory, when it has a non-default name
      --migrate "<service> <command>"
                               migrations, run in a one-off container of the
                               new version, e.g. "app php artisan migrate --force"
      --backup                 back up the project before every deploy
      --health-timeout <s>     seconds to wait for healthy containers
                               (default 120)
      --dry-run                show the configuration without writing it
  run <project> <version>    deploy a version: an image tag (mode image) or
                             a commit SHA or git tag (mode build)
  rollback <project>         deploy the version that ran before the current one
  status [<project>]         what is deployed and how the last deploy ended
  key <project> [--host <address>] [--revoke] [--dry-run] [--yes]
                             create (or remove) an SSH key for CI that can
                             only start "deploy run <project> <version>"

A deploy: lock, optional backup, pull or build, migrations, new containers,
wait until they are healthy. When a step fails, the previous version is put
back and the command exits with an error. Migrations are not undone.

Configuration: ${DEPLOY_CONF_DIR}/<project>.env
Logs: ${DEPLOY_LOG_ROOT}/<project>/
USAGE
}

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

step() { printf '\n==> %s\n' "$*"; }

# deploy_bin: the path a deploy key is tied to. The stable symlink when
# provisioning installed it, so that moving the repository does not break
# the key.
deploy_bin() {
    local bin="${REPO_ROOT}/bin/vps-stack"
    if [[ "$(readlink /usr/local/bin/vps-stack 2>/dev/null)" == "${bin}" ]]; then
        bin="/usr/local/bin/vps-stack"
    fi
    printf '%s\n' "${bin}"
}

# load_project <project>: read and validate the deploy configuration. Every
# value is checked again here, because the file can be edited by hand.
load_project() {
    local project="$1" file
    file="$(deploy_conf_file "${project}")"
    [[ -f "${file}" ]] || die "The deploy of ${project} is not set up. Set it up: sudo vps-stack deploy init ${project}"
    DEPLOY_MODE="image"
    DEPLOY_TAG_VAR="APP_TAG"
    DEPLOY_COMPOSE_FILE=""
    DEPLOY_MIGRATE_SERVICE=""
    DEPLOY_MIGRATE_COMMAND=""
    DEPLOY_BACKUP="false"
    DEPLOY_HEALTH_TIMEOUT="120"
    load_env_file "${file}"
    {
        validate_deploy_mode "${DEPLOY_MODE}" &&
            validate_deploy_tag_var "${DEPLOY_TAG_VAR}" &&
            validate_deploy_compose_file "${DEPLOY_COMPOSE_FILE}" &&
            validate_deploy_migrate "${DEPLOY_MIGRATE_SERVICE}" "${DEPLOY_MIGRATE_COMMAND}" &&
            validate_deploy_bool "${DEPLOY_BACKUP}" &&
            validate_deploy_timeout "${DEPLOY_HEALTH_TIMEOUT}"
    } || die "Fix the value in ${file}."
    PROJECT_DIR="$(deploy_project_dir "${project}")"
    [[ -d "${PROJECT_DIR}" ]] || die "The project directory ${PROJECT_DIR} does not exist."
    ENV_FILE="${PROJECT_DIR}/.env"
}

# --- init -------------------------------------------------------------------

cmd_init() {
    local project="" mode="image" tag_var="APP_TAG" compose_file="" migrate="" backup="false" timeout="120"
    local migrate_service="" migrate_command="" file content dir
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode | --tag-var | --compose-file | --migrate | --health-timeout)
                [[ $# -ge 2 ]] || die "$1 needs a value."
                case "$1" in
                    --mode) mode="$2" ;;
                    --tag-var) tag_var="$2" ;;
                    --compose-file) compose_file="$2" ;;
                    --migrate) migrate="$2" ;;
                    *) timeout="$2" ;;
                esac
                shift
                ;;
            --backup) backup="true" ;;
            --dry-run) DRY_RUN=1 ;;
            -*) die "Unknown option: $1" ;;
            *)
                [[ -z "${project}" ]] || die "Give exactly one project."
                project="$1"
                ;;
        esac
        shift
    done
    [[ -n "${project}" ]] || die "Give the project: vps-stack deploy init <project>"
    validate_project_name "${project}" || exit 2
    if [[ -n "${migrate}" ]]; then
        [[ "${migrate}" == *" "* ]] || die "--migrate needs a service and a command, e.g. \"app php artisan migrate --force\"."
        migrate_service="${migrate%% *}"
        migrate_command="${migrate#* }"
    fi
    {
        validate_deploy_mode "${mode}" &&
            validate_deploy_tag_var "${tag_var}" &&
            validate_deploy_compose_file "${compose_file}" &&
            validate_deploy_migrate "${migrate_service}" "${migrate_command}" &&
            validate_deploy_timeout "${timeout}"
    } || exit 2
    require_root
    require_etc_access write

    file="$(deploy_conf_file "${project}")"
    [[ ! -e "${file}" ]] || die "The deploy of ${project} is already set up. To change it: sudoedit ${file}"
    dir="$(deploy_project_dir "${project}")"
    [[ -d "${dir}" ]] || die "The project directory ${dir} does not exist. Create it and put the project's compose file and .env there first."

    if [[ -n "${compose_file}" ]]; then
        [[ -f "${dir}/${compose_file}" ]] || log_warn "${dir}/${compose_file} does not exist yet."
    elif [[ ! -f "${dir}/compose.yaml" && ! -f "${dir}/compose.yml" && ! -f "${dir}/docker-compose.yml" && ! -f "${dir}/docker-compose.yaml" ]]; then
        log_warn "No compose file in ${dir}. If it has another name, set DEPLOY_COMPOSE_FILE in ${file}."
    fi
    if [[ "${mode}" == "build" && ! -d "${dir}/.git" ]]; then
        log_warn "${dir} is not a git clone. Mode build checks out the commit to deploy: clone the project's repository there."
    fi
    if [[ "${backup}" == "true" && ! -f "$(backup_group_conf "${project}")" ]]; then
        log_warn "The backup group ${project} is not set up, so every deploy would stop at the backup: sudo vps-stack backup init ${project}"
    fi

    content="$(render_template "${REPO_ROOT}/templates/deploy-project.env.tmpl" \
        "NAME=${project}" "MODE=${mode}" "TAG_VAR=${tag_var}" "COMPOSE_FILE=${compose_file}" \
        "MIGRATE_SERVICE=${migrate_service}" "MIGRATE_COMMAND=${migrate_command}" \
        "BACKUP=${backup}" "HEALTH_TIMEOUT=${timeout}")"
    run install -d -m 700 "${DEPLOY_CONF_DIR}"
    write_file "${file}" 600 <<<"${content}"
    is_dry_run && return 0

    log_ok "The deploy of ${project} is set up (mode ${mode}). Configuration: ${file}"
    log_info "Deploy a version:     sudo vps-stack deploy run ${project} <version>"
    log_info "A key for your CI:    sudo vps-stack deploy key ${project}"
}

# --- run --------------------------------------------------------------------

# project_git <git arguments...>: git in the project directory, as the owner
# of that directory: its credentials for the remote are the ones that work,
# and root leaves no files of its own in the clone.
project_git() {
    local owner
    owner="$(stat -c %U "${PROJECT_DIR}")"
    if [[ "${owner}" == "$(id -un)" ]]; then
        git -C "${PROJECT_DIR}" "$@"
    else
        runuser -u "${owner}" -- git -C "${PROJECT_DIR}" "$@"
    fi
}

# write_env <content>: rewrite the project's .env in place, which keeps its
# owner and mode.
write_env() {
    if [[ ! -e "${ENV_FILE}" ]]; then
        install -m 600 /dev/null "${ENV_FILE}"
        chown "$(stat -c %u:%g "${PROJECT_DIR}")" "${ENV_FILE}"
    fi
    printf '%s\n' "$1" >"${ENV_FILE}"
}

compose_up() {
    docker compose up -d --remove-orphans --wait --wait-timeout "${DEPLOY_HEALTH_TIMEOUT}"
}

# deploy_steps <project> <version>: everything up to healthy containers.
# Returns at the first failing step; STEPS_* say how far it got, for
# deploy_revert.
deploy_steps() {
    local project="$1" version="$2" content
    local -a migrate=()

    if [[ "${DEPLOY_BACKUP}" == "true" ]]; then
        step "Backup of ${project}"
        "${SCRIPT_DIR}/backup.sh" run "${project}" || return 1
    fi

    if [[ "${DEPLOY_MODE}" == "build" ]]; then
        step "Fetching ${version}"
        STEPS_OLD_COMMIT="$(project_git rev-parse --verify HEAD)" || return 1
        project_git fetch --quiet --tags --prune origin || return 1
        project_git rev-parse --quiet --verify "${version}^{commit}" >/dev/null || {
            log_error "The repository has no commit or tag ${version}."
            return 1
        }
        project_git -c advice.detachedHead=false checkout --quiet --detach "${version}" || return 1
        STEPS_CHECKED_OUT=1
    fi

    if [[ -n "${STEPS_OLD_ENV}" ]]; then
        content="$(deploy_env_with_tag "${DEPLOY_TAG_VAR}" "${version}" <<<"${STEPS_OLD_ENV}")" || return 1
    else
        content="$(deploy_env_with_tag "${DEPLOY_TAG_VAR}" "${version}" </dev/null)" || return 1
    fi
    write_env "${content}" || return 1
    STEPS_ENV_WRITTEN=1

    if [[ "${DEPLOY_MODE}" == "build" ]]; then
        step "Building the image"
        docker compose build || return 1
    else
        step "Pulling the image"
        docker compose pull --quiet || return 1
    fi

    if [[ -n "${DEPLOY_MIGRATE_SERVICE}" ]]; then
        step "Migrations: ${DEPLOY_MIGRATE_SERVICE} ${DEPLOY_MIGRATE_COMMAND}"
        read -r -a migrate <<<"${DEPLOY_MIGRATE_COMMAND}"
        docker compose run --rm -T "${DEPLOY_MIGRATE_SERVICE}" "${migrate[@]}" || return 1
    fi

    step "Starting the containers and waiting until they are healthy (up to ${DEPLOY_HEALTH_TIMEOUT} s)"
    STEPS_SWAPPED=1
    compose_up || return 1
}

# deploy_revert: put back what deploy_steps changed, in reverse order.
deploy_revert() {
    step "The deploy failed. Going back to ${STEPS_OLD_VERSION:-the state before it}"
    if [[ "${STEPS_ENV_WRITTEN}" == "1" ]]; then
        if [[ "${STEPS_HAD_ENV}" == "1" ]]; then
            write_env "${STEPS_OLD_ENV}" || log_error "Could not restore ${ENV_FILE}."
        else
            rm -f "${ENV_FILE}"
        fi
    fi
    if [[ "${STEPS_CHECKED_OUT}" == "1" ]]; then
        project_git -c advice.detachedHead=false checkout --quiet --detach "${STEPS_OLD_COMMIT}" ||
            log_error "Could not check out the previous commit ${STEPS_OLD_COMMIT}."
    fi
    if [[ "${STEPS_SWAPPED}" != "1" ]]; then
        log_info "The running containers were not touched."
    elif [[ -z "${STEPS_OLD_VERSION}" ]]; then
        log_warn "There was no version before this one to go back to."
    elif compose_up; then
        log_info "Version ${STEPS_OLD_VERSION} is running again. Migrations, if any ran, were not undone."
    else
        log_error "Version ${STEPS_OLD_VERSION} did not start either. The project needs your attention: cd ${PROJECT_DIR} && docker compose ps"
    fi
}

# deploy_execute <project> <version>: runs in a subshell whose output is the
# deploy log; its exit code is the result of the deploy.
deploy_execute() {
    local project="$1" version="$2"
    cd "${PROJECT_DIR}" || return 1
    if [[ -n "${DEPLOY_COMPOSE_FILE}" ]]; then
        export COMPOSE_FILE="${PROJECT_DIR}/${DEPLOY_COMPOSE_FILE}"
    fi
    [[ ! -L "${ENV_FILE}" ]] || {
        log_error "${ENV_FILE} is a symbolic link. A deploy only writes to a regular file."
        return 1
    }
    STEPS_HAD_ENV=0
    STEPS_OLD_ENV=""
    if [[ -f "${ENV_FILE}" ]]; then
        STEPS_HAD_ENV=1
        STEPS_OLD_ENV="$(cat "${ENV_FILE}")"
    fi
    STEPS_OLD_VERSION="$(deploy_env_tag "${DEPLOY_TAG_VAR}" <<<"${STEPS_OLD_ENV}")"
    STEPS_OLD_COMMIT=""
    STEPS_CHECKED_OUT=0
    STEPS_ENV_WRITTEN=0
    STEPS_SWAPPED=0

    printf 'Deploying %s %s (mode %s, running: %s)\n' "${project}" "${version}" "${DEPLOY_MODE}" "${STEPS_OLD_VERSION:-nothing}"
    if ! deploy_steps "${project}" "${version}"; then
        deploy_revert
        return 1
    fi
    # What `rollback` returns to. A redeploy of the running version keeps it.
    if [[ -n "${STEPS_OLD_VERSION}" && "${STEPS_OLD_VERSION}" != "${version}" ]] &&
        validate_deploy_version "${STEPS_OLD_VERSION}" 2>/dev/null; then
        printf '%s\n' "${STEPS_OLD_VERSION}" >"$(deploy_previous_file "${project}")"
    fi
    printf '\nDeployed %s %s\n' "${project}" "${version}"
}

# cmd_run <project> <version>: exactly these two arguments and no options.
# A deploy key reaches this command through a sudoers rule whose last
# argument is a wildcard, so nothing here may change what a deploy does.
cmd_run() {
    if [[ $# -ne 2 ]]; then
        die "Give exactly a project and a version: vps-stack deploy run <project> <version>"
    fi
    local project="$1" version="$2" state_dir log_dir log code=0 old
    validate_project_name "${project}" || exit 2
    validate_deploy_version "${version}" || exit 2
    require_root
    require_etc_access
    load_project "${project}"
    require_cmd docker flock
    if [[ "${DEPLOY_MODE}" == "build" ]]; then
        require_cmd git
    fi

    state_dir="$(deploy_state_dir "${project}")"
    log_dir="$(deploy_log_dir "${project}")"
    install -d -m 700 "${state_dir}"
    install -d -m 750 "${log_dir}"

    # The lock belongs to this process only: everything started below gets
    # the descriptor closed.
    exec 9>"${state_dir}/.lock"
    flock -n 9 || die "A deploy of ${project} is already running. Its log is the newest file in ${log_dir}/"

    log="${log_dir}/deploy-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
    printf '# %s deploy of %s, version %s\n' "$(stamp)" "${project}" "${version}" >"${log}"
    log_info "Log: ${log}"

    # A cancelled pipeline closes the SSH connection in the middle of a
    # deploy. tee ignores the broken pipe and keeps writing the log, so the
    # deploy never notices and runs to its end instead of stopping halfway.
    trap '' HUP
    set +e
    (deploy_execute "${project}" "${version}") 2>&1 9>&- </dev/null | (
        trap '' PIPE
        exec tee -a "${log}"
    ) 9>&-
    code="${PIPESTATUS[0]}"
    set -e
    # From here on a closed connection must not stop the bookkeeping either.
    trap '' PIPE

    if [[ "${code}" -eq 0 ]]; then
        printf '%s DEPLOY_OK %s %s\n' "$(stamp)" "${project}" "${version}" >>"$(deploy_history_file "${project}")"
    else
        printf '%s DEPLOY_FAILED %s %s\n' "$(stamp)" "${project}" "${version}" >>"$(deploy_history_file "${project}")"
    fi
    while IFS= read -r old; do
        [[ -n "${old}" ]] && rm -f "${old}"
    done < <(deploy_prune_logs "${log_dir}" "${DEPLOY_LOG_KEEP}")

    if [[ "${code}" -ne 0 ]]; then
        log_error "The deploy of ${project} ${version} failed. Log: ${log}" || true
        exit 1
    fi
    log_ok "Deployed ${project} ${version}." 2>/dev/null || true
}

cmd_rollback() {
    [[ $# -eq 1 ]] || die "Give the project: vps-stack deploy rollback <project>"
    local project="$1" file previous
    validate_project_name "${project}" || exit 2
    require_root
    require_etc_access
    load_project "${project}"
    file="$(deploy_previous_file "${project}")"
    [[ -s "${file}" ]] || die "No previous version of ${project} is recorded. Deploy a specific one: vps-stack deploy run ${project} <version>"
    previous="$(head -n 1 "${file}")"
    validate_deploy_version "${previous}" || die "The recorded previous version in ${file} is not valid."
    log_info "Rolling ${project} back to ${previous}. Database migrations are not undone."
    cmd_run "${project}" "${previous}"
}

# cmd_ssh <project>: the forced command of a deploy key. Runs as the
# deployment account; what the SSH client asked to run is the version and
# nothing else. Not listed in the help: nobody types it.
cmd_ssh() {
    [[ $# -eq 1 ]] || die "Usage: vps-stack deploy ssh <project>"
    local project="$1" version
    validate_project_name "${project}" || exit 2
    version="$(deploy_version_from_ssh "${SSH_ORIGINAL_COMMAND:-}")" ||
        die "This key can only deploy a version of ${project}: ssh <server> <version>"
    exec sudo -n "$(deploy_bin)" deploy run "${project}" "${version}"
}

# --- status -----------------------------------------------------------------

cmd_status() {
    [[ $# -le 1 ]] || die "Give at most one project."
    local project current previous last result when version failed=0
    local -a projects=()
    require_etc_access
    if [[ $# -eq 1 ]]; then
        validate_project_name "$1" || exit 2
        [[ -f "$(deploy_conf_file "$1")" ]] || die "The deploy of $1 is not set up. Set it up: sudo vps-stack deploy init $1"
        projects=("$1")
    else
        while IFS= read -r project; do
            [[ -n "${project}" ]] && projects+=("${project}")
        done < <(deploy_projects)
    fi
    if [[ "${#projects[@]}" -eq 0 ]]; then
        log_info "No project has a deploy set up. Set one up: sudo vps-stack deploy init <project>"
        return 0
    fi
    printf '%s%s %s %s %s %s%s\n' "${C_BOLD}" "$(_pad "PROJECT" 20)" "$(_pad "MODE" 6)" \
        "$(_pad "DEPLOYED" 20)" "$(_pad "PREVIOUS" 20)" "LAST DEPLOY" "${C_RESET}"
    for project in "${projects[@]}"; do
        load_project "${project}"
        current=""
        if [[ -r "${ENV_FILE}" ]]; then
            current="$(deploy_env_tag "${DEPLOY_TAG_VAR}" <"${ENV_FILE}")"
        fi
        previous=""
        if [[ -r "$(deploy_previous_file "${project}")" ]]; then
            previous="$(head -n 1 "$(deploy_previous_file "${project}")")"
        fi
        last="$(deploy_last "$(deploy_history_file "${project}")")"
        if [[ -z "${last}" ]]; then
            result="never"
        else
            read -r when result _ version <<<"${last}"
            if [[ "${result}" == "DEPLOY_OK" ]]; then
                result="${C_GREEN}ok${C_RESET} ${when} ${version}"
            else
                result="${C_RED}FAILED${C_RESET} ${when} ${version}"
                failed=1
            fi
        fi
        printf '%s %s %s %s %s\n' "$(_pad "${project}" 20)" "$(_pad "${DEPLOY_MODE}" 6)" \
            "$(_pad "${current:--}" 20)" "$(_pad "${previous:--}" 20)" "${result}"
    done
    return "${failed}"
}

# --- key --------------------------------------------------------------------

cleanup() {
    if [[ -n "${KEY_DIR}" && -d "${KEY_DIR}" ]]; then
        rm -rf "${KEY_DIR}"
    fi
}

# write_authorized_keys <file> <owner:group> <content>: write_file refuses
# empty content, and removing the last key leaves exactly that.
write_authorized_keys() {
    local file="$1" owner="$2" content="$3"
    if [[ -n "${content}" ]]; then
        write_file "${file}" 600 "${owner}" <<<"${content}"
        return 0
    fi
    backup_file "${file}"
    run truncate -s 0 "${file}"
}

# sshd_port: the port sshd really listens on; stack.env is only a fallback.
sshd_port() {
    local port=""
    if have_cmd sshd; then
        port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')" || port=""
    fi
    printf '%s\n' "${port:-${SSH_PORT}}"
}

print_key_values() {
    local project="$1" host="$2" private_key="$3" port host_key shown_host
    port="$(sshd_port)"
    shown_host="${host:-<server address>}"
    cat <<VALUES

${C_BOLD}Values for the secret store of your CI${C_RESET}

DEPLOY_HOST
${shown_host}

DEPLOY_PORT
${port}

DEPLOY_USER
${DEPLOY_USER}
VALUES
    if [[ -r "${HOST_KEY_FILE}" ]]; then
        host_key="$(cat "${HOST_KEY_FILE}")"
        printf '\nDEPLOY_KNOWN_HOSTS\n%s\n' "$(deploy_known_hosts_line "${shown_host}" "${port}" "${host_key}")"
    else
        log_warn "Cannot read ${HOST_KEY_FILE}. For DEPLOY_KNOWN_HOSTS run on your computer: ssh-keyscan -p ${port} -t ed25519 ${shown_host}"
    fi
    printf '\nDEPLOY_SSH_KEY (all lines, including BEGIN and END)\n%s\n' "${private_key}"
    cat <<NOTES

This is the only copy of the private key: it is not kept on the server. If
you lose it, run this command again.

The pipeline deploys with one command, the version being all it can say:
  ssh -i <key file> -p ${port} ${DEPLOY_USER}@${shown_host} <version>

Example workflow: ${REPO_ROOT}/examples/project-deploy-workflow.yml.example
NOTES
}

cmd_key() {
    local project="" host="" revoke=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                [[ $# -ge 2 ]] || die "--host needs a value."
                host="$2"
                shift
                ;;
            --revoke) revoke=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --yes | -y) ASSUME_YES=1 ;;
            -*) die "Unknown option: $1" ;;
            *)
                [[ -z "${project}" ]] || die "Give exactly one project."
                project="$1"
                ;;
        esac
        shift
    done
    [[ -n "${project}" ]] || die "Give the project: vps-stack deploy key <project>"
    validate_project_name "${project}" || exit 2
    if [[ -n "${host}" ]]; then
        host="$(normalize_ip "${host}" 2>/dev/null || normalize_domain "${host}")" || exit 2
    fi
    require_root
    require_etc_access
    stack_config_load "${STACK_ENV_FILE}"

    id -u "${DEPLOY_USER}" >/dev/null 2>&1 || die "User ${DEPLOY_USER} (DEPLOY_USER) does not exist. Run 'vps-stack provision' first."
    local home group ssh_dir auth_file sudoers_file existing="" others bin line rule content private_key tmp
    home="$(getent passwd "${DEPLOY_USER}" | cut -d: -f6)"
    [[ -n "${home}" && -d "${home}" ]] || die "User ${DEPLOY_USER} has no home directory."
    group="$(id -gn "${DEPLOY_USER}")"
    ssh_dir="${home}/.ssh"
    auth_file="${ssh_dir}/authorized_keys"
    sudoers_file="$(deploy_sudoers_file "${project}")"
    if [[ -f "${auth_file}" ]]; then
        existing="$(cat "${auth_file}")"
    fi
    others="$(deploy_authorized_keys_without "${project}" <<<"${existing}")"

    if [[ "${revoke}" == "1" ]]; then
        if ! deploy_authorized_keys_has "${project}" <<<"${existing}" && [[ ! -e "${sudoers_file}" ]]; then
            log_info "Project ${project} has no deploy key. Nothing to do."
            return 0
        fi
        confirm "Remove the deploy key of ${project}? Pipelines using it will no longer deploy." || die "Aborted. Nothing was changed."
        if deploy_authorized_keys_has "${project}" <<<"${existing}"; then
            write_authorized_keys "${auth_file}" "${DEPLOY_USER}:${group}" "${others}"
        fi
        run rm -f "${sudoers_file}"
        log_ok "Removed the deploy key of ${project}. Delete DEPLOY_SSH_KEY from the secret store of your CI as well."
        return 0
    fi

    load_project "${project}"
    require_cmd ssh-keygen sudo visudo
    if [[ "$(stat -c %U "${PROJECT_DIR}")" == "${DEPLOY_USER}" ]]; then
        log_warn "${PROJECT_DIR} belongs to ${DEPLOY_USER}. The key itself can only name a version, but anyone with a"
        log_warn "shell on that account can edit the compose file that root then starts. If that account should not"
        log_warn "be equivalent to root, give the directory to the administrator (docs/deploying.md)."
    fi
    if deploy_authorized_keys_has "${project}" <<<"${existing}"; then
        confirm "Project ${project} already has a deploy key. Replace it? The old key stops working." || die "Aborted. Nothing was changed."
    fi

    bin="$(deploy_bin)"
    rule="$(deploy_sudoers_rule "${DEPLOY_USER}" "${bin}" "${project}")" || die "Could not build the sudoers rule (internal error)."
    run install -d -m 700 -o "${DEPLOY_USER}" -g "${group}" "${ssh_dir}"

    if is_dry_run; then
        log_dry "write ${sudoers_file} (mode 440):"
        log_dry "  ${rule##*$'\n'}"
        log_dry "generate an ed25519 key pair and add to ${auth_file}:"
        log_dry "  restrict,command=\"${bin} deploy ssh ${project}\" ssh-ed25519 <public key> $(deploy_key_comment "${project}")"
        return 0
    fi

    # A broken file in sudoers.d breaks sudo for everyone: check it first.
    tmp="$(mktemp)"
    printf '%s\n' "${rule}" >"${tmp}"
    if ! visudo -cf "${tmp}" >/dev/null; then
        rm -f "${tmp}"
        die "visudo rejected the sudoers rule (internal error). Nothing was changed."
    fi
    rm -f "${tmp}"
    # No backup copy: sudo would read it as one more rule file.
    write_file --no-backup "${sudoers_file}" 440 root:root <<<"${rule}"

    KEY_DIR="$(mktemp -d)"
    trap cleanup EXIT
    chmod 700 "${KEY_DIR}"
    ssh-keygen -q -t ed25519 -N "" -C "$(deploy_key_comment "${project}")" -f "${KEY_DIR}/key"
    line="$(deploy_authorized_keys_line "${bin}" "${project}" "$(cat "${KEY_DIR}/key.pub")")" ||
        die "Could not build the authorized_keys line (internal error)."
    content="${others:+${others}$'\n'}${line}"
    write_authorized_keys "${auth_file}" "${DEPLOY_USER}:${group}" "${content}"
    private_key="$(cat "${KEY_DIR}/key")"
    cleanup

    log_ok "Deploy key of ${project} added to ${auth_file}."
    print_key_values "${project}" "${host}" "${private_key}"
}

main() {
    local command="${1:-}"
    [[ $# -gt 0 ]] && shift
    case "${command}" in
        init) cmd_init "$@" ;;
        run) cmd_run "$@" ;;
        rollback) cmd_rollback "$@" ;;
        status) cmd_status "$@" ;;
        key) cmd_key "$@" ;;
        ssh) cmd_ssh "$@" ;;
        "" | help | -h | --help) usage ;;
        *)
            usage >&2
            die "Unknown command: deploy ${command}"
            ;;
    esac
}

main "$@"
