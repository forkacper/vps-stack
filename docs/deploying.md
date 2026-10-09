# Deploying projects

`vps-stack deploy` releases a version of a project with one command: it
pulls or builds the image, runs the migrations, replaces the containers,
waits until they are healthy and goes back to the previous version when
something fails. A pipeline can start it over SSH with a key that can do
nothing else.

The project brings no deploy script of its own. Nothing here knows about a
particular CI service: whatever can run `ssh` can deploy.

The examples use a fictional project called `example-app`.

## What the project provides

- A **compose file** in `/srv/example-app` whose application image takes its
  tag from a variable in `.env`:

  ```yaml
  image: ghcr.io/example-owner/example-app:${APP_TAG:?set APP_TAG in .env}
  ```

  A deploy is a change of that one line in `.env`, followed by
  `docker compose up`.
- A **Dockerfile**, built by the CI (mode `image`) or on the server (mode
  `build`).
- **Healthchecks** on the services that matter. A deploy waits for them;
  without a healthcheck "the container started" is all it can know, and an
  application that crashes a few seconds later passes for a good release.
- The **migration command**, if the project has a database, as plain words:
  `php artisan migrate --force`, `python manage.py migrate --noinput`.
  Migrations have to be backwards compatible: going back to the previous
  version changes the image, not the database.

Skeleton: `examples/project-compose.yml.example`. The whole list of
requirements: [project-contract.md](project-contract.md).

## Two modes

The only difference is where the image comes from.

| | `image` (recommended) | `build` |
|---|---|---|
| the image is built | by the CI, and pushed to a registry | on the server |
| the server | pulls it | checks out the commit and builds it |
| a version is | an image tag | a commit SHA or a git tag |
| `/srv/example-app` holds | the compose file and `.env` | a git clone of the project |
| needs | the server logged in to the registry, for a private image | the server able to fetch the repository |

Prefer `image`: a build never takes memory and CPU from the running
projects, and what you tested in the CI is byte for byte what runs.

In mode `build` the compose file names the image with the same variable, so
that every version stays on the server as its own image and going back needs
no rebuild:

```yaml
image: example-app:${APP_TAG:?set APP_TAG in .env}
build: .
```

`git` runs as the owner of the project directory, with that account's
credentials for the remote (`origin`).

## Setting it up

```bash
sudo vps-stack deploy init example-app \
    --migrate "app php artisan migrate --force" \
    --backup
```

| Option | Meaning |
|---|---|
| `--mode image\|build` | default `image` |
| `--tag-var <NAME>` | the variable in `.env` used as the image tag; default `APP_TAG` |
| `--compose-file <path>` | the compose file, relative to the project directory, when it is not `compose.yaml` or `docker-compose.yml` |
| `--migrate "<service> <command>"` | migrations: the compose service to run them in, then the command |
| `--backup` | back up the project before every deploy (needs `vps-stack backup init example-app`) |
| `--health-timeout <seconds>` | how long to wait for healthy containers; default 120 |
| `--dry-run` | show the configuration without writing it |

The result is `/etc/vps-stack/deploy/example-app.env`. To change something
later, edit that file: `sudoedit /etc/vps-stack/deploy/example-app.env`.

The migration command is split on spaces and is not interpreted by a shell:
no quotes, pipes or variables. Anything more complex belongs in a script
inside the image.

## Deploying

```bash
sudo vps-stack deploy run example-app 3f2a9c1d4b5e
```

What happens, in this order:

1. The project name and the version are checked. A version is letters,
   digits, `_`, `.` and `-`, up to 128 characters.
2. A lock is taken. A second deploy of the same project is refused while one
   is running; projects do not block each other.
3. With `DEPLOY_BACKUP=true`: `vps-stack backup run example-app`. A failed
   backup stops the deploy.
4. The image is pulled (mode `image`), or the commit is checked out and the
   image built (mode `build`). The tag variable in `.env` is set to the
   version; the rest of the file, its owner and mode stay as they are.
5. The migrations run in a one-off container of the new version.
6. `docker compose up -d --remove-orphans --wait`: the containers are
   replaced, and the deploy waits until they are healthy.
7. If any step fails, `.env` (and in mode `build` the checked out commit)
   goes back to what it was. If the containers had already been replaced,
   the previous version is started again. The command exits with an error,
   which is what turns a pipeline red.
8. The previous version is recorded for `rollback`, and the result is added
   to the history.

Everything a deploy prints also goes to
`/var/log/vps-stack-deploy/example-app/deploy-<time>-<pid>.log`; the newest
30 logs are kept.

A deploy is not cut in half: when the connection that started it breaks (a
cancelled pipeline, a network problem), it still runs to its end and the log
is complete.

**There is a short interruption** while the containers are replaced. This is
not a zero-downtime (blue-green) deploy, and it will not become one.

**Migrations are not undone.** Step 7 changes the image back, not the
database. That is why migrations have to be backwards compatible, and why
`--backup` exists.

## Going back

```bash
sudo vps-stack deploy rollback example-app
```

Deploys the version that ran before the current one, through the same steps.
Running it twice returns to where you started. To go further back, name the
version: `sudo vps-stack deploy run example-app <version>`.

## What is deployed

```bash
sudo vps-stack deploy status
```

```
PROJECT              MODE   DEPLOYED             PREVIOUS             LAST DEPLOY
example-app          image  3f2a9c1d4b5e         9b1c0d2e3f4a         ok 2026-10-09T14:09:07Z 3f2a9c1d4b5e
```

The exit code is 1 when the last deploy of a listed project failed.

## A key for the CI

```bash
sudo vps-stack deploy key example-app --host app.example.com
```

It generates a key pair and prints the values to put into the secret store
of your CI: `DEPLOY_HOST`, `DEPLOY_PORT`, `DEPLOY_USER`,
`DEPLOY_KNOWN_HOSTS` and `DEPLOY_SSH_KEY`. The private key is shown once and
is not kept on the server. The pipeline then deploys with a single command,
the version being all it can say:

```bash
ssh -i <key file> -p <port> deploy@app.example.com 3f2a9c1d4b5e
```

The output of the deploy appears in the pipeline, and a failed deploy fails
the `ssh` command. An example for GitHub Actions:
`examples/project-deploy-workflow.yml.example`.

Two things are written on the server:

```
# ~deploy/.ssh/authorized_keys
restrict,command="/usr/local/bin/vps-stack deploy ssh example-app" ssh-ed25519 AAAA... vps-stack-deploy:example-app

# /etc/sudoers.d/vps-stack-deploy-example-app
deploy ALL=(root) NOPASSWD: /usr/local/bin/vps-stack deploy run example-app *
```

- `command=` replaces whatever the client asks to run. What the client sent
  is treated as the version: it is validated and passed on as data, never
  executed.
- `restrict` switches off the terminal, port, agent and X11 forwarding and
  `~/.ssh/rc`.
- The sudoers rule lets the deployment account start this one deploy as
  root, so **the account does not have to be in the `docker` group**
  (`DEPLOY_IN_DOCKER_GROUP=false`, the default, is enough). `deploy run`
  takes exactly a project and a version and has no options, so the `*`
  cannot turn it into anything else.

| | |
|---|---|
| `sudo vps-stack deploy key example-app` again | replaces the key; the old one stops working |
| `sudo vps-stack deploy key example-app --revoke` | removes the key and the sudoers rule |
| `--dry-run` | shows what would change |

### What the key protects against, and what it does not

A **leaked CI secret** lets someone deploy another version of that project's
image: an older one, with its known bugs. It gives no shell, no access to
Docker and no way to another project.

It does not limit **people who can push to the deployed branch**. Their code
becomes the image that runs on the server. Protect the branch (reviews, no
direct pushes).

**Who owns the project directory matters.** A deploy runs `docker compose`
as root on the compose file in `/srv/example-app`. Whoever can edit that file
can make root start any container, which is the same as being root. The key
cannot edit files, so it stays limited either way. A person or a process
with a shell on the deployment account can, when that account owns the
directory. If the deployment account is to stay unprivileged, let the
administrator own the project directory:

```bash
sudo chown -R sysadmin:sysadmin /srv/example-app
```

`deploy key` warns when the directory belongs to the deployment account. In
mode `build` the directory is a git clone that a deploy updates, so a push
changes the compose file too: there the protection of the branch is all
there is.

The deployment account's own key (`DEPLOY_SSH_PUBKEY_FILE`,
[ssh-keys.md](ssh-keys.md)) is a full shell. Never put that one into a CI.
