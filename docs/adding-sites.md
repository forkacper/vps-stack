# Adding sites

## Order matters: DNS first, certificate second

When Caddy gets a new domain, it tries to obtain a certificate for it right
away. If DNS does not point at the server yet, the attempt fails, and
certificate authorities **rate-limit failed attempts**. A few mistakes can get
you blocked for a longer time.

So:

1. Create the project's network (`sudo vps-stack network create <project>`)
   and start the project with its web container on it
   ([project-contract.md](project-contract.md)).
2. Point the domain's `A` record at the server's IPv4 address. Set an `AAAA`
   record only if the server has working IPv6, and to the right address. **A
   wrong or stale `AAAA` record breaks certificate issuance even when `A` is
   correct.**
3. Check: `vps-stack check-dns app.example.com`
4. Only then: `sudo vps-stack add-site ...`

## Basic usage

```bash
sudo vps-stack add-site app.example.com example-app-web:80
```

- first argument: the domain,
- second: `container-name:port` of the project's web server, on the project's
  network.

The command, in order:

1. validates the arguments (rejects anything that is not a plain domain name
   and a plain upstream),
2. checks that the domain is not already configured in another file,
3. checks DNS,
4. checks that the upstream container runs and shares a network with Caddy,
5. writes `/etc/vps-stack/sites/<domain>.caddy`,
6. validates the whole Caddy configuration; on an error it **rolls the change
   back** and stops, and the proxy keeps running as before,
7. reloads Caddy without downtime.

Preview without changes: add `--dry-run`.

Running it again with the same arguments changes nothing. Changing the
settings of an existing site needs `--force` (the previous version of the file
stays as `*.bak.<date-time>`).

## Options

### Aliases: `--alias`

Additional domains served by the same application, without a redirect:

```bash
sudo vps-stack add-site example.com example-app-web:80 --alias app.example.com
```

### Redirects: `--redirect-from`

Domains that should redirect (301) to the main domain, keeping the path:

```bash
sudo vps-stack add-site example.com example-app-web:80 --redirect-from www.example.com
```

Every domain given with `--alias` and `--redirect-from` needs correct DNS too:
Caddy obtains a certificate for each of them.

### Request size limit: `--max-body`

```bash
sudo vps-stack add-site example.com example-app-web:80 --max-body 50MB
```

Units: `KB`, `MB`, `GB`. Set the same limit in the project's web server and in
the application (see [project-contract.md](project-contract.md)).

### DNS check: `--server-ip`, `--no-dns-check`

By default the server's public address is fetched from an external service. If
it is unreachable or you do not want to rely on it, pass the address yourself:

```bash
sudo vps-stack add-site example.com example-app-web:80 --server-ip 192.0.2.10
```

The option may be given twice (IPv4 and IPv6). `--no-dns-check` skips the
check entirely: use it only when you know why the result is a false negative
(e.g. the domain sits behind an external DNS proxy).

On a DNS mismatch the command asks whether to continue. `--yes` does **not**
answer that question with yes: in no-questions mode you have to pass
`--no-dns-check` explicitly.

### Only some paths: `--paths`

Serves only the listed paths (a trailing `*` matches a prefix) and answers
404 for everything else, e.g. a host that exists only for a webhook and a
health check:

```bash
sudo vps-stack add-site hooks.example.com example-app-web:80 --paths /webhook,/health
```

## Many hosts: a wildcard or any host, with on-demand TLS

Some applications serve hosts nobody lists in advance: a subdomain for every
customer (`<customer>.example.com`), or the customers' own domains pointed at
the server. `add-site` takes them with `--on-demand-tls`:

- `'*.example.com'`: every subdomain of one label (`a.example.com`, not
  `a.b.example.com`). DNS: a wildcard record `*.example.com`.
- `'*'`: any host no other site serves. Explicit sites and wildcards always
  win over it. DNS: the customers' records, pointed at the server.

Quote both, so that the shell does not expand them.

With on-demand TLS Caddy obtains a certificate for a host on its **first
visit** (a few seconds once) and renews it like any other. Before that it
asks an endpoint of yours whether the host is allowed; only a 2xx answer is.
Without that check anyone could point names at the server and make it
request certificates until the certificate authority's limits are used up,
so Caddy refuses on-demand TLS without the endpoint, and so does `add-site`.

```bash
# 1. The endpoint: Caddy adds ?domain=<host>; answer 2xx only for hosts your
#    application serves. A container on a project network, or a public URL.
sudo vps-stack on-demand-tls set http://example-app-web/tls-check
# 2. The sites
sudo vps-stack add-site '*.example.com' example-app-web:80 --on-demand-tls
sudo vps-stack add-site '*' example-app-web:80 --on-demand-tls
# 3. The endpoint refuses a host nobody owns
sudo vps-stack verify
```

`vps-stack on-demand-tls show` prints the endpoint, `unset` removes it (only
once no site uses it). There is one endpoint per server, so the application
behind it decides for every on-demand site of the server.

- The DNS check of a wildcard looks up a random name under it; `'*'` has no
  name to check.
- A wildcard or any host takes no `--alias` or `--redirect-from`: redirects
  between the customers' hosts belong to the application.
- Let's Encrypt allows 50 new certificates a week per registered domain
  (`example.com` and all its subdomains together); renewals do not count.
  Each customer's own domain has its own limit. Above that, a single
  wildcard certificate needs the DNS-01 challenge and a Caddy build with your
  DNS provider's module, which `vps-stack` does not ship.
- `remove-site '*.example.com'` and `remove-site '*'` remove them like any
  site; the certificates already issued stay in Caddy's storage until they
  expire.

## Limitations

- ASCII domains only; give internationalised names in punycode (`xn--...`).
- One upstream per site, one template. You can write a custom configuration by
  hand as your own `*.caddy` file in `/etc/vps-stack/sites/`; `add-site`
  checks its hosts for duplicates and `list-sites` shows it as "not written
  by add-site" when it has no plain `reverse_proxy`.

## Testing against the staging environment

To exercise the whole path without the risk of exhausting the production rate
limits, switch the proxy to the Let's Encrypt staging environment:

```bash
sudoedit /etc/vps-stack/proxy.env
# ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory
sudo vps-stack proxy up
sudo vps-stack add-site app.example.com example-app-web:80
```

A staging certificate is **not trusted** by browsers: a certificate warning is
expected then. You can check the issuer with:

```bash
curl -vkI https://app.example.com 2>&1 | grep -i issuer
```

**After testing, go back to the production CA:**

```bash
sudoedit /etc/vps-stack/proxy.env      # ACME_CA= (empty value)
sudo vps-stack proxy up                # the container is recreated
```

`proxy reload` alone is not enough: the CA address is an environment variable
of the container. After switching back, Caddy obtains production certificates;
check the issuer once more.

## Listing and removing

```bash
sudo vps-stack list-sites
sudo vps-stack remove-site app.example.com
```

`remove-site` does not delete the file: it moves it to
`/etc/vps-stack/sites/.removed/<domain>.caddy.<date-time>`, validates the
configuration and reloads the proxy. DNS records and certificates already
issued stay: remove the records at your domain provider.

## When something does not work

- `sudo vps-stack proxy logs`: Caddy logs, including certificate issuance
  errors.
- A 502 error: the upstream container is not running or is not on the `proxy`
  network.
- `sudo vps-stack proxy validate`: check the configuration without changing
  anything.
- Ports 80 and 443 have to be reachable from the internet (also check the
  firewall in the provider's panel, if there is one).
