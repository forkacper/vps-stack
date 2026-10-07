# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project follows [Semantic Versioning](https://semver.org/).
In the `0.x` series any release may change behaviour in a backwards
incompatible way.

## [Unreleased]

### Added

- Example GitHub Actions workflow for projects
  (`examples/project-build-workflow.yml.example`): tests, image build and
  push to ghcr.io, with manual deploy and rollback steps. The project Compose
  example takes the application image tag from `APP_TAG`.

## [0.1.0-alpha.1]

First version. The code has not been confirmed on a real server yet (see the
"Verified on" section of the README).

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
