# vps-stack

> **Status: alpha (0.x). Use at your own risk.**
>
> The scripts run as **root** and change the **SSH and firewall**
> configuration. A mistake there can lock you out of the server. Do the first
> run on a machine you can throw away (a cheap VPS for an hour, or a virtual
> machine), have a snapshot and tested access to your provider's rescue
> console. This is a hobby project: no guarantee that it works, no support and
> no response time. MIT licensed, so no warranty of any kind either.

`vps-stack` is a minimal set of bash scripts and configuration files that
turns a clean Ubuntu VPS into a hardened server for hosting several Docker
Compose projects behind a shared reverse proxy (Caddy), with off-site backup
and a command for adding domains.

**What it is not:** it is not a PaaS; there is no panel, no agent, no
automatic deployment and nothing running on the server besides Docker and one
proxy container.

## What it does

- Creates an administrator account (sudo, key-only login) and a deployment
  account, disables password login and root login over SSH.
- Enables the firewall (ufw): only SSH, 80 and 443 are open.
- Configures fail2ban, automatic security updates, swap and log limits
  (journald and Docker).
- Installs Docker and starts the shared Caddy proxy with automatic HTTPS.
- Adds and removes sites with one command, with input validation, a DNS check
  and a rollback when Caddy rejects the configuration.
- Runs encrypted backups (restic) to a repository outside the server.
- Checks the state of the server (`verify`) and looks for ports exposed to the
  internet (`check-ports`).
- Optionally, a read-only status page at its own domain behind a login:
  server resources and containers, refreshed every 10 seconds (`monitor`).

The scripts hold your hand through the risky steps: before they disable SSH
passwords or enable the firewall, they require confirmation that a second SSH
session works.

## How it fits together

```
                    Internet
                       |
              80, 443/tcp, 443/udp        (the only published ports)
                       |
        +--------------v---------------+
        |  Caddy (container "caddy")   |   automatic HTTPS
        +--------------+---------------+
                       |  Docker network "proxy" (shared)
          +------------+-------------+
          |                          |
  +-------v---------+        +-------v-----------+
  | example-app-web |        | other-project-web |   web containers of the projects
  +-------+---------+        +-------+-----------+
          |  internal network        |  internal network
          |  of the project          |  of the project
  +-------v---------+        +-------v-----------+
  | app, database,  |        | app, database,    |   invisible to the proxy
  | cache, workers  |        | cache, workers    |   and to other projects
  +-----------------+        +-------------------+
```

Details: [docs/architecture.md](docs/architecture.md).

> **Warning: ports published by Docker (`ports:`) bypass ufw.**
>
> Docker manages its own network rules, and a container with
> `ports: "8080:80"` is reachable from the internet even when ufw does not
> allow that port. There is one rule: **only the proxy has `ports:`**. Projects
> publish no ports, and if they have to (e.g. database access through an SSH
> tunnel), then only as `127.0.0.1:port:port`. `vps-stack check-ports` and
> `vps-stack verify` watch for this.

## Supported systems

| System | Status | Tested by | Date | Commit |
|---|---|---|---|---|
| Ubuntu 26.04 LTS | target system; code implemented, **untested** | | | |
| Ubuntu 24.04 LTS | same code, **untested** (warning at start) | | | |
| Debian 12 / 13 | planned; the script refuses to run ("not implemented") | | | |
| Debian 11 and older, other distributions | not supported | | | |

Debian 11 is out of support: its LTS period ended on 2026-08-31
([wiki.debian.org/LTS](https://wiki.debian.org/LTS)).

On any system other than Ubuntu 24.04 / 26.04 the scripts stop before making
any change.

### Verified on

This section is filled in only by the repository owner, from the report of the
procedure described in [docs/testing.md](docs/testing.md). As long as the
table is empty, **nothing in this repository has been confirmed on a real
server**.

<!-- TODO(user): fill in after a test on a real machine (docs/testing.md). -->

| Date | System | Provider | Commit | Result | Notes |
|---|---|---|---|---|---|
| | | | | | |

## Quick start

The full version with explanations: [docs/quickstart.md](docs/quickstart.md).

```bash
# On a fresh server, as root or a user with sudo:
sudo apt-get update && sudo apt-get install -y git
sudo git clone https://github.com/forkacper/vps-stack.git /opt/vps-stack
cd /opt/vps-stack

# Read the scripts before you run them. Then:
cp config/stack.env.example ./stack.env      # fill in ADMIN_SSH_PUBKEY_FILE
cp config/proxy.env.example ./proxy.env      # fill in ACME_EMAIL
sudo ./bin/vps-stack provision --config ./stack.env --dry-run   # preview
sudo ./bin/vps-stack provision --config ./stack.env
sudo vps-stack verify
```

Installation is always: clone, read, run. There is no "download and execute
right away" installer and there never will be.

The repository can live in any directory; `/opt/vps-stack` is recommended.
Local configuration goes to `/etc/vps-stack/` and `git pull` does not touch
it.

## Commands

| Command | What it does |
|---|---|
| `vps-stack provision` | prepares the server; safe to run again; has `--dry-run` |
| `vps-stack ssh-port <port>` | changes the SSH port in a safe order |
| `vps-stack verify` | checks the state of the server, changes nothing |
| `vps-stack check-ports` | looks for ports reachable from the internet besides SSH, 80, 443 |
| `vps-stack add-site <domain> <container:port>` | adds a site to the proxy; has `--dry-run` |
| `vps-stack remove-site <domain>` | removes a site (the file is moved aside, not deleted) |
| `vps-stack list-sites` | lists domains, upstreams, aliases and redirects |
| `vps-stack check-dns <domain>...` | checks that a domain points at this server |
| `vps-stack proxy up\|down\|restart\|reload\|validate\|status\|logs` | manages the proxy container |
| `vps-stack backup init\|run\|setup` | restic backup: initialise, run, install the cron job |
| `vps-stack monitor enable <domain>\|disable\|password\|status` | optional status page: resources and containers, behind a login |
| `vps-stack version`, `vps-stack help` | version and help |

Every command accepts `--help`.

## Security model in short

The full description: [docs/security-model.md](docs/security-model.md).

- **Protects against:** SSH password guessing (keys only, root disabled),
  accidentally exposed host services (firewall), projects reaching each
  other's databases (separate networks), missing system security patches
  (automatic updates).
- **Does not protect against:** bugs in your applications (Caddy is a proxy,
  not an application firewall), a compromised VPS provider account (it
  bypasses everything), failure of the only server, ports published by Docker
  behind ufw's back.
- **The `docker` group is root.** The administrator is a member. The
  deployment account joins it only with `DEPLOY_IN_DOCKER_GROUP=true`:
  deployments are more convenient then, but a compromised deploy account means
  a compromised server. The default is `false`.

## How this project was made

The code, tests and documentation in this repository were generated with the
help of AI from a written specification prepared by the owner. The repository
owner tests them by hand on real machines and records the results in the
[Verified on](#verified-on) section.

What that means for you:

- Treat the code like any unknown script run as root: read it. It is short and
  deliberately simple.
- The automated tests (CI) only check what can be checked without a server:
  syntax, input validation, configuration generation and the validity of the
  Caddy configuration. **CI does not test provisioning.** The scope is
  described in [docs/testing.md](docs/testing.md).
- Behaviour on a particular system is confirmed only when it appears in the
  "Verified on" table.

## FAQ

### Why not Coolify, Dokku, CapRover, Kamal or Ansible?

Each of these tools does more than `vps-stack`; above all they automate
deployments, which are not covered here at all. If you need that, pick one of
them.

`vps-stack` has a different goal: as few moving parts as possible on one small
server maintained by one person. No agent or panel runs on the server, the
whole "platform" is bash scripts you can read in an evening, and projects stay
plain Docker Compose files. The price is the lack of comfort: you deploy
yourself (`git pull` and `docker compose up -d`).

Ansible would be the right choice for many servers. For a single server,
idempotent bash gives the same result without another layer to learn. The
reasoning behind the decisions: [docs/decisions.md](docs/decisions.md).

### Can I run this on a server that already hosts something?

The scripts are written for a fresh server. On a running one use `--dry-run`
first and read the output: changing `AllowUsers` in SSH and enabling ufw can
cut off existing services and users.

### How do I update vps-stack?

`cd /opt/vps-stack && sudo git pull`, read [CHANGELOG.md](CHANGELOG.md), and
after changes in `proxy/` run `sudo vps-stack proxy restart`.

## Documentation

- [docs/quickstart.md](docs/quickstart.md): the first run, step by step
- [docs/ssh-keys.md](docs/ssh-keys.md): creating an SSH key and getting it onto the server
- [docs/architecture.md](docs/architecture.md): networks, directories, what runs where
- [docs/security-model.md](docs/security-model.md): what it protects against and what it does not
- [docs/adding-sites.md](docs/adding-sites.md): domains, DNS, certificates
- [docs/project-contract.md](docs/project-contract.md): requirements for projects
- [docs/backup-restore.md](docs/backup-restore.md): backup and restore
- [docs/ssh-recovery.md](docs/ssh-recovery.md): what to do when SSH is locked
- [docs/monitoring.md](docs/monitoring.md): the minimum of monitoring and the optional status page
- [docs/testing.md](docs/testing.md): what is tested and the manual test procedure
- [docs/decisions.md](docs/decisions.md): reasoning behind the decisions

## Issues and contributing

Bugs and proposals: issues in the repository (templates are provided).
Vulnerabilities: [SECURITY.md](SECURITY.md). Rules for changes:
[CONTRIBUTING.md](CONTRIBUTING.md). This is a hobby project; replies may come
late or not at all.

## License

[MIT](LICENSE).
