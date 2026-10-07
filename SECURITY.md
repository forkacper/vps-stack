# Security policy

## Reporting a vulnerability

Do not report vulnerabilities in public issues.

Use GitHub's private vulnerability reporting: the **Security** tab of the
repository, **Report a vulnerability** button.

<!-- TODO(user): enable "Private vulnerability reporting" in the repository settings (Settings → Code security). The button is not visible without it. -->

In the report give: the `vps-stack` version or commit, the operating system,
steps to reproduce and the expected impact. Remove IP addresses, domains and
secrets from logs.

## Scope

In scope:

- the scripts in `bin/`, `lib/` and `scripts/`,
- the templates in `templates/` and the configuration in `proxy/`,
- the examples in `examples/` and `config/`, when using them as described
  leads to an insecure configuration.

Out of scope:

- vulnerabilities in Docker, Caddy, restic, OpenSSH, ufw, fail2ban and the
  operating system itself (report them to their authors),
- the configuration and code of projects hosted on the server,
- consequences of running the scripts on an unsupported system or after
  manual modifications.

## What to expect

This is a hobby project maintained in spare time. **There is no guaranteed
response time and no deadline for a fix.** Reports are read and taken
seriously, but a reply may take a while.

## Supported versions

Fixes go only into the latest version on the master branch. The `0.x` series is
alpha.
