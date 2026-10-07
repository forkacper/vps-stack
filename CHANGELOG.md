# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project follows [Semantic Versioning](https://semver.org/).
In the `0.x` series any release may change behaviour in a backwards
incompatible way.

## [Unreleased]

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

[Unreleased]: https://github.com/forkacper/vps-stack/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/forkacper/vps-stack/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/forkacper/vps-stack/releases/tag/v0.1.0
