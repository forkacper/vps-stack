# Versions and releases

## Version numbers

`vps-stack` follows [Semantic Versioning](https://semver.org/):
`MAJOR.MINOR.PATCH`, without pre-release labels. The current version is in
`VERSION`; every release is a tag `vX.Y.Z` with a
[GitHub release](https://github.com/forkacper/vps-stack/releases) whose notes
come from `CHANGELOG.md`.

In the `0.x` series:

| Change | New version |
|---|---|
| anything that breaks compatibility (see below) | MINOR, e.g. 0.2.0 → 0.3.0 |
| a new feature that does not break anything | MINOR |
| a fix only | PATCH, e.g. 0.2.0 → 0.2.1 |

From `1.0.0` on, a change that breaks compatibility raises MAJOR, a new
feature MINOR and a fix PATCH.

### What counts as breaking

The "public interface" of `vps-stack` is everything a server or a person
relies on:

- commands, their options and exit codes;
- the keys and the meaning of values in `stack.env`, `proxy.env`,
  `backup/<group>.env` and `monitor.env`;
- paths: `/etc/vps-stack`, `/srv/data`, `/srv/backup-staging`, `/srv/backups`, the log files
  and the system files listed in [architecture.md](architecture.md);
- the contracts with projects: the proxy network
  ([project-contract.md](project-contract.md)) and the backup hooks
  ([backup-restore.md](backup-restore.md));
- what provisioning does to a server: a new or removed firewall rule, a
  changed sshd setting, a different Docker installation.

A change to any of these that needs action from the user, or that changes a
server already provisioned, is breaking. It is described under "Changed" or
"Removed" in the changelog together with what to do.

Not part of the interface: the code inside `lib/` and `scripts/`, the tests,
CI and the wording of messages.

## Branches

- `master` is the only long-lived branch. Every commit on it has passed CI.
- Work happens on short-lived branches (e.g. `fix-ssh-port-rollback`), merged
  into `master` through a pull request once CI is green. History stays
  linear (rebase merge).
- `release/X.Y` branches are created only when an older line needs a fix
  after `master` has moved on (see below). Normally there are none: fixes go
  into the next release.

Tags `v*` cannot be moved or deleted on GitHub: a published version always
points at the same code.

## Making a release

1. `master` is up to date and its CI is green.
2. Choose the version from the table above.
3. On a branch (e.g. `release-0.3.0`):
   - `VERSION`: the new version;
   - `CHANGELOG.md`: rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`,
     add a new empty `## [Unreleased]` above it, update the links at the
     bottom of the file;
   - check the notes: `.github/scripts/release-notes.sh X.Y.Z`. Links in the
     changelog are absolute and point at the tag, e.g.
     `https://github.com/forkacper/vps-stack/blob/vX.Y.Z/docs/releasing.md`:
     on the release page a relative link leads nowhere, and the script
     refuses it.
4. Pull request, CI green, merge into `master`.
5. Tag the merged commit and push the tag:

   ```bash
   git switch master && git pull
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```

6. The release workflow (`.github/workflows/release.yml`) runs the CI checks
   again, verifies that the tag, `VERSION` and the changelog agree and creates
   the GitHub release. Check that it appeared.

A mistake in a published release is fixed by a new PATCH release, never by
moving the tag.

## A fix for an older version

Only when it is really needed (for example a server that cannot move to the
newest version yet):

```bash
git switch -c release/0.2 v0.2.1      # the newest tag of that line
git cherry-pick <commit of the fix from master>
# VERSION: 0.2.2; CHANGELOG.md: a ## [0.2.2] section on this branch
git push origin release/0.2
git tag -a v0.2.2 -m "v0.2.2" && git push origin v0.2.2
```

The fix also goes into `master`, and the `master` changelog gets the same
entry under the 0.2.2 heading.

## Updating a server

A server runs a tagged version, not the `master` branch:

```bash
cd /opt/vps-stack
sudo git fetch --tags
sudo git tag --list 'v*' --sort=-v:refname | head -n 5   # the newest versions
# Read CHANGELOG.md for every version between yours and the new one.
sudo git checkout vX.Y.Z
```

After that, do what the changelog says, for example
`sudo vps-stack proxy restart` when `proxy/` changed.
