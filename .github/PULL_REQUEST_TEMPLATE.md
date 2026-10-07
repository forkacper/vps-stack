## What this PR changes

<!-- Briefly: what and why. Link the issue if there is one. -->

## What it was tested on

<!-- Required. "CI passed" is not enough: CI does not run provisioning. -->

- System and version:
- Provider or kind of machine:
- Commands run and their result:

## Checklist

- [ ] `shellcheck` reports nothing
- [ ] `bats tests/` passes; I added tests for changes in validation or templates
- [ ] A second run breaks nothing (idempotency)
- [ ] `--dry-run` still writes nothing
- [ ] I updated the documentation and `CHANGELOG.md`
- [ ] No private data: only `example.com`, `example.org`, `admin@example.com`, `example-app`
