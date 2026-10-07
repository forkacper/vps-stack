# Backup and restore

## How it works

`vps-stack` backs up with [restic](https://restic.net/). Every project has its
**own backup repository**, with its own password; a group called `system`
holds the `vps-stack` configuration and the certificates. "Repository" here
means restic's storage for the copies (a directory of encrypted,
deduplicated data), not a git repository.

```
cron every 6 h → vps-stack backup run
  system         /etc/vps-stack (without the backup configuration), certificates
  <project>      hooks: database dump + paths of user files, and /srv/<project>/.env
                 → /srv/backups/<project>   (restic repository of the project)
```

- Every run creates one **snapshot** per group: the state at that moment.
  restic stores only what changed since the previous one, so frequent
  snapshots of a database of a few GB take little extra space.
- Retention after every run: 14 daily, 8 weekly and 6 monthly snapshots;
  once a week `restic prune` and `restic check`.
- A failure in one group (a broken hook, for example) does not stop the
  others, but the whole run ends with an error, and `verify` shows it.
- The projects' code is not backed up: it is in their git repositories.

### What a copy on this server protects against

By default the repositories live on the server itself, in `/srv/backups/`.

| Protects against | Does not protect against |
|---|---|
| a bad migration, deleted or overwritten data in an application | losing the server or its disk |
| a broken deployment: you go back to the dump from a few hours ago | losing access to the provider account |
| a mistaken `docker compose down -v` | an attacker with root, who can delete the copies too |

For the right column the copies have to live elsewhere as well: see
[Copies outside the server](#copies-outside-the-server).

## Setting up

```bash
# Once: the system group.
sudo vps-stack backup init system

# For every project (the name of its directory in /srv):
sudo vps-stack backup init example-app
```

`init` creates, without overwriting anything that exists:

| Path | Content |
|---|---|
| `/etc/vps-stack/backup/example-app.env` | repository, retention, optional monitoring ping (600) |
| `/etc/vps-stack/backup/example-app.password` | repository password, generated (600) |
| `/etc/vps-stack/hooks/example-app/` | hooks of the project (700) |
| `/srv/backups/example-app/` | the restic repository (700) |

**The password** is generated and stored on the server; you never type it,
and `vps-stack backup` reads it for you. As long as the repository is on the
same server, a second copy of the password would not help: if the server is
lost, the copies are lost with it. Once the repository moves elsewhere, save
the password in your password manager as well.

Then the hooks (below), the first backup by hand and the schedule:

```bash
sudo vps-stack backup run example-app
sudo vps-stack backup setup              # cron, every 6 hours, all groups
sudo vps-stack backup list               # groups, last success, snapshots, size
```

Preview without changing anything: `sudo vps-stack backup run --dry-run`.
Log: `/var/log/vps-stack-backup.log`.

## Project hooks

Before a project's snapshot, `backup run` executes every **executable** file
`/etc/vps-stack/hooks/<project>/*.sh`. Each gets:

| Variable | Meaning |
|---|---|
| `BACKUP_GROUP` | the project, e.g. `example-app` |
| `PROJECT_DIR` | its directory, e.g. `/srv/example-app` |
| `STAGING_DIR` | the project's staging directory for dumps (`/srv/backup-staging/example-app`) |
| `HOOK_NAME` | name of the hook file without `.sh` |
| `HOOK_EXTRA_PATHS_FILE` | file for additional paths to back up |

Rules:

- Write dumps to `$STAGING_DIR/$HOOK_NAME/`, with the date in the file name.
  Before the snapshot only the newest file of every hook is kept, so a
  snapshot holds exactly one dump per hook.
- Write **plain SQL**, not gzip: restic compresses the dump itself and stores
  only the changes. A compressed dump looks entirely new every time and would
  take its full size in the repository on every run.
- Append additional paths (absolute, existing) to `$HOOK_EXTRA_PATHS_FILE`,
  one per line. A path that does not exist marks the run as failed, so that a
  typo cannot silently switch off a backup.
- The hook fails when the dump is empty or incomplete.

Examples:

```bash
sudo install -m 700 /opt/vps-stack/examples/backup-hook-mysql.sh.example \
    /etc/vps-stack/hooks/example-app/db.sh
sudo install -m 700 /opt/vps-stack/examples/backup-hook-files.sh.example \
    /etc/vps-stack/hooks/example-app/files.sh
sudoedit /etc/vps-stack/hooks/example-app/db.sh     # fill in the TODO(user) items
```

The database hook works with MySQL and MariaDB: it uses `mariadb-dump` when
the container has it (MariaDB 11 images have only that) and `mysqldump`
otherwise, and checks the `-- Dump completed` line both write at the end of a
complete dump. Make the dump with a dedicated database user that has minimal
privileges, never root.

User files belong in a bind mount below the project directory (e.g.
`./storage/uploads`), not in a named Docker volume: the path is then plain
and stable ([project-contract.md](project-contract.md)).

## Restoring

`vps-stack backup restore` always unpacks into a **new or empty directory**
and never writes over live data. Putting data back into the application is a
separate, deliberate step.

### Choosing the moment

```bash
sudo vps-stack backup snapshots example-app
```

Every row is a snapshot with its ID and time. `latest` is the newest.

### A database

```bash
# 1. A fresh snapshot of the current state first: if the restore goes wrong,
#    there is something to go back to.
sudo vps-stack backup run example-app

# 2. Unpack the chosen snapshot into a temporary directory.
sudo vps-stack backup restore example-app --snapshot <ID> --target /tmp/restore-example-app
sudo ls /tmp/restore-example-app/srv/backup-staging/example-app/db/

# 3. Stop what writes to the database.
cd /srv/example-app && sudo docker compose stop app worker

# 4. Import (overwrites the tables contained in the dump).
#    MariaDB: mariadb, MySQL: mysql. The root password variable is the one
#    the database container was started with.
sudo docker compose exec -T db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" example_app' \
    < /tmp/restore-example-app/srv/backup-staging/example-app/db/example_app-<time>.sql

# 5. Start the application again and clean up.
sudo docker compose start app worker
sudo rm -rf /tmp/restore-example-app
```

**The careful variant:** import into a temporary database (for example
`CREATE DATABASE example_app_restore`) instead, compare it with production
and only then decide. The same way recovers a single table or a few deleted
rows without turning back the whole database.

### Files

A single file:

```bash
sudo vps-stack backup restore example-app --snapshot <ID> \
    --path /srv/example-app/storage/uploads/products/123.jpg --target /tmp/r
sudo cp -p /tmp/r/srv/example-app/storage/uploads/products/123.jpg \
    /srv/example-app/storage/uploads/products/
```

A whole directory:

```bash
sudo vps-stack backup restore example-app --snapshot <ID> \
    --path /srv/example-app/storage/uploads --target /tmp/r
sudo rsync -a /tmp/r/srv/example-app/storage/uploads/ /srv/example-app/storage/uploads/
```

`rsync -a` brings back missing and changed files and keeps files added since
the snapshot; with `--delete` the directory returns exactly to the snapshot.

Not sure which snapshot has a file? With the group's settings loaded,
`restic find <name>` lists every snapshot that contains it:

```bash
sudo -i
set -a; . /etc/vps-stack/backup/example-app.env; set +a
restic find 123.jpg
```

## Moving a project to another server

```bash
# On the old server: an archive of the newest snapshot (tar or zip).
sudo vps-stack backup export example-app --output /root/example-app.tar
scp root@old-server:/root/example-app.tar .
```

The archive holds the dump, the user files and `.env`, under their full
paths. It is **not encrypted**: move it over SSH and delete it afterwards. On
the new server: provision, clone the project, put `.env` and the files in
place, `docker compose up -d`, import the dump as in "A database" above, then
`sudo vps-stack backup init example-app` and the hooks.

To move every project at once, copy `/srv/backups/` together with
`/etc/vps-stack/backup/` (the passwords) to the new server and restore from
there.

## Copies outside the server

To protect against losing the server, a group's repository can live on
S3-compatible storage or on an SFTP server instead. In
`/etc/vps-stack/backup/<group>.env`:

```bash
RESTIC_REPOSITORY=s3:https://s3.example.com/example-bucket/example-app
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
```

then `sudo vps-stack backup init <group>` creates the new repository. The old
local snapshots can be carried over with `restic copy` (see the restic
documentation). From that moment:

- save the repository password in your password manager: without it the
  copies are useless;
- prefer storage where the server can add data but not delete it (S3 Object
  Lock or versioning, or `rest-server --append-only`); otherwise an attacker
  with root on the server can delete the copies as well.

Every project can be moved separately, so different clients' data can end up
in different, physically separate places.

## Monitoring the backup

`sudo vps-stack verify` shows every group: the age of its last successful
backup (warning after 13 hours, error after 48) and where its repository
lives. For an alert when a backup stops, set `HC_URL` in the group's `.env` to
the ping URL of a healthchecks.io style monitor: the script calls
`<HC_URL>/start` and at the end `<HC_URL>` or `<HC_URL>/fail`. More:
[monitoring.md](monitoring.md).

## Monthly restore test

A backup that has never been restored is only a hope. Once a month, for every
project with a database:

1. `sudo vps-stack backup restore <project> --target /tmp/restore-test`
2. Import the dump into a temporary database container, the same image and
   version as the project uses:

   ```bash
   docker run -d --name restore-test -e MARIADB_ROOT_PASSWORD=restore-test-only mariadb:11.4
   # wait until it is up, then:
   docker exec restore-test mariadb -prestore-test-only -e 'CREATE DATABASE restore_test'
   docker exec -i restore-test mariadb -prestore-test-only restore_test \
       < /tmp/restore-test/srv/backup-staging/<project>/db/<newest>.sql
   ```

   For MySQL use the `mysql:<version>` image, `MYSQL_ROOT_PASSWORD` and the
   `mysql` client.
3. Compare the number of tables and of rows in the most important tables with
   production. Zero, or an order of magnitude fewer, means a broken backup.
4. Open a few restored user files.
5. `docker rm -f restore-test && sudo rm -rf /tmp/restore-test`, and note the
   date of the test.

The `restore-test-only` password applies only to a one-off container with no
published ports that you delete after the test.

## Moving from vps-stack 0.2

Version 0.2 had one repository for everything, configured in
`/etc/vps-stack/restic.env`, with hooks directly in `/etc/vps-stack/hooks/`.
`vps-stack backup` stops while that file exists. To move over:

1. `sudo vps-stack backup init system` and `backup init <project>` for every
   project.
2. Move every hook into its project's directory
   (`/etc/vps-stack/hooks/<project>/`) and update it from the examples: plain
   SQL instead of gzip, and `PROJECT_DIR`.
3. `sudo vps-stack backup run` and `backup list`: every group has a snapshot.
4. Move `/etc/vps-stack/restic.env` and `restic.password` away. The old
   repository stays readable with them for as long as you keep it.
