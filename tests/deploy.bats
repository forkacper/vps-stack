#!/usr/bin/env bats

load helpers

DEPLOY="${REPO_ROOT}/scripts/deploy.sh"
PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGJ1c3QgYSB0ZXN0IGtleSwgbm90IHJlYWwhISEh someone@laptop"

setup() {
    ETC_DIR="${BATS_TEST_TMPDIR}/etc"
    PROJECTS_ROOT="${BATS_TEST_TMPDIR}/srv"
    DEPLOY_CONF_DIR="${ETC_DIR}/deploy"
    DEPLOY_STATE_ROOT="${BATS_TEST_TMPDIR}/state"
    DEPLOY_LOG_ROOT="${BATS_TEST_TMPDIR}/log"
    SUDOERS_DIR="${BATS_TEST_TMPDIR}/sudoers.d"
    export VPS_STACK_ETC_DIR="${ETC_DIR}" VPS_STACK_PROJECTS_ROOT="${PROJECTS_ROOT}" \
        VPS_STACK_DEPLOY_STATE_ROOT="${DEPLOY_STATE_ROOT}" VPS_STACK_DEPLOY_LOG_ROOT="${DEPLOY_LOG_ROOT}" \
        VPS_STACK_SUDOERS_DIR="${SUDOERS_DIR}"
    unset SSH_ORIGINAL_COMMAND

    # A docker that records how it was called and fails on request: the
    # file ${FAKE_DIR}/fail-<compose command> makes that command fail once
    # the tag in .env is the one named in the file.
    FAKE_DIR="${BATS_TEST_TMPDIR}/fake"
    export FAKE_DIR
    mkdir -p "${FAKE_DIR}/bin" "${ETC_DIR}"
    cat >"${FAKE_DIR}/bin/docker" <<'FAKE'
#!/usr/bin/env bash
tag="$(sed -n 's/^APP_TAG=//p' .env 2>/dev/null)"
printf '%s tag=%s file=%s\n' "$*" "${tag}" "${COMPOSE_FILE:-}" >>"${FAKE_DIR}/calls"
if [[ -f "${FAKE_DIR}/fail-$2" && "$(cat "${FAKE_DIR}/fail-$2")" == "${tag}" ]]; then
    echo "fake docker: $2 failed" >&2
    exit 1
fi
if [[ "$2" == "up" && -e "${FAKE_DIR}/block" ]]; then
    touch "${FAKE_DIR}/started"
    while [[ ! -e "${FAKE_DIR}/finish" ]]; do sleep 0.1; done
fi
exit 0
FAKE
    chmod +x "${FAKE_DIR}/bin/docker"
    PATH="${FAKE_DIR}/bin:${PATH}"
}

# The tests of the command itself: it needs root and flock, which the CI
# container provides.
runs_deploy() {
    [ "$(id -u)" -eq 0 ] || skip "needs root"
    command -v flock >/dev/null 2>&1 || skip "flock is not installed"
}

# project <name> [init options...]: a project directory running v1.
project() {
    local name="$1"
    shift
    mkdir -p "${PROJECTS_ROOT}/${name}"
    printf 'APP_ENV=production\nAPP_TAG=v1\nDB_PASSWORD=secret\n' >"${PROJECTS_ROOT}/${name}/.env"
    touch "${PROJECTS_ROOT}/${name}/compose.yaml"
    "${DEPLOY}" init "${name}" "$@" >/dev/null
}

calls() { cat "${FAKE_DIR}/calls" 2>/dev/null; }

# --- names and values -------------------------------------------------------

@test "project name: directory names are valid" {
    local value
    for value in "example-app" "shop_2" "a" "$(repeat_char a 63)"; do
        run validate_project_name "${value}"
        [ "$status" -eq 0 ]
    done
}

@test "project name: invalid names are rejected" {
    local value
    for value in "" "-app" "App" "my app" "../etc" "a/b" "app.sh" "$(repeat_char a 64)" \
        $'app\nother' 'app$(id)' 'app;id' 'app"' 'app*'; do
        run validate_project_name "${value}"
        [ "$status" -ne 0 ]
    done
}

@test "version: image tags, commit SHAs and versions are valid" {
    local value
    for value in "3f2a9c1d4b5e" "v1.2.3" "main" "release_2026-10-09" "$(repeat_char a 128)"; do
        run validate_deploy_version "${value}"
        [ "$status" -eq 0 ]
    done
}

@test "version: options and anything a shell could interpret are rejected" {
    local value
    for value in "" "-rf" "--help" ".hidden" "a b" "a;id" 'a$(id)' 'a`id`' "a|b" "a&b" "a/b" "../x" "a>b" \
        $'a\nb' "a'b" 'a"b' "a:b" "a*" "$(repeat_char a 129)"; do
        run validate_deploy_version "${value}"
        [ "$status" -ne 0 ]
    done
}

@test "configuration values: mode, tag variable, compose file, timeout" {
    run validate_deploy_mode image
    [ "$status" -eq 0 ]
    run validate_deploy_mode build
    [ "$status" -eq 0 ]
    run validate_deploy_mode "push"
    [ "$status" -ne 0 ]

    run validate_deploy_tag_var APP_TAG
    [ "$status" -eq 0 ]
    local value
    for value in "" "app_tag" "1TAG" "APP-TAG" "APP TAG" 'A$B' "PATH=x"; do
        run validate_deploy_tag_var "${value}"
        [ "$status" -ne 0 ]
    done

    for value in "" "docker-compose.prod.yml" "deploy/compose.yaml"; do
        run validate_deploy_compose_file "${value}"
        [ "$status" -eq 0 ]
    done
    for value in "/etc/compose.yml" "../other/compose.yml" "a/../../b.yml" "-f.yml" "a b.yml" 'a$b.yml' "a.yml:b.yml"; do
        run validate_deploy_compose_file "${value}"
        [ "$status" -ne 0 ]
    done

    for value in 1 120 3600; do
        run validate_deploy_timeout "${value}"
        [ "$status" -eq 0 ]
    done
    for value in "" 0 3601 99999 "12s" "-5" "1 2"; do
        run validate_deploy_timeout "${value}"
        [ "$status" -ne 0 ]
    done
}

@test "migrations: a service and plain words, or nothing" {
    run validate_deploy_migrate "" ""
    [ "$status" -eq 0 ]
    run validate_deploy_migrate app "php artisan migrate --force"
    [ "$status" -eq 0 ]
    run validate_deploy_migrate web "python manage.py migrate --noinput --database=default"
    [ "$status" -eq 0 ]
    run validate_deploy_migrate "" "php artisan migrate"
    [ "$status" -ne 0 ]
    run validate_deploy_migrate app ""
    [ "$status" -ne 0 ]
    local value
    for value in "sh -c 'rm -rf /'" 'echo $HOME' "a; b" "a | b" "a && b" 'a "b"' "a  b" "--rm x" 'a`b`' "a > b"; do
        run validate_deploy_migrate app "${value}"
        [ "$status" -ne 0 ]
    done
    run validate_deploy_migrate "app;id" "migrate"
    [ "$status" -ne 0 ]
    run validate_deploy_migrate "-app" "migrate"
    [ "$status" -ne 0 ]
}

@test "paths of a project" {
    [ "$(deploy_project_dir example-app)" = "${PROJECTS_ROOT}/example-app" ]
    [ "$(deploy_conf_file example-app)" = "${DEPLOY_CONF_DIR}/example-app.env" ]
    [ "$(deploy_previous_file example-app)" = "${DEPLOY_STATE_ROOT}/example-app/previous" ]
    [ "$(deploy_history_file example-app)" = "${DEPLOY_STATE_ROOT}/example-app/history.log" ]
    [ "$(deploy_log_dir example-app)" = "${DEPLOY_LOG_ROOT}/example-app" ]
    [ "$(deploy_sudoers_file example-app)" = "${SUDOERS_DIR}/vps-stack-deploy-example-app" ]
    [ "$(deploy_key_comment example-app)" = "vps-stack-deploy:example-app" ]
}

@test "projects: sorted; other files ignored" {
    run deploy_projects
    [ "$output" = "" ]
    mkdir -p "${DEPLOY_CONF_DIR}"
    touch "${DEPLOY_CONF_DIR}/shop.env" "${DEPLOY_CONF_DIR}/blog.env" "${DEPLOY_CONF_DIR}/Bad Name.env" \
        "${DEPLOY_CONF_DIR}/notes.txt" "${DEPLOY_CONF_DIR}/blog.env.bak.20261009-100000"
    run deploy_projects
    [ "$status" -eq 0 ]
    [ "$output" = $'blog\nshop' ]
}

# --- the image tag in .env --------------------------------------------------

@test ".env: the tag is read; the last assignment wins" {
    [ "$(printf 'A=1\nAPP_TAG=v1\nB=2\n' | deploy_env_tag APP_TAG)" = "v1" ]
    [ "$(printf 'APP_TAG=v1\nAPP_TAG="v2"\n' | deploy_env_tag APP_TAG)" = "v2" ]
    [ "$(printf 'MY_APP_TAG=v9\n# APP_TAG=old\n' | deploy_env_tag APP_TAG)" = "" ]
    [ "$(printf '' | deploy_env_tag APP_TAG)" = "" ]
}

@test ".env: only the tag line changes" {
    run deploy_env_with_tag APP_TAG v2 <<<$'APP_ENV=production\nAPP_TAG=v1\n# a comment\nDB_PASSWORD=p$ss "w" #rd'
    [ "$status" -eq 0 ]
    [ "$output" = $'APP_ENV=production\nAPP_TAG=v2\n# a comment\nDB_PASSWORD=p$ss "w" #rd' ]
}

@test ".env: the tag is appended when missing, duplicates collapse" {
    run deploy_env_with_tag APP_TAG v2 <<<"APP_ENV=production"
    [ "$output" = $'APP_ENV=production\nAPP_TAG=v2' ]
    run deploy_env_with_tag APP_TAG v2 <<<$'APP_TAG=a\nX=1\nAPP_TAG=b'
    [ "$output" = $'APP_TAG=v2\nX=1' ]
}

@test ".env: an invalid version or variable writes nothing" {
    run deploy_env_with_tag APP_TAG $'v2\nEVIL=1' <<<"APP_TAG=v1"
    [ "$status" -ne 0 ]
    [[ "$output" != *"EVIL"* ]]
    run deploy_env_with_tag 'APP_TAG=x' v2 <<<"APP_TAG=v1"
    [ "$status" -ne 0 ]
}

# --- the restricted key -----------------------------------------------------

@test "ssh command: exactly one version, nothing else" {
    run deploy_version_from_ssh "3f2a9c1d4b5e"
    [ "$status" -eq 0 ]
    [ "$output" = "3f2a9c1d4b5e" ]
    local value
    for value in "" "bash -i" "vps-stack deploy run other-app v1" "abc; rm -rf /" "abc other" 'abc$(id)' \
        "/bin/sh" "--help" "v1 --mode build"; do
        run deploy_version_from_ssh "${value}"
        [ "$status" -ne 0 ]
    done
}

@test "authorized_keys line: restricted to the deploy of one project" {
    run deploy_authorized_keys_line /usr/local/bin/vps-stack example-app "${PUBKEY}"
    [ "$status" -eq 0 ]
    [ "$output" = 'restrict,command="/usr/local/bin/vps-stack deploy ssh example-app" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGJ1c3QgYSB0ZXN0IGtleSwgbm90IHJlYWwhISEh vps-stack-deploy:example-app' ]
}

@test "authorized_keys line: invalid input produces nothing" {
    run deploy_authorized_keys_line /usr/local/bin/vps-stack 'app" x' "${PUBKEY}"
    [ "$status" -ne 0 ]
    [[ "$output" != *restrict* ]]
    run deploy_authorized_keys_line 'bin/vps-stack' example-app "${PUBKEY}"
    [ "$status" -ne 0 ]
    run deploy_authorized_keys_line '/opt/a" b/vps-stack' example-app "${PUBKEY}"
    [ "$status" -ne 0 ]
    run deploy_authorized_keys_line /usr/local/bin/vps-stack example-app 'ssh-ed25519 AAAA"B'
    [ "$status" -ne 0 ]
    run deploy_authorized_keys_line /usr/local/bin/vps-stack example-app 'not-a-key AAAA'
    [ "$status" -ne 0 ]
    run deploy_authorized_keys_line /usr/local/bin/vps-stack example-app ''
    [ "$status" -ne 0 ]
}

@test "sudoers rule: one command of one project" {
    run deploy_sudoers_rule deploy /usr/local/bin/vps-stack example-app
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = "deploy ALL=(root) NOPASSWD: /usr/local/bin/vps-stack deploy run example-app *" ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "${lines[0]}" == "#"* ]]
}

@test "sudoers rule: invalid input produces nothing" {
    local user
    for user in "" "ALL" "deploy, admin" "%sudo" "deploy ALL=(ALL) ALL #"; do
        run deploy_sudoers_rule "${user}" /usr/local/bin/vps-stack example-app
        [ "$status" -ne 0 ]
        [[ "$output" != *NOPASSWD* ]]
    done
    run deploy_sudoers_rule deploy /usr/local/bin/vps-stack 'app *'
    [ "$status" -ne 0 ]
    for user in "bin/vps-stack" "/usr/bin/*" "/bin/sh, /usr/bin/vps-stack" "/opt/a:b/vps-stack" "/opt/a=b/vps-stack"; do
        run deploy_sudoers_rule deploy "${user}" example-app
        [ "$status" -ne 0 ]
        [[ "$output" != *NOPASSWD* ]]
    done
}

@test "authorized_keys: only the keys of the project are found and removed" {
    local content shop app
    shop="$(deploy_authorized_keys_line /usr/local/bin/vps-stack shop "${PUBKEY}")"
    app="$(deploy_authorized_keys_line /usr/local/bin/vps-stack example-app "${PUBKEY}")"
    content="${PUBKEY}"$'\n'"${shop}"$'\n'"${app}"

    run deploy_authorized_keys_has example-app <<<"${content}"
    [ "$status" -eq 0 ]
    run deploy_authorized_keys_has example <<<"${content}"
    [ "$status" -ne 0 ]
    run deploy_authorized_keys_has blog <<<"${content}"
    [ "$status" -ne 0 ]

    run deploy_authorized_keys_without example-app <<<"${content}"
    [ "$status" -eq 0 ]
    [ "$output" = "${PUBKEY}"$'\n'"${shop}" ]
    run deploy_authorized_keys_without blog <<<"${content}"
    [ "$output" = "${content}" ]
}

@test "known_hosts line: the port is named only when it is not 22" {
    [ "$(deploy_known_hosts_line example.com 22 "ssh-ed25519 AAAAC3 root@srv1")" = "example.com ssh-ed25519 AAAAC3" ]
    [ "$(deploy_known_hosts_line example.com 2222 "ssh-ed25519 AAAAC3 root@srv1")" = "[example.com]:2222 ssh-ed25519 AAAAC3" ]
}

# --- logs and history -------------------------------------------------------

@test "log pruning: the newest logs are kept" {
    local dir="${BATS_TEST_TMPDIR}/logs"
    mkdir -p "${dir}"
    touch "${dir}/deploy-20261001T100000Z-1.log" "${dir}/deploy-20261003T100000Z-1.log" \
        "${dir}/deploy-20261002T100000Z-1.log" "${dir}/other.log"
    run deploy_prune_logs "${dir}" 2
    [ "$status" -eq 0 ]
    [ "$output" = "${dir}/deploy-20261001T100000Z-1.log" ]
    run deploy_prune_logs "${dir}" 5
    [ "$output" = "" ]
    run deploy_prune_logs "${BATS_TEST_TMPDIR}/missing" 2
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    mkdir -p "${BATS_TEST_TMPDIR}/empty"
    run deploy_prune_logs "${BATS_TEST_TMPDIR}/empty" 2
    [ "$output" = "" ]
}

@test "history: the newest entry wins, other lines are ignored" {
    local file="${BATS_TEST_TMPDIR}/history.log"
    run deploy_last "${file}"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    printf '%s\n' "2026-10-08T10:00:00Z DEPLOY_OK example-app abc" \
        "2026-10-09T10:00:00Z DEPLOY_FAILED example-app def" "garbage" >"${file}"
    run deploy_last "${file}"
    [ "$output" = "2026-10-09T10:00:00Z DEPLOY_FAILED example-app def" ]
}

# --- deploy init ------------------------------------------------------------

@test "init: writes the configuration, refuses to overwrite it" {
    runs_deploy
    mkdir -p "${PROJECTS_ROOT}/example-app"
    touch "${PROJECTS_ROOT}/example-app/compose.yaml"
    run "${DEPLOY}" init example-app --migrate "app php artisan migrate --force" --health-timeout 60
    [ "$status" -eq 0 ]
    local file="${DEPLOY_CONF_DIR}/example-app.env"
    grep -qx 'DEPLOY_MODE=image' "${file}"
    grep -qx 'DEPLOY_TAG_VAR=APP_TAG' "${file}"
    grep -qx 'DEPLOY_COMPOSE_FILE=' "${file}"
    grep -qx 'DEPLOY_MIGRATE_SERVICE=app' "${file}"
    grep -qx 'DEPLOY_MIGRATE_COMMAND=php artisan migrate --force' "${file}"
    grep -qx 'DEPLOY_BACKUP=false' "${file}"
    grep -qx 'DEPLOY_HEALTH_TIMEOUT=60' "${file}"
    file_has_mode "${file}" 600

    run "${DEPLOY}" init example-app --mode build
    [ "$status" -ne 0 ]
    [[ "$output" == *"already set up"* ]]
    grep -qx 'DEPLOY_MODE=image' "${file}"
}

@test "init: invalid options and a missing project directory are refused" {
    runs_deploy
    mkdir -p "${PROJECTS_ROOT}/example-app"
    run "${DEPLOY}" init example-app --mode push
    [ "$status" -ne 0 ]
    run "${DEPLOY}" init example-app --migrate "app sh -c 'id'"
    [ "$status" -ne 0 ]
    run "${DEPLOY}" init example-app --compose-file /etc/passwd
    [ "$status" -ne 0 ]
    run "${DEPLOY}" init example-app --tag-var 'X=1'
    [ "$status" -ne 0 ]
    [ ! -e "${DEPLOY_CONF_DIR}/example-app.env" ]
    run "${DEPLOY}" init missing-app
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "init --dry-run writes nothing" {
    runs_deploy
    mkdir -p "${PROJECTS_ROOT}/example-app"
    run "${DEPLOY}" init example-app --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DEPLOY_MODE=image"* ]]
    [ ! -e "${DEPLOY_CONF_DIR}/example-app.env" ]
}

# --- deploy run -------------------------------------------------------------

@test "run (image): tag, pull, migrate, up; previous version recorded" {
    runs_deploy
    project example-app --migrate "app php artisan migrate --force" --health-timeout 60
    run "${DEPLOY}" run example-app v2
    [ "$status" -eq 0 ]
    [ "$(cat "${PROJECTS_ROOT}/example-app/.env")" = $'APP_ENV=production\nAPP_TAG=v2\nDB_PASSWORD=secret' ]
    [ "$(calls)" = "compose pull --quiet tag=v2 file=
compose run --rm -T app php artisan migrate --force tag=v2 file=
compose up -d --remove-orphans --wait --wait-timeout 60 tag=v2 file=" ]
    [ "$(cat "${DEPLOY_STATE_ROOT}/example-app/previous")" = "v1" ]
    grep -Eq '^[0-9TZ:-]+ DEPLOY_OK example-app v2$' "${DEPLOY_STATE_ROOT}/example-app/history.log"
    grep -q "Deployed example-app v2" "${DEPLOY_LOG_ROOT}"/example-app/deploy-*.log
}

@test "run: no migrations configured, a custom compose file" {
    runs_deploy
    project example-app --compose-file docker-compose.prod.yml
    run "${DEPLOY}" run example-app v2
    [ "$status" -eq 0 ]
    [ "$(calls)" = "compose pull --quiet tag=v2 file=${PROJECTS_ROOT}/example-app/docker-compose.prod.yml
compose up -d --remove-orphans --wait --wait-timeout 120 tag=v2 file=${PROJECTS_ROOT}/example-app/docker-compose.prod.yml" ]
}

@test "run: .env keeps its owner and mode" {
    runs_deploy
    project example-app
    chmod 640 "${PROJECTS_ROOT}/example-app/.env"
    chown 1234:1234 "${PROJECTS_ROOT}/example-app/.env"
    run "${DEPLOY}" run example-app v2
    [ "$status" -eq 0 ]
    [ "$(stat -c '%u:%g %a' "${PROJECTS_ROOT}/example-app/.env")" = "1234:1234 640" ]
}

@test "run: a failed pull changes nothing" {
    runs_deploy
    project example-app
    echo v2 >"${FAKE_DIR}/fail-pull"
    run "${DEPLOY}" run example-app v2
    [ "$status" -eq 1 ]
    [[ "$output" == *"The running containers were not touched"* ]]
    [ "$(cat "${PROJECTS_ROOT}/example-app/.env")" = $'APP_ENV=production\nAPP_TAG=v1\nDB_PASSWORD=secret' ]
    [ "$(calls)" = "compose pull --quiet tag=v2 file=" ]
    [ ! -e "${DEPLOY_STATE_ROOT}/example-app/previous" ]
    grep -Eq ' DEPLOY_FAILED example-app v2$' "${DEPLOY_STATE_ROOT}/example-app/history.log"
}

@test "run: failed migrations stop before the containers are replaced" {
    runs_deploy
    project example-app --migrate "app migrate"
    echo v2 >"${FAKE_DIR}/fail-run"
    run "${DEPLOY}" run example-app v2
    [ "$status" -eq 1 ]
    [[ "$(calls)" != *"compose up"* ]]
    grep -qx 'APP_TAG=v1' "${PROJECTS_ROOT}/example-app/.env"
}

@test "run: unhealthy containers bring the previous version back" {
    runs_deploy
    project example-app
    echo v2 >"${FAKE_DIR}/fail-up"
    run "${DEPLOY}" run example-app v2
    [ "$status" -eq 1 ]
    [[ "$output" == *"Version v1 is running again"* ]]
    grep -qx 'APP_TAG=v1' "${PROJECTS_ROOT}/example-app/.env"
    [ "$(calls | tail -n 2)" = "compose up -d --remove-orphans --wait --wait-timeout 120 tag=v2 file=
compose up -d --remove-orphans --wait --wait-timeout 120 tag=v1 file=" ]
    [ ! -e "${DEPLOY_STATE_ROOT}/example-app/previous" ]
}

@test "run: the first deploy of a project without a tag in .env" {
    runs_deploy
    mkdir -p "${PROJECTS_ROOT}/example-app"
    "${DEPLOY}" init example-app >/dev/null 2>&1
    run "${DEPLOY}" run example-app v1
    [ "$status" -eq 0 ]
    [ "$(cat "${PROJECTS_ROOT}/example-app/.env")" = "APP_TAG=v1" ]
    file_has_mode "${PROJECTS_ROOT}/example-app/.env" 600
    [ ! -e "${DEPLOY_STATE_ROOT}/example-app/previous" ]
}

@test "run: exactly a project and a valid version, no options" {
    runs_deploy
    project example-app
    local -a args
    for args in "example-app" "example-app v2 v3" "example-app v2 --mode build" "example-app --help" \
        "example-app v2;id" "../example-app v2" "--dry-run example-app v2"; do
        # shellcheck disable=SC2086  # word splitting wanted: a list of arguments
        run "${DEPLOY}" run ${args}
        [ "$status" -ne 0 ]
    done
    [ "$(calls)" = "" ]
    grep -qx 'APP_TAG=v1' "${PROJECTS_ROOT}/example-app/.env"
}

@test "run: a project without a deploy configuration, an edited configuration" {
    runs_deploy
    mkdir -p "${PROJECTS_ROOT}/blog"
    run "${DEPLOY}" run blog v1
    [ "$status" -ne 0 ]
    [[ "$output" == *"not set up"* ]]

    project example-app
    echo 'DEPLOY_MIGRATE_SERVICE=app' >>"${DEPLOY_CONF_DIR}/example-app.env"
    echo 'DEPLOY_MIGRATE_COMMAND=sh -c "id > /tmp/x"' >>"${DEPLOY_CONF_DIR}/example-app.env"
    run "${DEPLOY}" run example-app v2
    [ "$status" -ne 0 ]
    [[ "$output" == *"Fix the value"* ]]
    [ "$(calls)" = "" ]
}

@test "run: .env as a symbolic link is refused" {
    runs_deploy
    project example-app
    mv "${PROJECTS_ROOT}/example-app/.env" "${BATS_TEST_TMPDIR}/elsewhere"
    ln -s "${BATS_TEST_TMPDIR}/elsewhere" "${PROJECTS_ROOT}/example-app/.env"
    run "${DEPLOY}" run example-app v2
    [ "$status" -eq 1 ]
    grep -qx 'APP_TAG=v1' "${BATS_TEST_TMPDIR}/elsewhere"
}

@test "run: a second deploy is refused while one is running; projects do not block each other" {
    runs_deploy
    project example-app
    project blog
    touch "${FAKE_DIR}/block"
    "${DEPLOY}" run example-app v2 >/dev/null 2>&1 &
    local first=$! tries=0
    while [[ ! -e "${FAKE_DIR}/started" && "${tries}" -lt 100 ]]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    [ -e "${FAKE_DIR}/started" ]
    rm -f "${FAKE_DIR}/block"

    run "${DEPLOY}" run example-app v3
    [ "$status" -eq 1 ]
    [[ "$output" == *"already running"* ]]
    run "${DEPLOY}" run blog v2
    [ "$status" -eq 0 ]

    touch "${FAKE_DIR}/finish"
    wait "${first}"
    grep -qx 'APP_TAG=v2' "${PROJECTS_ROOT}/example-app/.env"
}

@test "run (build): checks out the commit, builds, and goes back on failure" {
    runs_deploy
    command -v git >/dev/null 2>&1 || skip "git is not installed"
    local dir="${PROJECTS_ROOT}/example-app" origin="${BATS_TEST_TMPDIR}/origin" first second
    git init -q "${origin}"
    git -C "${origin}" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m one
    first="$(git -C "${origin}" rev-parse HEAD)"
    mkdir -p "${PROJECTS_ROOT}"
    git clone -q "${origin}" "${dir}"
    git -C "${origin}" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m two
    second="$(git -C "${origin}" rev-parse HEAD)"
    printf 'APP_TAG=%s\n' "${first}" >"${dir}/.env"
    "${DEPLOY}" init example-app --mode build >/dev/null 2>&1

    run "${DEPLOY}" run example-app "${second}"
    [ "$status" -eq 0 ]
    [ "$(git -C "${dir}" rev-parse HEAD)" = "${second}" ]
    [ "$(calls | head -n 1)" = "compose build tag=${second} file=" ]
    [ "$(cat "${DEPLOY_STATE_ROOT}/example-app/previous")" = "${first}" ]

    run "${DEPLOY}" run example-app 0000000000000000000000000000000000000000
    [ "$status" -eq 1 ]
    [ "$(git -C "${dir}" rev-parse HEAD)" = "${second}" ]

    echo "${first}" >"${FAKE_DIR}/fail-build"
    run "${DEPLOY}" run example-app "${first}"
    [ "$status" -eq 1 ]
    [ "$(git -C "${dir}" rev-parse HEAD)" = "${second}" ]
    grep -qx "APP_TAG=${second}" "${dir}/.env"
}

# --- rollback and status ----------------------------------------------------

@test "rollback: deploys the previous version" {
    runs_deploy
    project example-app
    run "${DEPLOY}" rollback example-app
    [ "$status" -ne 0 ]
    [[ "$output" == *"No previous version"* ]]

    "${DEPLOY}" run example-app v2 >/dev/null
    run "${DEPLOY}" rollback example-app
    [ "$status" -eq 0 ]
    grep -qx 'APP_TAG=v1' "${PROJECTS_ROOT}/example-app/.env"
    [ "$(cat "${DEPLOY_STATE_ROOT}/example-app/previous")" = "v2" ]
}

@test "status: deployed and previous version, the result of the last deploy" {
    runs_deploy
    run "${DEPLOY}" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"No project has a deploy set up"* ]]

    project example-app
    project blog
    "${DEPLOY}" run example-app v2 >/dev/null
    run "${DEPLOY}" status
    [ "$status" -eq 0 ]
    [[ "${lines[1]}" =~ ^blog\ +image\ +v1\ +-\ +never$ ]]
    [[ "${lines[2]}" =~ ^example-app\ +image\ +v2\ +v1\ +ok\ [0-9TZ:-]+\ v2$ ]]

    echo v3 >"${FAKE_DIR}/fail-pull"
    "${DEPLOY}" run example-app v3 >/dev/null 2>&1 || true
    run "${DEPLOY}" status example-app
    [ "$status" -eq 1 ]
    [[ "${lines[1]}" =~ ^example-app\ +image\ +v2\ +v1\ +FAILED\ [0-9TZ:-]+\ v3$ ]]
}

# --- the forced command of a deploy key -------------------------------------

@test "ssh: the client's command is one version, passed to sudo; anything else is refused" {
    cat >"${FAKE_DIR}/bin/sudo" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${FAKE_DIR}/sudo-call"
FAKE
    chmod +x "${FAKE_DIR}/bin/sudo"
    SSH_ORIGINAL_COMMAND="3f2a9c1d4b5e" run "${DEPLOY}" ssh example-app
    [ "$status" -eq 0 ]
    [ "$(cat "${FAKE_DIR}/sudo-call")" = "-n ${REPO_ROOT}/bin/vps-stack deploy run example-app 3f2a9c1d4b5e" ]

    rm -f "${FAKE_DIR}/sudo-call"
    local value
    for value in "" "bash -i" "vps-stack deploy run shop v1" 'x; touch /tmp/pwned' 'x$(id)' "scp -t /etc" \
        "v1 --help" "--help"; do
        SSH_ORIGINAL_COMMAND="${value}" run "${DEPLOY}" ssh example-app
        [ "$status" -ne 0 ]
        [[ "$output" == *"can only deploy a version of example-app"* ]]
    done
    [ ! -e "${FAKE_DIR}/sudo-call" ]
}
