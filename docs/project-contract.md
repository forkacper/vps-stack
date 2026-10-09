# Project contract

What a project (its Docker Compose file and the application itself) has to
satisfy to work well with `vps-stack`. The examples use a fictional project
called `example-app`. A skeleton Compose file:
`examples/project-compose.yml.example`. A GitHub Actions workflow that builds
the project's image outside the server, with the deploy and rollback steps:
`examples/project-build-workflow.yml.example`.

## 1. The shared network is external

Provisioning creates the proxy network, with IPv6 enabled so that Caddy sees
the real address of IPv6 clients. A project does not create it, it only
joins it:

```yaml
networks:
  proxy:
    external: true
  internal:
```

The network name comes from `PROXY_NETWORK` in `/etc/vps-stack/stack.env`
(default `proxy`).

## 2. Only the web container joins the proxy network

The container with the web server (e.g. nginx) is the project's only container
on the `proxy` network and has a **unique name**
(`container_name: example-app-web`): that name is the upstream given to
`add-site`.

The database, Redis, workers and everything else are on the project's internal
network only.

Put services that process content coming from outside (document renderers,
headless browsers, converters) on a **separate** network, visible only to the
application that uses them. Compromising such a service should not give access
to the database.

## 3. The project publishes no ports

No `ports:` at all. Ports published by Docker **bypass the firewall**.

The only exception is publishing on localhost, e.g. to reach the database
through an SSH tunnel:

```yaml
ports:
  - "127.0.0.1:3306:3306"
```

To check: `sudo vps-stack check-ports`.

## 4. The proxy is not part of the project

A project does not run its own Caddy, Traefik or an nginx listening on 80 and
443. HTTPS and certificates are handled by the shared proxy, and the project
receives plain HTTP traffic on the `proxy` network.

## 5. Trusted proxies

Traffic flows: Caddy → the project's web server → the application. So the
application sees an HTTP connection from an internal address, and learns about
the real client and about HTTPS from the `X-Forwarded-For` and
`X-Forwarded-Proto` headers set by Caddy.

Two conditions:

- **The project's web server passes these headers on unchanged.** A common
  mistake is overwriting `X-Forwarded-Proto` with the web server's own scheme
  (which sees HTTP). The application then concludes that the connection is not
  encrypted.
- **The application has trusted proxies configured** and believes these
  headers only from addresses on the Docker network.

Symptoms of a wrong configuration: redirect loops to HTTPS, links generated
with `http://`, session cookies without the `Secure` flag, wrong OAuth
callback URLs, the proxy's address instead of the client's in logs and rate
limits.

The proxies to trust are the private address ranges, which is where Docker
networks live: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` and, because
the `proxy` network has IPv6, `fc00::/7`. Do not list single addresses:
containers get new ones when they are recreated. Trusting these ranges is
safe because the application is reachable only through the proxy (sections 2
and 3).

**The project's web server (nginx).** In front of PHP-FPM nothing is needed:
request headers reach the application as they came. In front of an
application server (`proxy_pass`), pass them on instead of replacing them:

```nginx
proxy_set_header Host              $host;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;   # not $scheme
```

**Laravel** (11 and newer), `bootstrap/app.php`:

```php
->withMiddleware(function (Middleware $middleware) {
    $middleware->trustProxies(at: [
        '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', 'fc00::/7',
    ]);
})
```

In Laravel 10 and older the same list goes into `$proxies` of
`App\Http\Middleware\TrustProxies`.

**Symfony**, `config/packages/framework.yaml`:

```yaml
framework:
  trusted_proxies: 'private_ranges'
  trusted_headers: ['x-forwarded-for', 'x-forwarded-host', 'x-forwarded-proto', 'x-forwarded-port']
```

**Django**, `settings.py`. Django has no list of trusted proxies; these
settings believe the headers from anyone, which is acceptable only because
the application is not reachable in any other way:

```python
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
USE_X_FORWARDED_HOST = True
```

With gunicorn behind nginx also start it with `--forwarded-allow-ips` naming
the ranges above. The client address is the first entry of
`X-Forwarded-For`; `REMOTE_ADDR` is the proxy.

**Rails** trusts the private ranges by default
(`config.action_dispatch.trusted_proxies`), so `request.remote_ip` and
`request.ssl?` work as they are. With `config.force_ssl = true` nothing more
is needed.

**Express**:

```js
app.set('trust proxy', 'loopback, linklocal, uniquelocal');
```

For any other framework look for "trusted proxies" or "forwarded headers" in
its documentation and check the result: log in over HTTPS, then look at the
client address in the application log and at the `Secure` flag of the
session cookie.

## 6. A consistent upload size limit

The limit applies in several places at once and the smallest one wins:

- the project's web server,
- the application and its runtime,
- optionally the proxy: `add-site ... --max-body 50MB`.

Set them consistently. By default `add-site` sets no limit on the proxy side.

## 7. Memory limits and restart policy

Every service has `mem_limit` and `restart: unless-stopped`.

On a server with 2-4 GB of RAM one container without a limit can cause an
out-of-memory condition for everyone. The sum of the limits should leave
headroom for the system. `restart: unless-stopped` makes the project come back
after a server reboot.

## 8. Backup hook and a dedicated database user

A project with data has its backup group (`vps-stack backup init
<project>`) and hooks in `/etc/vps-stack/hooks/<project>/` that dump the
database (see `examples/backup-hook-mysql.sh.example`) and name the
directories holding user files (`examples/backup-hook-files.sh.example`).

User files live in a **bind mount below the project directory** (e.g.
`./storage/uploads:/var/www/storage/uploads`), not in a named Docker volume:
the hook can name a plain, stable path.

The dump is made by a **dedicated database user** with minimal privileges, not
by the database root and not by the application's user.

Details of the hook contract: [backup-restore.md](backup-restore.md).

## 9. Health endpoint

The application exposes a lightweight URL (e.g. `/health`) that returns 200
only when it really works (including the database connection). That is the URL
you give to external monitoring: [monitoring.md](monitoring.md).

## 10. Passwords on auxiliary services

Redis, the database and similar services have passwords set, **on the internal
network too**. Network isolation is one layer; the password is a second one,
in case the first fails (e.g. a container attached to the wrong network by
mistake).

## 11. Ready for `vps-stack deploy`

A project that is deployed with `vps-stack deploy` (by hand or from a CI)
brings no script for it. It provides:

- a **Dockerfile**;
- a compose file in which the **tag of the application image comes from a
  variable** in `.env`, `APP_TAG` by default:

  ```yaml
  image: ghcr.io/example-owner/example-app:${APP_TAG:?set APP_TAG in .env}
  ```

- **healthchecks** on the services that matter, so that a deploy can tell a
  working release from one that only started;
- the **migration command**, as plain words (`php artisan migrate --force`),
  with migrations that stay compatible with the previous version of the
  code.

Details: [deploying.md](deploying.md).

## Checklist

- [ ] the `proxy` network as `external: true`
- [ ] only the web container on the `proxy` network, with a unique
      `container_name`
- [ ] no `ports:` (or `127.0.0.1:` only)
- [ ] no proxy of its own on 80/443
- [ ] `X-Forwarded-*` headers passed on, trusted proxies set in the application
- [ ] a consistent upload limit
- [ ] `mem_limit` and `restart: unless-stopped` on every service
- [ ] a backup group, hooks and a dedicated database user
- [ ] user files in a bind mount below the project directory
- [ ] a health endpoint wired into monitoring
- [ ] passwords on auxiliary services
- [ ] the image tag from a variable in `.env`, healthchecks and a migration
      command, for `vps-stack deploy`
