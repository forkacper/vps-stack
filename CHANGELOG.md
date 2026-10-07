# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project follows [Semantic Versioning](https://semver.org/).
In the `0.x` series any release may change behaviour in a backwards
incompatible way.

## [Unreleased]

**Run once on existing servers: `sudo vps-stack proxy network-ipv6`**
(a short outage of all sites while the network is recreated).

### Fixed

- IPv6 clients reached every site as the Docker gateway (e.g.
  `172.18.0.1`) instead of their own address: the `proxy` network was
  IPv4-only, so Docker published Caddy's ports on IPv6 through its userland
  proxy. Applications saw the gateway in `X-Forwarded-For` and fail2ban could
  not ban IPv6 attackers on the status page. The network is now created with
  IPv6 (`provision`, `proxy up`), and ip6tables keeps the client address.
  This relies on ip6tables being enabled in Docker, the default since Docker
  Engine 27.0.1.

- The status page kept refreshing with the old password after a password
  change: every refresh counted as a failed login, and fail2ban banned the
  administrator's own address. After a rejected login the page now stops
  and asks to be reloaded.
- `monitor refresh` stopped with "FAIL2BAN_IGNOREIP: unbound variable" on a
  server with fail2ban: it did not read `stack.env`. It does now.
- `provision` no longer prints systemd's "Synchronizing state of ... with
  SysV service script" lines; `backup restore --path` shows where the
  restored path is; hooks that write nothing (like the files example) no
  longer leave an empty directory in every snapshot.

### Changed

- Ubuntu 24.04 is confirmed on a real server (OVH, 2026-10-07; see "Verified
  on" in the README): the scripts no longer warn that it is untested. Ubuntu
  26.04 still does.

### Added

- `proxy network-ipv6`: recreates an IPv4-only `proxy` network with IPv6,
  reconnecting every attached container (running or stopped) with its
  aliases; `--dry-run` shows the plan. `verify` reports whether the network
  has IPv6, and `provision` warns about an IPv4-only one.

## [0.4.2] - 2026-10-07

### Fixed

- `provision` (and every other apt call) failed with "Could not get lock
  /var/lib/apt/lists/lock" when automatic updates ran apt at the same time,
  which is common on a fresh server shortly after boot. apt calls now wait
  for the apt and dpkg locks, up to 10 minutes, printing that apt is busy;
  after that they fail with the command that shows the process holding them.

## [0.4.1] - 2026-10-07

### Fixed

- `provision` failed at the "Users" step on Ubuntu cloud images: they already
  have a group named `admin` (created by cloud-init), and `useradd admin`
  refuses to run. Preflight now refuses an account name taken by a group,
  before anything is changed, and the default administrator name is
  `sysadmin`. An existing `stack.env` with `ADMIN_USER=admin` keeps working
  where no such group exists.
- `provision --dry-run` no longer ends with "Provisioning finished" and does
  not claim that other users are already blocked; it says that nothing was
  changed, and ends with an error code when the preview found errors.

## [0.4.0] - 2026-10-07

### Added

- Status page history: every 5 minutes the collector records CPU (average
  and highest), memory, swap, disk, load and the memory of every running
  container, keeps 7 days in `/var/lib/vps-stack-monitor/` (survives
  reboots), and the page shows them as charts for 24 hours or 7 days, plus a
  24-hour memory trend per container.
- `monitor refresh`: after an update, brings an enabled status page in line
  with the new version (site file, collector service, fail2ban jail) and
  keeps the password. **Run it once after updating** if the status page is
  enabled: the site file of an existing page does not serve the history yet.

## [0.3.0] - 2026-10-07

### Changed

- **Breaking:** backups are per project. Every project has its own restic
  repository and generated password (`/etc/vps-stack/backup/<project>.env`,
  `/srv/backups/<project>/`), its hooks live in
  `/etc/vps-stack/hooks/<project>/`, and a `system` group holds the vps-stack
  configuration and certificates. The repositories live on the server by
  default. `/etc/vps-stack/restic.env` is no longer used: `backup` stops while
  it exists. Migration: "Moving from vps-stack 0.2" in
  [docs/backup-restore.md](https://github.com/forkacper/vps-stack/blob/v0.3.0/docs/backup-restore.md#moving-from-vps-stack-02).
- The database hook example writes plain SQL instead of gzip, so restic can
  deduplicate consecutive dumps; it uses `mariadb-dump` or `mysqldump`,
  whichever the container has, and never leaves an unfinished dump behind.
- Hooks receive `PROJECT_DIR` and `BACKUP_GROUP`; only the newest dump of
  every hook is kept, and it is pruned before the snapshot, so a snapshot
  holds exactly one dump per hook.

### Added

- `backup list`, `backup snapshots`, `backup restore` (always into a new or
  empty directory) and `backup export` (a tar or zip archive of a snapshot).
- `verify` reports every backup group, where its repository lives, projects
  without hooks, and the space taken by the local repositories.

### Removed

- `config/restic.env.example`; `backup init` writes the group configuration.

## [0.2.0] - 2026-10-07

### Added

- Release process: version numbers without pre-release labels, tags
  `vX.Y.Z` with GitHub releases created by `.github/workflows/release.yml`,
  a version and changelog check in CI ([docs/releasing.md](https://github.com/forkacper/vps-stack/blob/v0.2.0/docs/releasing.md)).
  The installation instructions check out the newest release.
- [docs/ssh-keys.md](https://github.com/forkacper/vps-stack/blob/v0.2.0/docs/ssh-keys.md): creating an SSH key and getting it
  onto the server.
- Example GitHub Actions workflow for projects
  (`examples/project-build-workflow.yml.example`): tests, image build and
  push to ghcr.io, with manual deploy and rollback steps. The project Compose
  example takes the application image tag from `APP_TAG`.
- `monitor`: optional, read-only status page at its own domain (server
  resources and containers, refreshed every 10 seconds). Served by Caddy from
  a file written by a collector service, which reads a fixed set of fields
  and never environment variables or logs. Generated login and password;
  a fail2ban jail bans repeated failed logins inside Caddy, on the status
  page only.

### Changed

- The version has no pre-release label any more: `0.1.0-alpha.1` is now
  `0.1.0`, and the help, README and start-up warning no longer say "alpha".
  The warning that the scripts are untested on real servers stays.
- `add-site`: the duplicate and DNS checks moved to `lib/common.sh`, shared
  with `monitor enable`. The DNS mismatch question now reads "Continue
  despite the DNS mismatch?".
- CI installs `jq` in the bats container and checks the status page (Caddy
  configuration, fail2ban filter, systemd unit, Compose overlay).

## [0.1.0] - 2026-10-07

First version. The code has not been confirmed on a real server yet (see the
"Verified on" section of the README).

Its `VERSION` file still reads `0.1.0-alpha.1`: the pre-release label was
dropped after it was written. The tag `v0.1.0` points at that commit.

### Added

- `provision`: packages, time zone, journald limits, sysctl, swap, users, SSH
  hardening, ufw, fail2ban, automatic updates, Docker, directories, network
  and proxy start; `--dry-run` mode.
- `ssh-port`: SSH port change with `ssh.socket` / `ssh.service` detection.
- Caddy proxy in Docker Compose with a shared header snippet.
- `add-site`, `remove-site`, `list-sites`, `check-dns`: site management with
  input validation and rollback when Caddy rejects the configuration.
- `check-ports`, `verify`: server state checks.
- `backup`: restic with project hooks, retention and a monitoring ping.
- Operating system layer: Ubuntu 24.04 and 26.04 (untested), a skeleton for
  Debian (refuses to run).
- bats tests for validation and template rendering, CI (shellcheck, bats,
  Compose and Caddy validation, secret scan).
- Documentation in `docs/`.

[Unreleased]: https://github.com/forkacper/vps-stack/compare/v0.4.2...HEAD
[0.4.2]: https://github.com/forkacper/vps-stack/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/forkacper/vps-stack/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/forkacper/vps-stack/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/forkacper/vps-stack/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/forkacper/vps-stack/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/forkacper/vps-stack/releases/tag/v0.1.0
