# Security model

This document says honestly what `vps-stack` gives you and what it does not.
Nothing here replaces your own attention.

## What it protects against

**Password guessing and root login over SSH.** Login is possible by key only
and only for two accounts (`AllowUsers`). Root does not log in over SSH at
all. The administrator uses `sudo` with a password; `NOPASSWD` is not set.

**Accidentally exposed host services.** ufw drops all incoming traffic except
SSH, 80 and 443. A service started on the host by mistake is not reachable
from the internet.

**One project reaching another project's data.** The database and cache of
every project are on its own internal network. The proxy and the other
projects have no network route to them.

**Missing system security patches.** unattended-upgrades installs security
updates automatically. A reboot after a kernel update is manual by default;
`vps-stack verify` reminds you when one is needed.

**A disk filled up by logs.** The system journal and container logs have size
limits, and unused images and build cache are cleaned up every week.

**Ordering mistakes with domains.** `add-site` checks DNS before adding a
site, so that failed certificate attempts do not exhaust the certificate
authority's rate limits, and rolls the change back when Caddy rejects the
configuration.

**Configuration injection through arguments.** Every value that ends up in a
Caddy file is validated against a strict pattern, and the template is filled
in by plain text substitution, without `eval` and without shell expansion.

## What it does NOT protect against

**Bugs in your applications.** Caddy is a reverse proxy, not an application
firewall. SQL injection, a data leak through an API or a weak admin panel
password pass straight through it.

**The `docker` group is root.** Anyone who can start containers can mount the
host's file system and take over the server. The administrator is always in
this group. The deployment account joins it only with
`DEPLOY_IN_DOCKER_GROUP=true`; a leak of its SSH key then means the whole
server is compromised.

**Ports published by Docker bypass ufw.** `ports: "3306:3306"` in a Compose
file exposes the database to the internet despite the firewall. `check-ports`
and `verify` detect it, but only after the fact and only when you run them.

**A single server is a single point of failure.** A disk failure, a provider
error or an administrator's mistake take everything down at once. The only
answer is an off-site backup and a rehearsed restore. The default backup
repositories live on the server itself and do not cover this case
([backup-restore.md](backup-restore.md)).

**A compromised VPS provider account bypasses everything.** Whoever has
access to the panel has the console, the snapshots and the disks. That is why
2FA on that account is the first step of the instructions.

**Web containers can see each other.** They are all on the `proxy` network. A
compromised web container of one project can send requests to the web
containers of other projects, bypassing Caddy.

**Volumetric attacks (DDoS).** A small VPS has no means of defending itself
against them.

**Vulnerabilities in Docker, Caddy and the kernel.** System updates install
themselves, but the Caddy image is pinned to a version and you update it by
hand. Docker packages from Docker's own repository are not covered by the
automatic security updates: update them with `apt upgrade`.

**What the status page shows.** When enabled (`vps-stack monitor`), the
page behind its login shows container names, image versions and resource
usage. The collector never reads environment variables, labels, mounts or
logs, and nothing in a container gets access to Docker for it. A leaked
status page password discloses the server's inventory, not its secrets.

**Secrets in the projects' `.env` files.** They lie on the disk in plain text
and go into the encrypted backup. Whoever has root has all of them.

## Being honest about fail2ban

With password login disabled, fail2ban does not really improve the security of
SSH: a dictionary attack cannot be carried out anyway. Its practical role is
to reduce noise in the logs. It is installed because it is cheap and does no
harm, but do not treat it as a layer of protection. Provisioning configures
only the `sshd` jail.

The optional status page (`vps-stack monitor`) adds the `vps-stack-monitor`
jail. Its password is long and random, so here too the jail does not stand
between an attacker and the password; it stops a flood of login attempts,
each of which costs the server a bcrypt computation. It bans inside Caddy, on
the status page only, and never bans private or Docker addresses. IPv6
clients are seen, and banned, with their real address because the `proxy`
network has IPv6 ([architecture.md](architecture.md)).

## What stays on your side

- 2FA and a strong password on the VPS provider account and at the domain
  registrar.
- Safe storage of the SSH key (with a passphrase), and of the backup
  repository passwords once the repositories live outside the server (in a
  password manager).
- Updating the projects' images and the Caddy image.
- Rebooting the server after kernel updates (or `AUTO_REBOOT=true`).
- The security of the applications themselves: dependencies, authentication,
  permissions.
- Passwords on auxiliary services (database, Redis), on the internal network
  too.
- Running `vps-stack verify` regularly and a monthly backup restore test.
- External monitoring: the server itself cannot tell you that it is down.

## Reporting problems

Vulnerabilities in the scripts and templates: [SECURITY.md](../SECURITY.md).
