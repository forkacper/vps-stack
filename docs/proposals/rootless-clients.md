# Proposal: clients isolated with rootless Docker

> **Status: future prospect, not planned for implementation.** Nothing in
> this document exists in `vps-stack` yet. It records the design discussed so
> far, so that the work can start from it once there is a real need.

## Problem

Today `vps-stack` knows projects only, and every project runs on the one
system Docker daemon. Access to that daemon is root on the whole server: a
person who can run `docker` sees every project's containers, databases and
secrets. Linux permissions cannot narrow that down.

The goal: several **clients** on one server, each with their own projects,
where a client can manage their own containers (including a shell with
`docker compose`) without seeing or affecting anybody else's.

## When this is the right tool

| Need | Simpler answer |
|---|---|
| the client only needs "deploy", "restart", "logs" | an SSH key with a forced command running one vetted script; no Docker access for the client |
| the client needs full freedom, or has contractual separation requirements | a separate small VPS per client, provisioned with `vps-stack` as it is |
| several clients on one server, each managing their own containers | **this proposal** |

Start this work only when the third row describes a real situation. A
separate VPS remains the strongest isolation (own kernel, own resources) and
needs no new code.

## Design

```
Internet ──80/443──► Caddy (system Docker, network_mode: host)
                       │  one ACME account, the shared `common` snippet
                       │
                       ├─ shop.client-a.example ──► unix socket /run/vps-stack/clients/client-a/<project>.sock
                       │                               └─ rootless Docker of user `client-a`
                       │                                   (web, app, db of client A)
                       └─ app.client-b.example  ──► unix socket /run/vps-stack/clients/client-b/<project>.sock
                                                       └─ rootless Docker of user `client-b`
```

- **One Linux account per client**, with its own rootless Docker daemon
  (`dockerd-rootless-setuptool.sh`, socket
  `unix:///run/user/<uid>/docker.sock`, kept running with
  `loginctl enable-linger <user>`). A client's containers, images, networks
  and volumes live in that daemon only. Root inside a client container maps
  to an unprivileged user on the host.
- **One shared edge proxy.** Only one process can own ports 80 and 443, and a
  rootless daemon cannot bind them without extra privileges. Caddy stays the
  single entry point: certificates, security headers and the mapping of
  domains to clients stay in one place, and a client cannot take over
  another client's domain.
- **Caddy moves to the host network** (`network_mode: host`). It can no
  longer reach containers by name over the shared `proxy` network, because
  every client has separate networks. A side effect: ports 80 and 443 stop
  bypassing ufw, since Caddy listens on the host directly.
- **Upstreams are unix sockets, not ports.** The web server of a client
  project listens on a socket in a directory bind-mounted from
  `/run/vps-stack/clients/<client>/`; Caddy proxies to it
  (`reverse_proxy unix//...`). The directory belongs to the client and is
  readable by Caddy's group only. A port on `127.0.0.1` would work too, but
  every local account could connect to it and bypass Caddy (and with it any
  login in front of the site); file permissions on a socket prevent that.
- **The operator's own projects** move to the same model (socket upstreams),
  either on the system daemon or under an "operator" client. One upstream
  model is simpler than two.

## Changes by area

| Area | Change |
|---|---|
| `provision` | packages for rootless mode (`uidmap`, `dbus-user-session`, `docker-ce-rootless-extras` or the distribution equivalent); cgroup v2 check; Caddy on the host network |
| new: `vps-stack client add\|remove\|list` | account, subordinate UID/GID ranges (`/etc/subuid`, `/etc/subgid`, at least 65,536 each), rootless daemon, linger, socket directory, resource limits, SSH key |
| resource limits | a systemd slice per client (`MemoryMax`, `CPUQuota`, `TasksMax`); `docker run --memory/--cpus` inside rootless mode work only with cgroup v2 and systemd |
| disk | per-client usage reporting at least; hard limits (filesystem quotas) to be evaluated in the prototype |
| `add-site` | upstream `client/project` resolved to the socket path, instead of `container:port`; ownership check: a domain is attached to one client |
| project contract | the web server listens on the socket in the mounted directory; no `ports:` at all |
| client access | either a full shell with their own daemon, or the forced-command interface (deploy, restart, logs) for clients who need no shell |
| backup | one restic repository per project, as in the planned per-project backup; hooks run `docker` against the client's daemon (`DOCKER_HOST`) |
| status page | the collector reads every daemon; a per-client view with its own login shows only that client's containers |
| `check-ports`, `verify` | per-client daemons, sockets, linger and slices |

## Risks to check first

- **AppArmor on Ubuntu 24.04+.** Unprivileged user namespaces are restricted
  by default. The deb package ships the AppArmor profile for rootlesskit; the
  installation script does not. Verify on 24.04 and 26.04.
- **Source IP.** Connections reach Caddy directly on the host, so the client
  address stays correct at the edge. Inside a rootless daemon, source IP
  propagation depends on the RootlessKit version and port driver; it matters
  only if a client publishes ports itself, which the socket model avoids.
- **Shared kernel.** User namespaces add kernel attack surface, and a client
  with a shell is a local user: a local privilege escalation in the kernel
  affects everybody. Keep shells optional and the kernel updated
  (`AUTO_REBOOT` or regular reboots).
- **Noisy neighbours.** Without slices and disk limits one client can
  exhaust the server for the others.
- **Images and storage.** Every daemon keeps its own images and layers: more
  disk than one shared daemon.
- **Application support for sockets.** nginx and Caddy can listen on a unix
  socket; check every project's web server.

## Phases

0. **Prototype on a disposable VPS** (24.04 and 26.04): rootless daemon for
   a test account, AppArmor, linger across reboots, a slice with limits, Caddy
   on the host network proxying to a socket. Docker Desktop cannot answer
   these questions.
1. **Socket upstreams and Caddy on the host network** for the existing
   projects. Breaking change: a minor release in `0.x` with migration steps.
2. **Client accounts**: `vps-stack client add|remove|list`, rootless daemon,
   slices, socket directories.
3. **Client access**: shell or forced-command interface.
4. **Backup and status page per client.**
5. **Documentation and the manual test procedure** in
   [testing.md](../testing.md).

Each phase is a separate release. Phase 0 decides whether to continue: if
the prototype shows the cost is too high, the answer for clients stays "a
separate VPS".

## Open questions

- Hard disk limits per client: filesystem quotas, a separate filesystem per
  client, or monitoring only?
- Does the operator's own work move under an "operator" client, or stay on
  the system daemon with socket upstreams?
- Which client access to offer by default: shell or forced commands?
- Domain ownership: who may attach a domain to a client, and how is it
  recorded?
