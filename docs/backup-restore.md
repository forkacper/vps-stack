# Backup and restore

**Keep the backup repository password in a password manager, together with the
repository address and the storage credentials. Without that password the
backup is useless: nobody, including you, can decrypt it.** These details are
deliberately not part of the backup itself, so if they exist only on the
server, they disappear with it.

## Assumptions

- Tool: [restic](https://restic.net/). Data is encrypted before it is sent.
- The repository lives **outside the VPS provider** (S3-compatible storage, an
  SFTP server or any other backend restic supports). A backup on the same
  server or in the same account is not a backup.
- cron runs the backup every 6 hours.
- A failure of any part ends the whole run with an error code and a `fail`
  ping. A partial backup is better than none, but it has to raise an alarm.

## What is backed up

| Path | Content |
|---|---|
| `/srv/backup-staging` | database dumps made by the hooks |
| `/srv/data/caddy/data` | certificates and the ACME account key |
| `/etc/vps-stack` | configuration, site files, hooks |
| `/srv/*/.env` | the projects' `.env` files |
| paths named by the hooks | e.g. directories with user files |

**Excluded:** `/etc/vps-stack/restic.env` and `/etc/vps-stack/restic.password`.
The credentials and the password of the repository must not live only in the
repository they unlock. They have to be in your password manager.

The projects' code is not backed up: it is in their git repositories. Docker
volumes are not either; database data goes into the backup as dumps made by
the hooks, and files as paths named by the hooks.

## Setup

```bash
# 1. Repository settings
sudo install -m 600 /opt/vps-stack/config/restic.env.example /etc/vps-stack/restic.env
sudoedit /etc/vps-stack/restic.env

# 2. Repository password: long, random, saved in a password manager
sudo sh -c 'umask 077; openssl rand -base64 32 > /etc/vps-stack/restic.password'
sudo cat /etc/vps-stack/restic.password      # copy it to the password manager NOW

# 3. Initialise the repository (safe to repeat)
sudo vps-stack backup init

# 4. Project hooks (see below), then the first backup by hand
sudo vps-stack backup run

# 5. Schedule
sudo vps-stack backup setup
```

Preview without running anything: `sudo vps-stack backup run --dry-run`.

Log: `/var/log/vps-stack-backup.log`. `sudo vps-stack verify` shows the age of
the last successful backup.

## Project hooks

Before sending data, the script runs every **executable** file matching
`/etc/vps-stack/hooks/*.sh`. Each gets three variables:

| Variable | Meaning |
|---|---|
| `STAGING_DIR` | directory for local dumps (`/srv/backup-staging`) |
| `HOOK_NAME` | name of the hook file without `.sh` |
| `HOOK_EXTRA_PATHS_FILE` | file for additional paths to back up |

Rules:

- Write dumps to `$STAGING_DIR/$HOOK_NAME/`, with the date in the file name.
- Append additional paths (absolute, existing) to `$HOOK_EXTRA_PATHS_FILE`,
  one per line.
- The hook **fails** when the dump is empty or corrupt (`gzip -t`). Use
  `set -euo pipefail`: without `pipefail` a `mysqldump` error in the pipe to
  `gzip` would be masked.
- A failing hook stops neither the other hooks nor the backup itself, but the
  whole run is marked as failed.
- After the backup, the 2 newest files are kept in every
  `$STAGING_DIR/<hook>/` directory.

Examples: `examples/backup-hook-mysql.sh.example` and
`examples/backup-hook-files.sh.example`.

```bash
sudo install -m 700 /opt/vps-stack/examples/backup-hook-mysql.sh.example \
    /etc/vps-stack/hooks/example-app-db.sh
sudoedit /etc/vps-stack/hooks/example-app-db.sh     # fill in the TODO(user) items
```

Make the dump with a dedicated database user that has minimal privileges.

## Retention

After every backup: `restic forget --keep-daily 14 --keep-weekly 8
--keep-monthly 6`. Once a week (the first run on Sunday, UTC): `restic prune`
and `restic check --read-data-subset=5%`.

## Monitoring the backup

Set `HC_URL` in `restic.env` to the ping URL of a healthchecks.io style
monitor. The script calls `<HC_URL>/start` at the beginning and `<HC_URL>` or
`<HC_URL>/fail` at the end. Configure the monitor to alert when no ping has
arrived for 13 hours. More: [monitoring.md](monitoring.md).

---

## (a) Restoring a server from scratch

Scenario: the server is gone. You have the password manager and access to DNS.

1. **New VPS.** Order a machine, go through steps 1-4 of
   [quickstart.md](quickstart.md) (provisioning with a new `stack.env`).
2. **Access to the repository.** Recreate from the password manager:

   ```bash
   sudoedit /etc/vps-stack/restic.env            # the same settings as before
   sudo sh -c 'umask 077; cat > /etc/vps-stack/restic.password'   # paste the password, Ctrl+D
   sudo chmod 600 /etc/vps-stack/restic.env /etc/vps-stack/restic.password
   ```

3. **Restore to a temporary directory.** Do not restore straight onto `/`:

   ```bash
   sudo -i
   set -a; . /etc/vps-stack/restic.env; set +a
   restic snapshots
   restic restore latest --target /tmp/restore
   ```

4. **vps-stack configuration.** Copy the site files and the hooks:

   ```bash
   cp -a /tmp/restore/etc/vps-stack/sites/. /etc/vps-stack/sites/
   cp -a /tmp/restore/etc/vps-stack/hooks/. /etc/vps-stack/hooks/
   ```

   Compare `stack.env` and `proxy.env` with the old ones and carry over the
   values you need.
5. **Certificates (optional).** Restoring `/srv/data/caddy/data` avoids having
   the certificates issued again:

   ```bash
   vps-stack proxy down
   cp -a /tmp/restore/srv/data/caddy/data/. /srv/data/caddy/data/
   ```

   If you skip this step, Caddy obtains new certificates once DNS has been
   switched.
6. **Projects.** For each one: clone the repository into `/srv/<project>`,
   copy `.env` from `/tmp/restore/srv/<project>/.env`, run
   `docker compose up -d`, import the newest database dump from
   `/tmp/restore/srv/backup-staging/<hook>/` and copy the user files.
7. **DNS.** Switch the domains' records to the new server's address. Only when
   `vps-stack check-dns <domain>` shows `OK`, run `sudo vps-stack proxy up`.
8. **Cleanup.** `rm -rf /tmp/restore`, then `sudo vps-stack verify`,
   `sudo vps-stack backup run` and `sudo vps-stack backup setup`.

## (b) Monthly restore test

A backup that has never been restored is only a hope. Once a month:

1. **Restore to a temporary directory:**

   ```bash
   sudo -i
   set -a; . /etc/vps-stack/restic.env; set +a
   restic snapshots | tail -n 5
   restic restore latest --target /tmp/restore-test
   ```

2. **Import the dump into a temporary database container** (not into the
   production one):

   ```bash
   # TODO(user): the same image and version as in the project
   docker run -d --name restore-test -e MYSQL_ROOT_PASSWORD=restore-test-only example/database:TODO
   # wait until the database is up, then:
   docker exec restore-test mysql -prestore-test-only -e 'CREATE DATABASE restore_test'
   gunzip -c /tmp/restore-test/srv/backup-staging/example-app-db/<newest>.sql.gz |
       docker exec -i restore-test mysql -prestore-test-only restore_test
   ```

3. **Check the number of tables and rows** and compare with production:

   ```bash
   docker exec restore-test mysql -prestore-test-only -e \
       'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema="restore_test"'
   # TODO(user): a few of the project's most important tables
   docker exec restore-test mysql -prestore-test-only -e 'SELECT COUNT(*) FROM restore_test.TODO'
   ```

   The numbers should be close to production (the difference is the traffic
   since the last backup). Zero, or an order of magnitude fewer, means a
   broken backup.
4. **Check the files:** open a few random user files from
   `/tmp/restore-test/...` and compare the number of files with production.
5. **Clean up:**

   ```bash
   docker rm -f restore-test
   rm -rf /tmp/restore-test
   ```

6. Write down the date of the test. While you are at it, check that the
   password in the password manager is the one the server uses.

The `restore-test-only` password in this example applies only to a one-off
container with no published ports that you delete after the test.
