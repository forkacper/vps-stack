# Design decisions

Short reasons for the choices made, so that the same discussions do not have
to be repeated and it is clear when a choice is worth revisiting.

## Docker instead of native installation

Every project brings its own environment in an image, so there is no fight
over the PHP or Node versions available in the distribution repositories and
no conflicts between projects. A project starts the same way locally and on
the server, and removing it leaves no traces in the system. The cost is one
more layer to understand and the fact that Docker manages network rules on its
own.

## Caddy instead of Nginx or Traefik

Caddy does automatic HTTPS without additional tools, and the configuration of
one site is three lines. Fewer parts means fewer things to break. Traefik, in
its typical Docker setup, reads container labels through the Docker socket,
which is deliberately not given to anyone here; Nginx in a classic setup needs
a separate ACME client and its schedule.

## ufw instead of raw iptables rules

ufw is enough for a "drop everything except SSH, 80 and 443" policy and is
readable to someone who does not deal with networking every day. Docker
manages its own chains and hand-written rules easily get in its way, which is
why the scripts add no rules to the `DOCKER-USER` chain and do not install
`iptables-persistent`. The consequence: ports published by Docker bypass ufw,
so the "only the proxy publishes ports" rule is enforced by `check-ports`, not
by the firewall.

## Bash instead of Ansible

The target is one server and one person. Idempotent bash gives the same result
as a playbook, without another tool on the administrator's computer and
without a new language to learn. With several servers this decision stops
making sense, and the right step then is moving to a configuration management
tool, not growing these scripts.

## Configuration outside the repository

The code lives in `/opt/vps-stack`, the settings in `/etc/vps-stack`. This
way `git pull` never overwrites local settings, there are no secrets in the
repository, and the configuration directory can be kept in your own private
repository.

## No interactive wizard in 0.1

A wizard is more code to maintain and test, and the first version is meant to
be small. The whole provisioning configuration is a single `stack.env` file,
so a future wizard can simply generate that file, without changes to the other
scripts.

## No automatic reboot

`AUTO_REBOOT` is off by default. An unattended reboot at 04:00 on the only
server means downtime for all projects and the risk that something does not
come back while nobody is watching. Instead `verify` warns that a reboot is
needed, and a human picks the moment. Whoever prefers the opposite trade-off
sets `AUTO_REBOOT=true`.

## 2 GB of swap

On a server with 2-4 GB of RAM a momentary spike in memory use without swap
ends with a process being killed, often the database. A small swap file with
`vm.swappiness=10` gives headroom for such spikes, while the system still uses
it reluctantly. It is a safety net, not extra memory: constant swap use means
the server is too small.

## Only one target system

The target system is Ubuntu 26.04 LTS; 24.04 uses the same code. Every
additional system brings its own differences in SSH, repositories and updates
that one person cannot test reliably. That is why Debian has only a skeleton
in `lib/os-debian.sh` and an explicit refusal to run, and the statuses in the
README change only after a real test.

## Detecting instead of assuming

Ubuntu 26.04 is a fresh release and the details of its behaviour may differ
from earlier ones. So the scripts check on the spot: whether Docker publishes
a repository for the codename, whether sshd runs through `ssh.socket`, whether
`sshd_config` includes the `sshd_config.d` directory, what the SSH service is
called. When something cannot be determined, the script stops with a message
instead of guessing. For the same reason only basic options of system tools
are used, and administrator rights come from membership of the `sudo` group,
not from a sudoers file of our own.

## `add-site` validates its input

The arguments of `add-site` end up in a Caddy configuration file executed by a
process with access to the certificates. A newline or a curly brace in a
domain name would allow any directive to be appended. That is why every value
has to match a strict pattern, the template is filled in by plain text
substitution without `eval` and without shell expansion, and rendering refuses
to work before it produces anything from invalid data. Wildcards and non-ASCII
domains are rejected in 0.1, because that keeps the pattern simple.

## HSTS without `includeSubDomains` and `preload`

The shared snippet sets `Strict-Transport-Security` with `max-age` only.
`includeSubDomains` forces HTTPS on all subdomains, including those hosted
elsewhere, and `preload` is practically irreversible. Both should be a
conscious decision for a particular domain. When a new domain goes live for
the first time it is worth starting with a shorter `max-age` (e.g. an hour)
and extending it once HTTPS works reliably: the browser remembers the value
and a mistake cannot be taken back quickly.

## No CSP in the shared snippet

Content-Security-Policy depends on where a given application loads its
scripts, styles and images from. One shared policy would be either too loose
to be worth anything or would break some of the projects. So the application
sets its own CSP.

## A proxy container with minimal privileges

Caddy runs with `cap_drop: ALL`, only `NET_BIND_SERVICE`, `no-new-privileges`
and a memory limit. It has no access to the Docker socket, and the Docker API
is not exposed over TCP. The proxy is the only container reachable from the
internet, so compromising it should yield as little as possible.

## A separate command for changing the SSH port

Changing the port is the easiest way to lock yourself out of the server, and
how it is done depends on whether the system uses `ssh.socket`. That is why it
is not part of provisioning: `ssh-port` detects the variant, opens the new
port in the firewall before the change and closes the old one only after a
confirmation from a new session.

## Backup: restic, one repository per project

restic deduplicates and compresses, checks the integrity of its data and
supports many backends, so moving the copies elsewhere later is a change of
one setting. Its encryption matters little while a repository lives on the
same server (whoever has root there reads the live data anyway), and it
cannot be switched off; the password is therefore generated and stored for
the user, who needs to keep it only once the copies leave the server.

Every project has its own repository and password: a project's backup can be
restored, handed over or moved without touching the others, and different
projects can later be kept in physically separate places. The repositories
live on the server by default, which protects against mistakes in the
applications but not against losing the server; the documentation says so
plainly instead of hiding it. Repository credentials and passwords are never
part of any backup.

Dumps are plain SQL: a compressed dump looks new every time and defeats the
deduplication.

## Version pinning

The Caddy image and the CI actions are pinned to specific versions. There are
no automatic image updates (e.g. Watchtower): updating the proxy on the only
server should be a conscious step taken after reading the changelog.
