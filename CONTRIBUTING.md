# Contributing

Thank you for your interest. Before you spend time on a change, please read
the following.

## Nature of the project

`vps-stack` is a hobby project maintained by one person in spare time. There
is no guarantee of support, of a response time, or that a change will be
accepted. Discuss larger changes in an issue first.

The project is small on purpose. Proposals that add tools outside the current
scope (Ansible, Terraform, Traefik, web panels, automatic image updates) will
most likely be declined: the reasons are in
[docs/decisions.md](docs/decisions.md).

## Branches and releases

Work on a branch and open a pull request against `master`; it is merged once
CI is green. Add an entry under `## [Unreleased]` in `CHANGELOG.md` for every
change a user would notice. Versions and the release procedure:
[docs/releasing.md](docs/releasing.md).

## Rules for pull requests

1. **shellcheck reports nothing** for any script. Disabling a rule
   (`# shellcheck disable=`) needs a comment saying why.
2. **The bats tests pass** (`bats tests/`). A change in validation or in the
   templates needs a new test.
3. **Idempotency.** A second run breaks nothing, and configuration that is
   already correct is not rewritten. Changes to the system go through `run()`,
   `write_file()` or `append_line()` from `lib/common.sh`, so that `--dry-run`
   keeps working.
4. **No change in behaviour without updating the documentation** (`README.md`,
   `docs/`, `CHANGELOG.md`).
5. **Say what the change was tested on:** system and version (e.g. Ubuntu
   24.04), provider or kind of machine, commands run. A change to `provision`,
   `ssh-port` or the firewall rules without a test on a real machine will not
   be accepted. "CI passed" is not such a test: CI does not run provisioning.
6. **No private data:** only `example.com`, `example.org`,
   `admin@example.com`, `example-app`. No real domains, IP addresses, e-mail
   addresses or keys, in the commit history either.

## Code style

- `#!/usr/bin/env bash`, `set -euo pipefail`, logic in functions.
- All variables quoted, no `eval`.
- Everything in English: messages, file names, variables and comments.
- Differences between distributions live only in `lib/os-<id>.sh`.
- Do not guess the state of the system: detect it or stop with a clear
  message.
- Given two solutions that work equally well, pick the simpler one.

## Running the tests locally

```bash
shellcheck -x bin/vps-stack lib/*.sh scripts/*.sh .github/scripts/*.sh tests/helpers.bash tests/e2e/*.sh examples/*.sh.example
bats tests/
```

The tests of the status page need `jq`.

The full scope of the automated tests and the manual test procedure:
[docs/testing.md](docs/testing.md).
