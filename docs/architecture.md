# Architecture

## Principle

As little as possible runs on the host: the system, SSH, the firewall, Docker.
Everything that serves the projects' traffic and data runs in containers. The
only container reachable from the internet is the proxy.

## What runs on the host and what in containers

| On the host | In containers |
|---|---|
| OpenSSH (keys only) | Caddy (shared proxy, container `caddy`) |
| ufw (firewall) | web servers of the projects |
| fail2ban | applications, workers |
| unattended-upgrades | databases, caches |
| Docker Engine with the Compose plugin | |
| cron: backup and image cleanup | |
| restic (backup client, one repository per project) | |

`vps-stack` installs no application runtimes (PHP, Node, Python) on the host.
They belong in the projects' images.

## Networks

```
Internet
   |
   |  80/tcp, 443/tcp, 443/udp
   v
[ caddy ]----------- network "proxy" (external, shared) -----------+
                          |                                        |
                 [ example-app-web ]                    [ other-project-web ]
                          |                                        |
             internal network example-app          internal network other-project
                    |          |                             |          |
                 [ app ]     [ db ]                       [ app ]     [ db ]
```

- **The `proxy` network** (named by `PROXY_NETWORK`) is created by
  provisioning and shared. Caddy joins it, and **only the web container** of
  every project.
- **The `proxy` network has IPv6 enabled** (Docker picks a private /64 for
  it). On an IPv4-only network Docker publishes Caddy's ports on the host's
  IPv6 addresses through its userland proxy, and every IPv6 client reaches
  Caddy as the network gateway (e.g. `172.18.0.1`): fail2ban cannot ban it
  and the applications see the gateway in `X-Forwarded-For`. With IPv6 on
  the network, ip6tables forwards the traffic and keeps the client address.
  This relies on ip6tables being enabled in the Docker daemon, the default
  since Docker Engine 27.0.1. A network created by an older `vps-stack` is
  moved once with `sudo vps-stack proxy network-ipv6`; `verify` points at it.
- **Internal networks** are defined by each project in its own Compose file.
  The database, cache and workers are only on those, so neither the proxy nor
  other projects have a route to them.
- Caddy finds the web container by name (`container_name`) through Docker's
  DNS, which is why the upstream in `add-site` is `container-name:port`.

Web containers of different projects can see each other on the `proxy`
network. That is a deliberate trade-off for simplicity; so do not expose
anything on the web container beyond what is public anyway.

## Ports

The only ports published on the server are 80/tcp, 443/tcp and 443/udp
(HTTP/3) of the `caddy` container, plus the host's SSH port.

**Ports published by Docker bypass ufw.** That is why projects do not use
`ports:`, and when they have to, they publish on `127.0.0.1` only.
`vps-stack check-ports` checks this.

## Directory layout

Code and local configuration are kept apart: updating the code (checking out
a newer release tag, [releasing.md](releasing.md)) overwrites no settings, and
`/etc/vps-stack` can be kept in your own private repository.

```
/opt/vps-stack/            clone of this repository at a release tag (code only)
/etc/vps-stack/            local configuration, root:root, 700
├── stack.env              provisioning parameters (600)
├── proxy.env              ACME_EMAIL, ACME_CA (600)
├── backup/                backup groups (700): <group>.env and <group>.password (600),
│                          not part of any backup
├── sites/                 Caddy files, one per site: <domain>.caddy
│   └── .removed/          files of removed sites
└── hooks/<project>/       backup hooks of every project (700)
/srv/data/caddy/data       certificates and the ACME account key
/srv/data/caddy/config     Caddy state
/srv/backup-staging/<project>/  the newest dump of every hook, before the snapshot (700)
/srv/backups/<group>/      restic repository of every group (700), by default
/srv/<project>/            project directories (clones of their repositories)
```

A project directory is created by hand, owned by `DEPLOY_USER`:

```bash
sudo install -d -o deploy -g deploy /srv/example-app
```

The clone of the `vps-stack` repository may live somewhere other than
`/opt/vps-stack`: the scripts work out their location from their own path.

## System files changed by provisioning

| File | Content |
|---|---|
| `/etc/ssh/sshd_config.d/00-hardening.conf` | sshd hardening |
| `/etc/systemd/system/ssh.socket.d/override.conf` | SSH port with socket activation (`ssh-port` only) |
| `/etc/default/ufw` | `IPV6=yes` |
| `/etc/fail2ban/jail.local` | the `sshd` jail |
| `/etc/apt/apt.conf.d/20auto-upgrades`, `52vps-stack-unattended-upgrades` | automatic updates |
| `/etc/hostname`, `/etc/hosts`, `/etc/cloud/cloud.cfg.d/99-vps-stack-hostname.cfg` | host name and its `127.0.1.1` line, kept by cloud-init (only with `SERVER_HOSTNAME`) |
| `/etc/systemd/journald.conf.d/size.conf` | journal limit of 200 MB |
| `/etc/sysctl.d/99-vps-stack.conf` | `vm.swappiness`, `vm.vfs_cache_pressure` |
| `/etc/docker/daemon.json` | log rotation, `live-restore` (merged with an existing file) |
| `/etc/apt/sources.list.d/docker.list`, `/etc/apt/keyrings/docker.asc` | Docker repository |
| `/etc/cron.d/vps-stack-docker-cleanup`, `/etc/cron.d/vps-stack-backup` | scheduled jobs |
| `/etc/logrotate.d/vps-stack` | rotation of the vps-stack logs |
| `/etc/fstab`, `/swapfile` | swap file |
| `/usr/local/bin/vps-stack` | symlink to `bin/vps-stack` |

The optional status page (`vps-stack monitor enable`) adds, and `disable`
removes:

| File | Content |
|---|---|
| `/etc/systemd/system/vps-stack-monitor.service` | collector writing `status.json` every 10 seconds |
| `/etc/tmpfiles.d/vps-stack-monitor.conf` | creates `/run/vps-stack-monitor/` at boot, before Docker starts Caddy |
| `/etc/fail2ban/jail.d/vps-stack-monitor.local`, `filter.d/vps-stack-monitor.conf`, `action.d/vps-stack-monitor.conf` | the `vps-stack-monitor` jail |
| `/etc/vps-stack/monitor.env`, `monitor-banned.list` | domain and login; addresses banned by fail2ban (600) |
| `/etc/vps-stack/sites/_monitor.caddy`, `sites/.monitor-banned` | the site (600, holds the password hash) and the ban list it imports |
| `/var/log/vps-stack-monitor/access.log` | access log of the status page, rotated by Caddy (kept after `disable`) |
| `/var/lib/vps-stack-monitor/history.jsonl` | 7 days of history samples, one every 5 minutes (removed by `disable`) |

Before an existing file is changed, a copy `<file>.bak.<date-time>` is made.

## Proxy

The Caddy configuration consists of `proxy/Caddyfile` (in the repository) and
the site files in `/etc/vps-stack/sites/` (generated by `add-site`). The
Caddyfile defines a shared `common` snippet (compression and security
headers), and every site imports it.

The container runs with dropped capabilities (`cap_drop: ALL` plus only
`NET_BIND_SERVICE`), with `no-new-privileges` and a 256 MB memory limit. The
Docker socket is not mounted into it.

While the status page is enabled, `vps-stack proxy` adds
`proxy/docker-compose.monitor.yml`, which mounts the page
(`monitor/www/`) and `/run/vps-stack-monitor/` read-only and the log
directory of the status page writable. The directory is mounted rather than
the file, so the container sees every new `status.json` at once.

A practical note: `proxy/Caddyfile` is mounted as a single file. When an
update of `vps-stack` replaces it, the running container still sees the old
version.
After an update that changes this file, run `sudo vps-stack proxy restart`.
