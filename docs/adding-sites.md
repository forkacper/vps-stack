# Adding sites

## Order matters: DNS first, certificate second

When Caddy gets a new domain, it tries to obtain a certificate for it right
away. If DNS does not point at the server yet, the attempt fails, and
certificate authorities **rate-limit failed attempts**. A few mistakes can get
you blocked for a longer time.

So:

1. Start the project (the web container has to be on the `proxy` network).
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
- second: `container-name:port` of the project's web server on the `proxy`
  network.

The command, in order:

1. validates the arguments (rejects anything that is not a plain domain name
   and a plain upstream),
2. checks that the domain is not already configured in another file,
3. checks DNS,
4. checks that the upstream container is on the `proxy` network,
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

## Limitations in version 0.1

- No wildcards (`*.example.com`).
- ASCII domains only; give internationalised names in punycode (`xn--...`).
- One upstream per site, one template. You can write a custom configuration by
  hand as your own `*.caddy` file in `/etc/vps-stack/sites/`, but `add-site`
  and `list-sites` only understand files generated from the template.

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
