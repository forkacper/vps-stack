# Monitoring

The minimum for one person and one server. `vps-stack` deliberately installs
no monitoring system by default (the status page in section 5 is optional):
below is what is worth setting up yourself, most important first.

The principle: **monitoring has to run outside the server.** A server that is
down will not send an alert saying that it is down.

## 1. External uptime check

A service outside the server requests each project's URL every few minutes and
notifies you when it stops responding.

- Check the **application's health endpoint** (e.g.
  `https://app.example.com/health`), not the home page. It should return 200
  only when the application can reach its database.
- Turn on certificate expiry checking, if the service offers it.
- Send notifications to a channel you will actually notice.

## 2. Backup monitoring

A backup that silently stopped working comes to light at the worst moment. Use
a "dead man's switch" service (e.g. healthchecks.io): the alarm goes off when
a ping does **not** arrive.

Set `HC_URL` in `/etc/vps-stack/backup/<group>.env`, one monitor per
group. The backup script calls `<HC_URL>/start`, and at the end `<HC_URL>`
(success) or `<HC_URL>/fail`.

Check settings: a period of 6 hours, a grace time of a few hours.

## 3. Application error tracking

Collect exceptions and 500 errors in an error tracking tool integrated with
the application. That is the project's business, not the server's, but without
it you learn about errors from your users.

## 4. Regular review

Once a week, or after every change:

```bash
sudo vps-stack verify
```

Among other things it shows disk usage, a pending reboot, the state of the
proxy, ports exposed to the internet and the age of the last backup.

## 5. Optional: the built-in status page

A read-only page in the browser with the current state of the server: CPU,
memory, swap, disk and load, and every container with its image, state,
health check, uptime, restarts, CPU and memory. It refreshes every 10
seconds, and shows the history of the last 24 hours or 7 days as charts: CPU
(average and highest), memory, disk and load, and a 24-hour memory trend of
every container. It is **disabled by default** and is meant for looking at
the server, not for alerting: it sends no notifications.

```bash
sudo vps-stack monitor enable status.example.com
```

The domain needs a DNS record pointing at the server, like any site. The
command generates a login and a password and shows the password **once**:
save it in your password manager. A new password:
`sudo vps-stack monitor password`. The state:
`sudo vps-stack monitor status`. Removal: `sudo vps-stack monitor disable`.
After updating `vps-stack`, `sudo vps-stack monitor refresh` brings an
enabled page in line with the new version; the password stays. After a password change, an open page stops refreshing and asks to
be reloaded: it never keeps sending the old password in the background,
which fail2ban would count as failed logins.

How it works:

- A small collector (systemd service `vps-stack-monitor`) writes
  `/run/vps-stack-monitor/status.json` every 10 seconds. It asks Docker for a
  fixed list of fields only (name, image, state, health, start time,
  restarts, CPU, memory). **Environment variables, labels, mounts, ports,
  networks and logs are never read**, so they cannot reach the page.
- Every 5 minutes it also appends a history sample (CPU average and highest
  over those 5 minutes, memory, swap, disk, load, and the memory of every
  running container) to `/var/lib/vps-stack-monitor/history.jsonl`. The file
  keeps 7 days (about 2,000 lines) and survives reboots; the page reads it as
  `history.json`. A gap in the charts means the server or the collector was
  down.
- Caddy serves the page and the data files at the domain. Nothing that runs
  in a container gets access to Docker: the page has no backend and Caddy
  only reads a file.
- Access requires the login and password (HTTPS, the password is stored only
  as a bcrypt hash).
- fail2ban counts failed logins (wrong password). 5 within 10 minutes ban the
  address for 1 hour, **on the status page only**: the ban happens inside
  Caddy, not in the firewall, so the address can still reach your other
  sites. Private and Docker addresses are never banned.

Enabling and disabling restart the proxy container (a few seconds without any
site), because Caddy gets two extra read-only mounts.

What to know:

- If somebody obtains the login and password, they see what the page shows:
  container names, image versions and resource usage. Not secrets.
- IPv6 clients are seen with their real address, so they are banned like
  IPv4 ones, as long as the `proxy` network has IPv6 (`verify` reports it).
  On a network created by `vps-stack` 0.4.2 or older they show up as a
  Docker gateway, which is never banned; run once
  `sudo vps-stack proxy network-ipv6` ([architecture.md](architecture.md)).
- The page is not a replacement for the external uptime check above: when
  the server is down, the page is down too.

## 6. Optional: server metrics (Netdata)

Charts of CPU, memory, disk and network with alerts. `vps-stack` does not
install it, because it is one more service to maintain and uses more memory.

If you want it:

- install it following the official Netdata documentation, **downloading the
  installer script to a file and reading it before running it** (not piped
  straight into a shell), or use the package from the distribution repository,
- **do not open the dashboard port in ufw.** It should listen on `127.0.0.1`,
  and you connect through an SSH tunnel:
  `ssh -L 19999:127.0.0.1:19999 sysadmin@<server>`,
- after installing, run `sudo vps-stack check-ports` and make sure nothing new
  listens on all interfaces.

## Alert thresholds

| What | Threshold | Why |
|---|---|---|
| Disk usage | above 75% | a full disk stops databases and breaks dumps |
| Available RAM | below 500 MB | a sign that the kernel is about to kill processes |
| Swap activity | constant paging, not mere usage | swap in use is fine; constant traffic means too little memory |
| Certificate expiry | e.g. less than 14 days for 90-day certificates | Caddy renews certificates ahead of time; an approaching expiry means renewal is not working. Pick the threshold to match the lifetime of your certificates |
| Backup age | more than 13 hours | two missed runs in a row |
| Site availability | 2-3 failed attempts in a row | a single one may be a passing network error |
| Reboot required | for longer than a week | kernel fixes not loaded |

`vps-stack verify` warns about the disk at 70% and reports an error at 90%,
and warns about the backup after 13 hours and reports an error after 48.

## What is not here

Central log collection, application metrics or request tracing. With one small
server, `docker compose logs` and `journalctl` are usually enough; when they
stop being enough, that is a sign the scale has outgrown what this project is
meant for.
