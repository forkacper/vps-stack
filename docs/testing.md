# Testing

## What CI checks and what it does not

CI (`.github/workflows/ci.yml`) checks only what can be verified reliably
without a server:

| Check | What it confirms |
|---|---|
| `shellcheck`, `bash -n` | syntax and common mistakes in all scripts |
| `bats tests/validate.bats` | validation of domains, upstreams and sizes |
| `bats tests/render.bats` | generation of site files and rejection of injection attempts |
| `bats tests/monitor.bats` | status page: logins, hashes, IP addresses, site file, ban list, `status.json` built only from the allowed fields |
| `fail2ban-regex` | the status page filter on `tests/fixtures/monitor-access.log`: failed logins match, requests without credentials and injection attempts do not |
| `systemd-analyze verify` | the collector unit of the status page |
| `docker compose config` | validity of `proxy/docker-compose.yml`, alone and with `docker-compose.monitor.yml` |
| `caddy validate` | validity of the Caddyfile with an empty `sites/`, with a generated site file and with the status page (empty and non-empty ban list) |
| secret scan (gitleaks) | no keys or passwords in the repository and its history |

**CI does not test provisioning.** It runs neither `provision`, `ssh-port`,
`backup` nor `verify`. Everything that depends on systemd, sshd, ufw,
fail2ban, a real Docker on the host and a real restic repository can only be
confirmed by hand, on a real machine, with the procedure below.

So a green CI means "the scripts parse and input validation works", not "this
works on a server".

## Local tests

```bash
shellcheck -x bin/vps-stack lib/*.sh scripts/*.sh tests/helpers.bash examples/*.sh.example
bats tests/
```

The tests of the status page need `jq`.

## Manual test procedure

It is carried out by the repository owner (or the person proposing a change)
on a **fresh, disposable machine**: a cheap VPS billed by the hour or a
virtual machine with a full systemd. A Docker container is not suitable.

Record the result of every step. Before you start, prepare: an SSH key, a test
domain whose DNS you can change, and a test project with a MySQL or MariaDB
database.

### 0. Preparation

- [ ] A fresh machine; the system (`cat /etc/os-release`) and the commit
      (`git rev-parse --short HEAD`) noted down.
- [ ] The provider's rescue console works.
- [ ] Noted down: how the image starts sshd
      (`systemctl is-active ssh.socket`), which files are in
      `/etc/ssh/sshd_config.d/`, what the default user is called.

### 1. Dry run

- [ ] `sudo ./bin/vps-stack provision --config ./stack.env --dry-run` finishes
      without an error.
- [ ] After the dry run neither `/etc/vps-stack` nor
      `/etc/ssh/sshd_config.d/00-hardening.conf` exists.

### 2. Provisioning

- [ ] `sudo ./bin/vps-stack provision --config ./stack.env` goes through all
      13 steps.
- [ ] An answer other than `YES` to the second session question ends the
      script without changes to sshd (check this in a separate run).
- [ ] The Docker repository for this release was detected (or the script
      stopped and pointed at `--docker-fallback`).
- [ ] Summary table: only `OK` (apart from steps skipped on purpose).

### 3. Second SSH session

From a separate terminal, without closing the first session:

- [ ] `ssh admin@<server>` works with the key.
- [ ] `sudo -v` works with the password that was set.
- [ ] `ssh root@<server>` is rejected.
- [ ] `ssh -o PubkeyAuthentication=no admin@<server>` is rejected (no password
      login).
- [ ] The provider's default user can no longer log in over SSH.

### 4. Verify

- [ ] `sudo vps-stack verify`: no `ERROR`.
- [ ] `sudo ufw status verbose`: deny incoming; SSH, 80, 443/tcp and 443/udp
      open.
- [ ] `sudo fail2ban-client status sshd`: the jail is active.
- [ ] `docker info`: log-driver `json-file`, live-restore enabled.
- [ ] `sudo vps-stack check-ports`: no warnings (note any system ports, e.g.
      the DHCP client).

### 5. Reboot

`sudo reboot`, then:

- [ ] SSH works.
- [ ] `swapon --show`: swap is active.
- [ ] `sudo ufw status`: active.
- [ ] `systemctl is-active docker`: active.
- [ ] `docker ps`: the `caddy` container is running and `healthy`.
- [ ] `sudo vps-stack verify`: no `ERROR`.

### 6. Idempotency

- [ ] A second `sudo vps-stack provision` goes through without the SSH and
      firewall questions.
- [ ] No new `*.bak.*` files were created
      (`sudo find /etc -name '*.bak.*' -newer /etc/vps-stack/stack.env`).
- [ ] SSH still works, `verify` is unchanged.

### 7. A site on the staging CA

Following [adding-sites.md](adding-sites.md):

- [ ] `ACME_CA` set to staging, `sudo vps-stack proxy up`.
- [ ] A test web container on the `proxy` network.
- [ ] `vps-stack check-dns <domain>` before DNS is set: `MISMATCH`; after:
      `OK`.
- [ ] `sudo vps-stack add-site <domain> <container>:80 --dry-run`: writes
      nothing.
- [ ] `sudo vps-stack add-site <domain> <container>:80`: a staging certificate
      is issued, the site responds.
- [ ] The same command a second time: "Nothing to do".
- [ ] `--alias`, `--redirect-from`, `--max-body` work as described.
- [ ] `sudo vps-stack list-sites` shows the site.
- [ ] `sudo vps-stack remove-site <domain>`: the site stops responding, the
      file is in `.removed/`.
- [ ] Back to the production CA and `sudo vps-stack proxy up`.

### 8. SSH port change

- [ ] `sudo vps-stack ssh-port 2222`: the detected mode (socket or service)
      matches the note from step 0.
- [ ] A new session on port 2222 works, **the old session still works**.
- [ ] After `YES`: port 22 closed in ufw, `SSH_PORT=2222` in `stack.env`,
      `port = 2222` in the fail2ban jail.
- [ ] A separate run: an answer other than `YES` and choosing the rollback
      brings back the previous port.
- [ ] Reboot: SSH comes up on the new port.

### 9. Backup

Following [backup-restore.md](backup-restore.md):

- [ ] `restic version` noted: Ubuntu 24.04 ships an older restic than the
      one the local integration test used (0.18).
- [ ] `sudo vps-stack backup init system` and `backup init <project>`: files
      in `/etc/vps-stack/backup/` (600), repositories in `/srv/backups/`; a
      second call changes nothing.
- [ ] Hooks from the examples installed in `/etc/vps-stack/hooks/<project>/`.
- [ ] `sudo vps-stack backup run`: exit code 0, `BACKUP_OK <group>` in the log
      for every group; `backup list` shows them.
- [ ] A second run after a small change in the database: the repository grows
      by far less than the size of the dump.
- [ ] A hook broken on purpose: the run ends with a non-zero code, the other
      groups still get `BACKUP_OK`.
- [ ] The `system` snapshot contains nothing from `/etc/vps-stack/backup/`.
- [ ] `backup restore <project> --target /tmp/r`, the dump imported into a
      temporary database: the row counts match.
- [ ] `backup export <project> --output /root/<project>.tar`: the archive has
      the dump, the files and `.env`.
- [ ] `sudo vps-stack backup setup`: a file in `/etc/cron.d`, and after 6
      hours new `BACKUP_OK` entries in the log.
- [ ] **Restore test** from section (b): the dump imports into a temporary
      database, the number of tables and rows matches.

### 10. Status page (optional)

With a test domain pointing at the server (`ACME_CA` set to staging):

- [ ] `sudo vps-stack monitor enable <domain>` finishes; the login and
      password are shown once.
- [ ] `systemctl status vps-stack-monitor` is active, and
      `/run/vps-stack-monitor/status.json` changes every 10 seconds.
- [ ] The page asks for the login; with the password it shows the server and
      the containers. A test container started with `-e TEST_SECRET=...`
      appears on the page, its value does not appear in `status.json`.
- [ ] `sudo fail2ban-client status vps-stack-monitor` shows the jail. 5 wrong
      passwords from another public address: that address gets a closed
      connection on the status page and still reaches the other sites; after
      `sudo vps-stack monitor unban <ip>` it gets the login prompt again.
- [ ] A request over IPv6: note which address the access log in
      `/var/log/vps-stack-monitor/access.log` records (the real one or a
      Docker gateway).
- [ ] After a reboot the page works again without any command.
- [ ] `sudo vps-stack verify` shows the three status page rows as OK.
- [ ] `sudo vps-stack monitor password`: the old password stops working.
- [ ] `sudo vps-stack monitor disable`: the page, the service and the jail are
      gone, the other sites work.

### 11. Cleanup

- [ ] Delete the test machine, the test restic repository and the DNS records.

## Test report

After going through the procedure, add a row below **and** in the "Verified
on" table in [README.md](../README.md) (and fill in the test columns of the
supported systems table). Record only what you actually did.

<!-- TODO(user): fill in after a test on a real machine. -->

| Date | System | Provider | Commit | Result | Notes |
|---|---|---|---|---|---|
| | | | | | |

Result: `OK` (the whole procedure), `partial` (list the skipped steps in the
notes) or `error` (with the issue number).

Once a system has an `OK` entry, its status in `lib/os-ubuntu.sh`
(`os_check_supported`) can be changed from `untested` to `ok`, which switches
off the warning at start.
