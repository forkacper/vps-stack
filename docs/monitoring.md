# Monitoring

The minimum for one person and one server. `vps-stack` deliberately installs
no monitoring system: below is what is worth setting up yourself, most
important first.

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

Set `HC_URL` in `/etc/vps-stack/restic.env`. The backup script calls
`<HC_URL>/start`, and at the end `<HC_URL>` (success) or `<HC_URL>/fail`.

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

## 5. Optional: server metrics (Netdata)

Charts of CPU, memory, disk and network with alerts. `vps-stack` does not
install it, because it is one more service to maintain and uses more memory.

If you want it:

- install it following the official Netdata documentation, **downloading the
  installer script to a file and reading it before running it** (not piped
  straight into a shell), or use the package from the distribution repository,
- **do not open the dashboard port in ufw.** It should listen on `127.0.0.1`,
  and you connect through an SSH tunnel:
  `ssh -L 19999:127.0.0.1:19999 admin@<server>`,
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
