#!/usr/bin/env bash
# End-to-end test of vps-stack on a FRESH, DISPOSABLE server.
#
# Runs on your computer, not on the server: only from outside can it check
# what matters most (the new administrator logs in with the key, the old
# doors are closed, the new SSH port answers). It drives the real commands
# over SSH and answers their questions with expect; vps-stack itself has no
# test shortcuts. Procedure and requirements: docs/testing.md.
#
# It changes SSH and the firewall of the server. Never point it at a server
# you care about.
set -uo pipefail

REPO_URL="https://github.com/forkacper/vps-stack.git"
ADMIN="sysadmin"
SITE_PORT_TEST_IMAGE="nginx:1.27-alpine"
STAGING_CA="https://acme-staging-v02.api.letsencrypt.org/directory"

ADDRESS=""
KEY=""
INIT_USER="ubuntu"
REF=""
SITE_HOST=""
STATUS_HOST=""
EMAIL=""
NEW_PORT=2222
REPORT_DIR="${PWD}/e2e-reports"

usage() {
    cat <<USAGE
Usage: tests/e2e/run.sh <server-address> --key <private key> [options]

End-to-end test of vps-stack on a fresh, disposable server. Run it from your
computer. It provisions the server, changes its SSH port and firewall, and
tests backup, sites and the status page. Never use it on a server you care
about.

Required:
  <server-address>     public IPv4 address of the fresh server
  --key <file>         private key that logs in to the default account
                       (its .pub must lie next to it)

Options:
  --user <name>        default account of the image (default: ubuntu); it
                       needs passwordless sudo, as on cloud images
  --ref <tag|commit>   vps-stack version to test (default: newest tag)
  --site <host>        hostname for add-site, with A/AAAA records on the server
  --status <host>      hostname for the status page, same requirement
  --email <address>    ACME e-mail (staging CA, no real certificates)
  --ssh-port <port>    port for the SSH port change (default: 2222)
  --report-dir <dir>   where the report and the log go (default: ./e2e-reports)

Without --site/--status/--email the site and status page steps are skipped.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key) KEY="$2"; shift ;;
        --user) INIT_USER="$2"; shift ;;
        --ref) REF="$2"; shift ;;
        --site) SITE_HOST="$2"; shift ;;
        --status) STATUS_HOST="$2"; shift ;;
        --email) EMAIL="$2"; shift ;;
        --ssh-port) NEW_PORT="$2"; shift ;;
        --report-dir) REPORT_DIR="$2"; shift ;;
        -h | --help) usage; exit 0 ;;
        -*) usage >&2; printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
        *) [[ -z "${ADDRESS}" ]] || { usage >&2; exit 2; }; ADDRESS="$1" ;;
    esac
    shift
done
[[ -n "${ADDRESS}" && -n "${KEY}" ]] || { usage >&2; exit 2; }

# --- output and report ------------------------------------------------------

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${REPORT_DIR}"
REPORT="${REPORT_DIR}/report-${STAMP}.md"
LOG="${REPORT_DIR}/log-${STAMP}.txt"
KNOWN_HOSTS="${REPORT_DIR}/known_hosts-${STAMP}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

RESULTS=()
FAILED=0
FACTS=()

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "${LOG}" >&2; }

# record <PASS|FAIL|SKIP> <check> [detail]
record() {
    RESULTS+=("| $1 | $2 | ${3:-} |")
    [[ "$1" == "FAIL" ]] && FAILED=$((FAILED + 1))
    log "$1  $2${3:+ ($3)}"
    write_report
}
pass() { record PASS "$@"; }
fail() { record FAIL "$@"; }
skip() { record SKIP "$@"; }

# assert <name> <detail> <command...>: PASS or FAIL by the command, with the
# detail in the report either way.
assert() {
    local name="$1" detail="$2"
    shift 2
    if "$@"; then pass "${name}" "${detail}"; else fail "${name}" "${detail}"; fi
}
is() { [[ "$1" == "$2" ]]; }
has() { [[ "$1" == *"$2"* ]]; }

# check <name> <command...>: PASS when the command succeeds.
check() {
    local name="$1"
    shift
    if "$@" >>"${LOG}" 2>&1; then pass "${name}"; else fail "${name}"; fi
}

# critical <name> <command...>: like check, but stops the run on failure.
critical() {
    local name="$1"
    shift
    if "$@" >>"${LOG}" 2>&1; then
        pass "${name}"
    else
        fail "${name}" "critical: the run stops here; see the log"
        log "Stopped. Report: ${REPORT}"
        exit 1
    fi
}

write_report() {
    {
        printf '# vps-stack end-to-end test\n\n'
        printf -- '- Started: %s (UTC)\n- Server: %s\n- vps-stack: %s\n' "${STAMP}" "${ADDRESS}" "${REF:-?}"
        for fact in "${FACTS[@]+"${FACTS[@]}"}"; do
            printf -- '- %s\n' "${fact}"
        done
        printf '\n| Result | Check | Detail |\n|---|---|---|\n'
        printf '%s\n' "${RESULTS[@]+"${RESULTS[@]}"}"
        printf '\nFailures: %s. Full log: %s\n' "${FAILED}" "$(basename "${LOG}")"
    } >"${REPORT}"
}

# --- SSH --------------------------------------------------------------------

SSH_OPTS=(-o BatchMode=yes -o IdentitiesOnly=yes -i "${KEY}"
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${KNOWN_HOSTS}"
    -o ConnectTimeout=15 -o ServerAliveInterval=15 -o LogLevel=ERROR)
ADMIN_PORT=22
ADMIN_PW=""

# ssh_as <user> <port> <command>
ssh_as() {
    local user="$1" port="$2"
    shift 2
    ssh "${SSH_OPTS[@]}" -p "${port}" "${user}@${ADDRESS}" "$@"
}
on_init() { ssh_as "${INIT_USER}" 22 "$@"; }
on_admin() { ssh_as "${ADMIN}" "${ADMIN_PORT}" "$@"; }

# as_root <command string>: as the administrator through sudo, with the
# password on stdin. Output goes to stdout.
as_root() {
    printf '%s\n' "${ADMIN_PW}" | on_admin "sudo -S -p '' bash -c $(printf '%q' "$1")"
}

# root_script: run the script given on stdin as root.
root_script() {
    local file="/tmp/e2e-$$-${RANDOM}.sh"
    on_admin "cat > ${file}" || return 1
    as_root "bash ${file}; rc=\$?; rm -f ${file}; exit \${rc}"
}

wait_for_ssh() {
    local i
    for ((i = 0; i < 60; i++)); do
        on_admin true >/dev/null 2>&1 && return 0
        sleep 5
    done
    return 1
}

# denied <user> <port> [ssh options...]: the login is refused, and the server
# offers only public keys.
denied() {
    local user="$1" port="$2" out
    shift 2
    out="$(ssh "${SSH_OPTS[@]}" "$@" -p "${port}" "${user}@${ADDRESS}" true 2>&1)" && return 1
    printf '%s\n' "${out}"
    [[ "${out}" == *"Permission denied (publickey)"* ]]
}

# --- expect -----------------------------------------------------------------

# A helper that tests a new session as the administrator (key login and
# sudo) on the port given as its argument. expect calls it before YES.
SECOND_SESSION="${WORK}/second-session"
cat >"${SECOND_SESSION}" <<HELPER
#!/usr/bin/env bash
printf '%s\n' "\${E2E_ADMIN_PW}" | ssh $(printf '%q ' "${SSH_OPTS[@]}") -p "\$1" ${ADMIN}@${ADDRESS} "sudo -S -p '' -v && echo SECOND_SESSION_OK"
HELPER
chmod 700 "${SECOND_SESSION}"

cat >"${WORK}/provision.exp" <<'EXPECT'
set timeout 2400
set pw $env(E2E_ADMIN_PW)
spawn {*}$argv
expect {
    "Continue at your own risk?" { send "y\r"; exp_continue }
    "Start provisioning?" { send "y\r"; exp_continue }
    "New password:" { send "$pw\r"; exp_continue }
    "Retype new password:" { send "$pw\r"; exp_continue }
    "Type YES to continue:" {
        if {[catch {exec $env(E2E_SECOND_SESSION) 22 2>@1} out] || ![string match "*SECOND_SESSION_OK*" $out]} {
            puts "\nE2E: the second session test FAILED: $out"
            send "NO\r"
        } else {
            puts "\nE2E: second session as the administrator works"
            send "YES\r"
        }
        exp_continue
    }
    "Enable the firewall?" { send "y\r"; exp_continue }
    "Remove these packages?" { send "n\r"; exp_continue }
    timeout { puts "\nE2E: timeout"; exit 99 }
    eof
}
catch wait result
exit [lindex $result 3]
EXPECT

# ssh-port: confirm (test the new port, then YES) or rollback (no YES).
cat >"${WORK}/ssh-port.exp" <<'EXPECT'
set timeout 300
set pw $env(E2E_ADMIN_PW)
set mode $env(E2E_MODE)
set new_port $env(E2E_NEW_PORT)
spawn {*}$argv
expect {
    -re {\[sudo[^]]*\] [Pp]assword} { send "$pw\r"; exp_continue }
    "Continue at your own risk?" { send "y\r"; exp_continue }
    "Change the SSH port" { send "y\r"; exp_continue }
    "Type YES to continue:" {
        if {$mode eq "rollback"} {
            send "no\r"
        } elseif {[catch {exec $env(E2E_SECOND_SESSION) $new_port 2>@1} out] || ![string match "*SECOND_SESSION_OK*" $out]} {
            puts "\nE2E: the new port does not work: $out"
            send "no\r"
        } else {
            puts "\nE2E: new port works"
            send "YES\r"
        }
        exp_continue
    }
    "Roll back the port change" { send "y\r"; exp_continue }
    timeout { puts "\nE2E: timeout"; exit 99 }
    eof
}
catch wait result
exit [lindex $result 3]
EXPECT

# run_expect <script> <ssh command...>: output into the log.
run_expect() {
    local script="$1"
    shift
    E2E_ADMIN_PW="${ADMIN_PW}" E2E_SECOND_SESSION="${SECOND_SESSION}" \
        expect -f "${script}" "$@" >>"${LOG}" 2>&1
}

# --- small checks -----------------------------------------------------------

port22_closed() {
    ! ssh "${SSH_OPTS[@]}" -o ConnectTimeout=8 -p 22 "${ADMIN}@${ADDRESS}" true
}

proxy_has_ipv6() {
    [[ "$(as_root "docker network inspect -f '{{.EnableIPv6}}' proxy")" == "true" ]]
}

# --- steps ------------------------------------------------------------------

step_preflight() {
    local tool answer
    for tool in ssh scp expect curl git jq openssl; do
        command -v "${tool}" >/dev/null || { printf 'Missing tool: %s\n' "${tool}" >&2; exit 2; }
    done
    [[ -r "${KEY}" && -r "${KEY}.pub" ]] || { printf 'Cannot read %s and %s.pub\n' "${KEY}" "${KEY}" >&2; exit 2; }
    if [[ -z "${REF}" ]]; then
        REF="$(git ls-remote --tags --refs --sort=-v:refname "${REPO_URL}" 'v*' | head -n 1 | sed 's|.*refs/tags/||')"
    fi
    [[ -n "${REF}" ]] || { printf 'Cannot determine the newest release; give --ref.\n' >&2; exit 2; }
    [[ "${NEW_PORT}" =~ ^[0-9]+$ && "${NEW_PORT}" -ne 22 ]] || { printf -- '--ssh-port must be a port other than 22.\n' >&2; exit 2; }

    cat <<WARNING >&2

This test provisions ${ADDRESS}: it disables password and root login over SSH,
blocks the account '${INIT_USER}' from SSH, enables a firewall and moves SSH to
port ${NEW_PORT}. Use only a fresh server you can throw away.
vps-stack ${REF}. Report: ${REPORT}

WARNING
    read -r -p "Type the server address to continue: " answer
    [[ "${answer}" == "${ADDRESS}" ]] || { printf 'Aborted.\n' >&2; exit 1; }
    ADMIN_PW="$(head -c 18 /dev/urandom | base64 | tr '+/' 'xy')"
    # Kept for looking into the server after a failure; e2e-reports/ is
    # ignored by git.
    (umask 077 && printf '%s\n' "${ADMIN_PW}" >"${REPORT_DIR}/sysadmin-password-${STAMP}")
    write_report
}

step_facts() {
    local facts
    critical "Connect as ${INIT_USER} with the key" on_init true
    critical "${INIT_USER} has passwordless sudo" on_init "sudo -n true"
    # shellcheck disable=SC2016  # expanded on the server, not here
    facts="$(on_init 'set -e
        . /etc/os-release; echo "System: ${PRETTY_NAME}"
        echo "Kernel: $(uname -r)"
        echo "OpenSSH: $(ssh -V 2>&1 | cut -d, -f1)"
        echo "ssh.socket: $(systemctl is-active ssh.socket 2>/dev/null || true)"
        echo "sshd_config.d: $(ls /etc/ssh/sshd_config.d/ 2>/dev/null | tr "\n" " ")"
        echo "IPv6: $(ip -6 -o addr show scope global | awk "{print \$4}" | head -n 1)"
        echo "restic candidate: $(apt-cache policy restic | awk "/Candidate/ {print \$2}")"
        echo "fail2ban candidate: $(apt-cache policy fail2ban | awk "/Candidate/ {print \$2}")"')"
    while IFS= read -r line; do
        [[ -n "${line}" ]] && FACTS+=("${line}")
    done <<<"${facts}"
    SERVER_IPV6="$(sed -n 's|^IPv6: \([^/]*\).*|\1|p' <<<"${facts}")"
    write_report
}

step_install() {
    critical "Clone vps-stack ${REF}" on_init "set -e
        for i in 1 2 3 4 5 6 7 8 9 10; do command -v git >/dev/null && break
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git && break; sleep 15; done
        sudo rm -rf /opt/vps-stack
        sudo git clone -q ${REPO_URL} /opt/vps-stack
        sudo git -C /opt/vps-stack -c advice.detachedHead=false checkout -q ${REF}
        sudo git -C /opt/vps-stack log --oneline -1"
    FACTS+=("Commit: $(on_init "sudo git -C /opt/vps-stack rev-parse --short HEAD")")
    critical "Upload the public key" scp "${SSH_OPTS[@]}" -P 22 "${KEY}.pub" "${INIT_USER}@${ADDRESS}:admin.pub"
    critical "Write stack.env and proxy.env" on_init "set -e
        cp /opt/vps-stack/config/stack.env.example ~/stack.env
        cp /opt/vps-stack/config/proxy.env.example ~/proxy.env
        sed -i \"s|^ADMIN_SSH_PUBKEY_FILE=.*|ADMIN_SSH_PUBKEY_FILE=\$HOME/admin.pub|\" ~/stack.env
        sed -i 's|^ACME_EMAIL=.*|ACME_EMAIL=${EMAIL:-admin@example.com}|' ~/proxy.env
        sed -i 's|^ACME_CA=.*|ACME_CA=${STAGING_CA}|' ~/proxy.env"
}

step_provision() {
    local out
    out="$(on_init "cd /opt/vps-stack && sudo ./bin/vps-stack provision --config ~/stack.env --dry-run" 2>&1)"
    printf '%s\n' "${out}" >>"${LOG}"
    if [[ "${out}" == *"Dry run finished: nothing was changed"* ]]; then pass "provision --dry-run"; else fail "provision --dry-run"; fi
    critical "Nothing changed by the dry run" on_init "test ! -e /etc/vps-stack && test ! -e /etc/ssh/sshd_config.d/00-hardening.conf"

    critical "provision (second session tested before YES)" \
        run_expect "${WORK}/provision.exp" ssh "${SSH_OPTS[@]}" -tt -p 22 "${INIT_USER}@${ADDRESS}" \
        "cd /opt/vps-stack && sudo ./bin/vps-stack provision --config ~/stack.env"
    critical "Administrator logs in with the key and uses sudo" as_root true
}

step_doors() {
    check "${INIT_USER} can no longer log in over SSH" denied "${INIT_USER}" "${ADMIN_PORT}"
    check "Password login is refused" denied "${ADMIN}" "${ADMIN_PORT}" -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive
    check "root login is refused" denied root "${ADMIN_PORT}"
}

# verify_clean <name>: verify reports no error.
verify_clean() {
    local out
    out="$(as_root "vps-stack verify" 2>&1)"
    printf '%s\n' "${out}" >>"${LOG}"
    if [[ "${out}" == *"Total: 0 errors"* ]]; then
        pass "$1" "$(grep -o 'Total: .*' <<<"${out}")"
    else
        fail "$1" "$(grep -E '^ERROR|Total:' <<<"${out}" | tr '\n' ' ')"
    fi
}

step_reboot() {
    local name="$1"
    as_root "systemctl reboot" >/dev/null 2>&1 || true
    sleep 20
    critical "${name}: the server is back" wait_for_ssh
    verify_clean "${name}: verify"
}

step_idempotency() {
    local out
    out="$(as_root "vps-stack provision --yes" 2>&1)"
    printf '%s\n' "${out}" >>"${LOG}"
    if [[ "${out}" == *"Provisioning finished."* && "${out}" != *"written:"* ]]; then
        pass "Second provision changes nothing"
    else
        fail "Second provision changes nothing" "$(grep -E '^written:|ERROR' <<<"${out}" | tr '\n' ' ')"
    fi
}

step_ssh_port() {
    local listen
    E2E_MODE=confirm E2E_NEW_PORT="${NEW_PORT}" run_expect "${WORK}/ssh-port.exp" \
        ssh "${SSH_OPTS[@]}" -tt -p "${ADMIN_PORT}" "${ADMIN}@${ADDRESS}" "sudo vps-stack ssh-port ${NEW_PORT}"
    if ssh_as "${ADMIN}" "${NEW_PORT}" true >/dev/null 2>&1; then
        ADMIN_PORT="${NEW_PORT}"
        pass "SSH port changed to ${NEW_PORT}"
    else
        fail "SSH port changed to ${NEW_PORT}" "critical: the run stops here; port 22 should still work"
        exit 1
    fi
    check "Port 22 is closed" port22_closed
    listen="$(as_root "systemctl show ssh.socket -p Listen 2>/dev/null; ufw status; grep '^port' /etc/fail2ban/jail.local; grep '^SSH_PORT' /etc/vps-stack/stack.env" 2>&1)"
    printf '%s\n' "${listen}" >>"${LOG}"
    if [[ "${listen}" == *"SSH_PORT=${NEW_PORT}"* && "${listen}" == *"port = ${NEW_PORT}"* && ! "${listen}" =~ (^|[[:space:]])22/tcp ]]; then
        pass "stack.env, fail2ban and ufw follow the new port"
    else
        fail "stack.env, fail2ban and ufw follow the new port"
    fi
    step_reboot "Reboot after the port change"

    local rollback=$((NEW_PORT + 1))
    E2E_MODE=rollback E2E_NEW_PORT="${rollback}" run_expect "${WORK}/ssh-port.exp" \
        ssh "${SSH_OPTS[@]}" -tt -p "${ADMIN_PORT}" "${ADMIN}@${ADDRESS}" "sudo vps-stack ssh-port ${rollback}"
    listen="$(as_root "systemctl show ssh.socket -p Listen 2>/dev/null; ss -tln; ufw status" 2>&1)"
    printf '%s\n' "${listen}" >>"${LOG}"
    if on_admin true && [[ "${listen}" != *":${rollback} "* && "${listen}" != *"${rollback}/tcp"* ]]; then
        pass "ssh-port without YES rolls back"
    else
        fail "ssh-port without YES rolls back"
    fi
}

step_backup() {
    local out
    out="$(root_script <<'SCRIPT' 2>&1
set -e
install -d /srv/e2e-app/storage/uploads
cd /srv/e2e-app
cat > docker-compose.yml <<EOF
services:
  db:
    image: mariadb:11.4
    restart: unless-stopped
    mem_limit: 512m
    env_file: .env
    volumes:
      - db-data:/var/lib/mysql
volumes:
  db-data:
EOF
printf 'MARIADB_ROOT_PASSWORD=%s\nMARIADB_DATABASE=e2e_app\nDB_BACKUP_PASSWORD=%s\n' "$(openssl rand -hex 16)" "$(openssl rand -hex 16)" > .env
chmod 600 .env
for i in 1 2 3; do head -c 50000 /dev/urandom > storage/uploads/photo-$i.jpg; done
docker compose up -d --quiet-pull >/dev/null 2>&1
set -a; . ./.env; set +a
for i in $(seq 1 30); do docker compose exec -T db mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e 'SELECT 1' >/dev/null 2>&1 && break; sleep 2; done
docker compose exec -T db mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
  CREATE USER 'backup'@'%' IDENTIFIED BY '$DB_BACKUP_PASSWORD';
  GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON e2e_app.* TO 'backup'@'%';
  CREATE TABLE e2e_app.orders (id INT AUTO_INCREMENT PRIMARY KEY, note VARCHAR(200));
  INSERT INTO e2e_app.orders (note) VALUES ('first'), ('second'), ('third');"
vps-stack backup init system
vps-stack backup init e2e-app
install -m 700 /opt/vps-stack/examples/backup-hook-mysql.sh.example /etc/vps-stack/hooks/e2e-app/db.sh
sed -i 's/^DB_NAME=.*/DB_NAME="e2e_app"/' /etc/vps-stack/hooks/e2e-app/db.sh
install -m 700 /opt/vps-stack/examples/backup-hook-files.sh.example /etc/vps-stack/hooks/e2e-app/files.sh
vps-stack backup run
echo "E2E_RUN1_OK"
docker compose exec -T db mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "INSERT INTO e2e_app.orders (note) VALUES ('fourth');"
size1=$(du -sk /srv/backups/e2e-app | cut -f1)
vps-stack backup run e2e-app
size2=$(du -sk /srv/backups/e2e-app | cut -f1)
echo "E2E_GROWTH_KB=$((size2 - size1))"
vps-stack backup list
SCRIPT
)"
    printf '%s\n' "${out}" >>"${LOG}"
    if [[ "${out}" == *"E2E_RUN1_OK"* && "${out}" == *"BACKUP_OK system"* && "${out}" == *"BACKUP_OK e2e-app"* ]]; then
        pass "backup init and run (system, project)"
    else
        fail "backup init and run (system, project)"
        return 0
    fi
    pass "Second backup after a small change" "$(grep -o 'E2E_GROWTH_KB=[0-9-]*' <<<"${out}") of growth"

    out="$(root_script <<'SCRIPT' 2>&1
set -e
rm -rf /tmp/e2e-restore /tmp/e2e-one
vps-stack backup restore e2e-app --target /tmp/e2e-restore >/dev/null
echo "E2E_DUMPS=$(ls /tmp/e2e-restore/srv/backup-staging/e2e-app/db/ | wc -l)"
docker rm -f e2e-restore-db >/dev/null 2>&1 || true
docker run -d --name e2e-restore-db -e MARIADB_ROOT_PASSWORD=restore-test-only mariadb:11.4 >/dev/null
for i in $(seq 1 30); do docker exec e2e-restore-db mariadb -prestore-test-only -e 'SELECT 1' >/dev/null 2>&1 && break; sleep 2; done
docker exec e2e-restore-db mariadb -prestore-test-only -e 'CREATE DATABASE restore_test'
cat /tmp/e2e-restore/srv/backup-staging/e2e-app/db/*.sql | docker exec -i e2e-restore-db mariadb -prestore-test-only restore_test
echo "E2E_ROWS=$(docker exec e2e-restore-db mariadb -prestore-test-only -N -e 'SELECT GROUP_CONCAT(note ORDER BY id) FROM restore_test.orders')"
docker rm -f e2e-restore-db >/dev/null
vps-stack backup restore e2e-app --path /srv/e2e-app/storage/uploads/photo-2.jpg --target /tmp/e2e-one >/dev/null
cmp /tmp/e2e-one/srv/e2e-app/storage/uploads/photo-2.jpg /srv/e2e-app/storage/uploads/photo-2.jpg && echo "E2E_FILE_SAME"
rm -f /root/e2e-app.tar
vps-stack backup export e2e-app --output /root/e2e-app.tar >/dev/null 2>&1
tar -tf /root/e2e-app.tar | grep -c -E 'e2e_app-.*\.sql|srv/e2e-app/.env|photo-[123]\.jpg' | sed 's/^/E2E_EXPORT_ITEMS=/'
rm -rf /tmp/e2e-restore /tmp/e2e-one /root/e2e-app.tar
set -a; . /etc/vps-stack/backup/system.env; set +a
echo "E2E_SYSTEM_SECRETS=$(restic ls latest 2>/dev/null | grep -c '/etc/vps-stack/backup' || true)"
SCRIPT
)"
    printf '%s\n' "${out}" >>"${LOG}"
    assert "Snapshot holds exactly one dump" "" has "${out}" "E2E_DUMPS=1"
    assert "Restored dump imports with every row" "$(grep -o 'E2E_ROWS=.*' <<<"${out}")" has "${out}" "E2E_ROWS=first,second,third,fourth"
    assert "restore --path brings back an identical file" "" has "${out}" "E2E_FILE_SAME"
    assert "export holds the dump, .env and the files" "$(grep -o 'E2E_EXPORT_ITEMS=.*' <<<"${out}")" has "${out}" "E2E_EXPORT_ITEMS=5"
    assert "system snapshot has no backup passwords" "" has "${out}" "E2E_SYSTEM_SECRETS=0"

    out="$(root_script <<'SCRIPT' 2>&1
sed -i 's/^DB_NAME=.*/DB_NAME="does_not_exist"/' /etc/vps-stack/hooks/e2e-app/db.sh
vps-stack backup run >/tmp/e2e-broken.log 2>&1; echo "E2E_BROKEN_EXIT=$?"
grep -q 'backup e2e-app: ERROR' /tmp/e2e-broken.log && echo "E2E_BROKEN_REPORTED"
tail -n 20 /tmp/e2e-broken.log | grep -q ' BACKUP_OK system$' && echo "E2E_SYSTEM_STILL_OK"
sed -i 's/^DB_NAME=.*/DB_NAME="e2e_app"/' /etc/vps-stack/hooks/e2e-app/db.sh
vps-stack backup run e2e-app >/dev/null 2>&1 && echo "E2E_FIXED_OK"
ls /srv/backup-staging/e2e-app/ | tr '\n' ' ' | sed 's/^/E2E_STAGING=/'
echo
vps-stack backup setup >/dev/null && test -f /etc/cron.d/vps-stack-backup && echo "E2E_CRON"
rm -f /tmp/e2e-broken.log
SCRIPT
)"
    printf '%s\n' "${out}" >>"${LOG}"
    if [[ "${out}" == *"E2E_BROKEN_EXIT=1"* && "${out}" == *"E2E_BROKEN_REPORTED"* && "${out}" == *"E2E_SYSTEM_STILL_OK"* ]]; then
        pass "A broken hook fails the run, other groups still back up"
    else
        fail "A broken hook fails the run, other groups still back up"
    fi
    assert "Backup works again after fixing the hook" "" has "${out}" "E2E_FIXED_OK"
    assert "No empty hook directories in staging" "$(grep -o 'E2E_STAGING=.*' <<<"${out}")" has "${out}" "E2E_STAGING=db "
    assert "backup setup installs the cron job" "" has "${out}" "E2E_CRON"
}

# https_code <host> [curl options...]: HTTP code from this computer.
https_code() {
    local host="$1"
    shift
    curl -sk -o /dev/null --max-time 15 -w '%{http_code}' "$@" "https://${host}/"
}

# cert_issuer <host>: waits up to 2 minutes for a staging certificate of the
# host and prints its issuer (empty when there is none).
cert_issuer() {
    local i issuer=""
    for ((i = 0; i < 24; i++)); do
        issuer="$(echo | openssl s_client -connect "${ADDRESS}:443" -servername "$1" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)"
        [[ "${issuer}" == *STAGING* ]] && break
        sleep 5
    done
    printf '%s\n' "${issuer}"
}

step_sites() {
    local out issuer
    if [[ -z "${SITE_HOST}" || -z "${STATUS_HOST}" || -z "${EMAIL}" ]]; then
        skip "Sites and status page" "--site, --status and --email not given"
        return 1
    fi
    out="$(as_root "vps-stack check-dns ${SITE_HOST} ${STATUS_HOST}" 2>&1)"
    printf '%s\n' "${out}" >>"${LOG}"
    if [[ "$(grep -c '^OK' <<<"${out}")" -ne 2 ]]; then
        fail "DNS of ${SITE_HOST} and ${STATUS_HOST} points at the server" "$(grep -v '^Server address' <<<"${out}" | tr '\n' ' ')"
        skip "Sites and status page" "fix the DNS records and run again"
        return 1
    fi
    pass "DNS of ${SITE_HOST} and ${STATUS_HOST} points at the server"
    check "Proxy network has IPv6" proxy_has_ipv6

    root_script <<SCRIPT >>"${LOG}" 2>&1
set -e
install -d /srv/e2e-web
cat > /srv/e2e-web/docker-compose.yml <<EOF
services:
  web:
    image: ${SITE_PORT_TEST_IMAGE}
    container_name: e2e-web
    restart: unless-stopped
    mem_limit: 64m
    networks:
      - proxy
networks:
  proxy:
    external: true
EOF
cd /srv/e2e-web && docker compose up -d --quiet-pull
vps-stack add-site ${SITE_HOST} e2e-web:80 --yes
SCRIPT
    issuer="$(cert_issuer "${SITE_HOST}")"
    assert "add-site: staging certificate issued" "${issuer:-no certificate}" has "${issuer}" "STAGING"
    assert "add-site: HTTPS answers 200" "" is "$(https_code "${SITE_HOST}")" "200"
    assert "HTTP redirects to HTTPS" "" is "$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' "http://${SITE_HOST}/")" "308"

    as_root "vps-stack remove-site ${SITE_HOST} --yes" >>"${LOG}" 2>&1
    assert "remove-site: the site stops answering" "" is "$(https_code "${SITE_HOST}")" "000"
    as_root "vps-stack add-site ${SITE_HOST} e2e-web:80 --yes" >>"${LOG}" 2>&1
    sleep 3
    assert "add-site again: works at once" "" is "$(https_code "${SITE_HOST}")" "200"
    out="$(as_root "vps-stack proxy logs 2>&1 | grep -c 'certificate obtained successfully.*${SITE_HOST}' || true")"
    assert "add-site again: the stored certificate is reused" "obtained ${out} times" is "${out}" "1"
    return 0
}

step_status_page() {
    local out login password old_password bad_password ban_ip i code
    out="$(as_root "vps-stack monitor enable ${STATUS_HOST} --no-dns-check --yes" 2>&1)"
    printf '%s\n' "${out}" | sed 's/^\(  Password: \).*/\1<hidden>/' >>"${LOG}"
    login="$(sed -n 's/^  Login: *\([^ ]*\)$/\1/p' <<<"${out}" | tail -n 1)"
    password="$(sed -n 's/^  Password: *\([^ ]*\)$/\1/p' <<<"${out}" | tail -n 1)"
    if [[ -z "${login}" || -z "${password}" ]]; then
        fail "monitor enable" "no credentials in the output"
        return 0
    fi
    pass "monitor enable"
    # The certificate is requested only now; without it TLS fails (000).
    out="$(cert_issuer "${STATUS_HOST}")"
    assert "Status page: staging certificate issued" "${out:-no certificate}" has "${out}" "STAGING"
    assert "Status page asks for the login" "" is "$(https_code "${STATUS_HOST}")" "401"
    assert "Status page opens with the password" "" is "$(https_code "${STATUS_HOST}" -u "${login}:${password}")" "200"
    out="$(curl -sk --max-time 15 -u "${login}:${password}" "https://${STATUS_HOST}/status.json")"
    if jq -e '.containers | map(.name) | index("e2e-web") != null' >/dev/null 2>&1 <<<"${out}" &&
        ! grep -q 'MARIADB_ROOT_PASSWORD\|DB_BACKUP_PASSWORD' <<<"${out}"; then
        pass "status.json lists the containers and no environment variables"
    else
        fail "status.json lists the containers and no environment variables"
    fi

    # The client address: this computer over IPv4, the server itself over IPv6.
    https_code "${STATUS_HOST}" -4 >/dev/null
    out="$(as_root "tail -n 1 /var/log/vps-stack-monitor/access.log | jq -r .request.remote_ip")"
    assert "IPv4 client address reaches Caddy" "${out}" is "${out}" "$(curl -s -4 --max-time 10 https://api.ipify.org)"
    if [[ -n "${SERVER_IPV6:-}" ]]; then
        out="$(as_root "curl -6 -sk -o /dev/null https://${STATUS_HOST}/; tail -n 1 /var/log/vps-stack-monitor/access.log | jq -r .request.remote_ip")"
        assert "IPv6 client address reaches Caddy" "${out} (expected ${SERVER_IPV6})" is "${out}" "${SERVER_IPV6}"
    else
        skip "IPv6 client address reaches Caddy" "the server has no IPv6"
    fi

    # fail2ban: this computer fails to log in until it is banned (from the
    # server itself it would never be: fail2ban ignores the server's own
    # addresses, ignoreself). The ban is only in Caddy and only for the
    # status page, so SSH and the other site keep working for this computer.
    ban_ip="$(curl -s -4 --max-time 10 https://api.ipify.org)"
    bad_password="not-${password}"
    for i in 1 2 3 4 5 6; do
        https_code "${STATUS_HOST}" -4 -u "${login}:${bad_password}" >/dev/null
        sleep 2
    done
    for ((i = 0; i < 20; i++)); do
        as_root "grep -qx '${ban_ip}' /etc/vps-stack/monitor-banned.list" >/dev/null 2>&1 && break
        sleep 3
    done
    code="$(https_code "${STATUS_HOST}" -4)"
    assert "fail2ban bans after failed logins (status page closed)" "code ${code}" is "${code}" "000"
    code="$(https_code "${SITE_HOST}" -4)"
    assert "The ban does not touch other sites" "code ${code}" is "${code}" "200"
    as_root "fail2ban-client set vps-stack-monitor unbanip ${ban_ip}" >>"${LOG}" 2>&1
    sleep 5
    code="$(https_code "${STATUS_HOST}" -4)"
    assert "unban opens the status page again" "code ${code}" is "${code}" "401"

    old_password="${password}"
    out="$(as_root "vps-stack monitor password --yes" 2>&1)"
    password="$(sed -n 's/^  Password: *\([^ ]*\)$/\1/p' <<<"${out}" | tail -n 1)"
    if [[ -n "${password}" && "$(https_code "${STATUS_HOST}" -u "${login}:${password}")" == "200" &&
        "$(https_code "${STATUS_HOST}" -u "${login}:${old_password}")" == "401" ]]; then
        pass "monitor password: the new one works, the old one does not"
    else
        fail "monitor password: the new one works, the old one does not"
    fi
    out="$(as_root "vps-stack monitor refresh --yes" 2>&1)"
    printf '%s\n' "${out}" >>"${LOG}"
    if [[ "${out}" == *"The password did not change"* && "$(https_code "${STATUS_HOST}" -u "${login}:${password}")" == "200" ]]; then
        pass "monitor refresh keeps the password"
    else
        fail "monitor refresh keeps the password"
    fi
    STATUS_LOGIN="${login}"
    STATUS_PASSWORD="${password}"
}

step_history() {
    local i samples
    for ((i = 0; i < 40; i++)); do
        samples="$(curl -sk --max-time 15 -u "${STATUS_LOGIN}:${STATUS_PASSWORD}" "https://${STATUS_HOST}/history.json" | jq '.samples | length' 2>/dev/null)"
        [[ "${samples:-0}" -ge 1 ]] && break
        sleep 15
    done
    assert "Status page history has samples" "${samples}" test "${samples:-0}" -ge 1
}

# --- main -------------------------------------------------------------------

step_preflight
log "vps-stack ${REF} on ${ADDRESS}; log: ${LOG}"
step_facts
step_install
step_provision
step_doors
verify_clean "verify after provisioning"
step_reboot "Reboot"
step_idempotency
step_ssh_port
step_doors
step_backup
SITES=0
if step_sites; then
    SITES=1
    step_status_page
fi
step_reboot "Final reboot"
[[ "${SITES}" == "1" ]] && step_history

if [[ "${FAILED}" -eq 0 ]]; then
    # shellcheck disable=SC2016  # the backticks are Markdown
    printf '\nAll checks passed. For "Verified on":\n| %s | %s | %s | `%s` (%s) | OK | e2e test, report %s |\n' \
        "$(date -u +%Y-%m-%d)" "$(printf '%s\n' "${FACTS[@]}" | sed -n 's/^System: //p')" "<provider>" \
        "$(printf '%s\n' "${FACTS[@]}" | sed -n 's/^Commit: //p')" "${REF}" "$(basename "${REPORT}")" >>"${REPORT}"
fi
log "Done: ${FAILED} failure(s). Report: ${REPORT}"
[[ "${FAILED}" -eq 0 ]]
