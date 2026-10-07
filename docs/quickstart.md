# Quick start

This document takes you from ordering a server to the first working site. Set
aside a quiet hour for it. **The first time, do it on a machine you can throw
away.**

## 1. Before you touch the server

1. Order a VPS with Ubuntu 24.04 or 26.04 (for example 2 vCPU, 4 GB RAM, 40 GB
   disk). Provide your **SSH public key** when ordering, if the provider
   allows it. If you do not have a key yet, create one first:
   [ssh-keys.md](ssh-keys.md).
2. Enable **two-factor authentication (2FA)** on your provider account.
   Whoever takes over that account takes over the server, regardless of
   anything `vps-stack` does.
3. Take a **snapshot** of the fresh machine.
4. Check that you have access to the **rescue console** (VNC, KVM, rescue
   mode) in the provider's panel and that you know how to log in through it.
   It is the only way back if a change to SSH or the firewall goes wrong. Do
   this **before** any change, not after. Recovery instructions:
   [ssh-recovery.md](ssh-recovery.md).

## 2. Getting the code

Log in to the server and clone the repository. It is public; no deploy key is
needed.

```bash
sudo apt-get update && sudo apt-get install -y git
sudo git clone https://github.com/forkacper/vps-stack.git /opt/vps-stack
cd /opt/vps-stack
# The newest release, not the development branch:
sudo git checkout "$(sudo git tag --list 'v*' --sort=-v:refname | head -n 1)"
```

The last command switches to the newest release. The `master` branch holds the
work towards the next one; servers should run released versions
([releasing.md](releasing.md)).

Read `scripts/provision.sh` before you run it. It runs as root.

## 3. Configuration

The clone belongs to root, so prepare the configuration in your home
directory (provisioning copies it to `/etc/vps-stack/`):

```bash
cp /opt/vps-stack/config/stack.env.example ~/stack.env
cp /opt/vps-stack/config/proxy.env.example ~/proxy.env
```

In `stack.env` you have to set one thing: `ADMIN_SSH_PUBKEY_FILE`, the full
path to a file with your public key **on the server**:

```bash
# On your computer:
scp ~/.ssh/example-vps.pub example-vps:admin.pub
# In ~/stack.env (the home directory of the account you log in with):
ADMIN_SSH_PUBKEY_FILE=/home/ubuntu/admin.pub
```

Creating a key, logging in with it, copying it and testing it are described
step by step in [ssh-keys.md](ssh-keys.md).

It is also worth putting your IP address in `FAIL2BAN_IGNOREIP`. The other
values have sensible defaults and are described in the file.

In `proxy.env` set `ACME_EMAIL`: the address the certificate authority sends
warnings to. A file lying next to `stack.env` is copied automatically.

Leave `SSH_PORT` at whatever sshd listens on now (usually 22). The port is
changed later with a separate command.

## 4. Provisioning

First a preview that changes nothing:

```bash
sudo ./bin/vps-stack provision --config ~/stack.env --dry-run
```

Then the real run:

```bash
sudo ./bin/vps-stack provision --config ~/stack.env
```

The script goes through 13 steps and prints `[n/13]` at each of them. At the
start it warns that the system is untested, shows a summary of the settings and
asks whether to begin. After that it stops in three more places and waits for
you:

1. **Administrator password.** SSH login will be possible by key only, but
   `sudo` still asks for a password, so one has to be set.
2. **Second SSH session test.** Before the script disables passwords and root
   login, it asks you to type `YES`. **Do not type it by reflex.** Open a
   second terminal and check, as the new administrator (with the entry
   from [ssh-keys.md](ssh-keys.md), step 7: `User sysadmin`):

   ```bash
   ssh sysadmin@<server-address>
   sudo -v
   ```

   If both commands work, go back to the first terminal and type `YES`. If
   not, type anything else: the script stops without touching the sshd
   configuration, and you can fix the key and run it again.
3. **Enabling the firewall.** The script shows the list of rules and asks for
   consent only after checking that the rule for the SSH port exists.

The `--yes` option skips only the initial questions. It does not skip these
three points.

**Do not close the first SSH session** until, after the script has finished,
you have logged in once more from a new one.

If the script stops, read the message, fix the cause and run the same command
again: completed steps are skipped. The full log is in
`/var/log/vps-stack-provision.log`.

From now on the configuration lives in `/etc/vps-stack/stack.env`, and the
`vps-stack` command is available on `PATH`.

## 5. Verification

```bash
sudo vps-stack verify
```

The table should contain only `OK`. A `WARN` for the backup is normal at this
stage (you have not set it up yet). Clear up every `ERROR` before going on.

Reboot the server (`sudo reboot`), log in again and run `verify` once more:
swap, firewall, Docker and the proxy have to come up on their own.

## 6. First project and site

1. Prepare the project according to [project-contract.md](project-contract.md).
   Skeleton: `examples/project-compose.yml.example`.
2. Create the project directory and start the project:

   ```bash
   sudo install -d -o deploy -g deploy /srv/example-app
   # clone the project's repository into /srv/example-app, fill in .env
   cd /srv/example-app && sudo docker compose up -d
   ```

3. Point the domain's `A` record (and `AAAA`, if the server has IPv6) at the
   server's address. Wait until it takes effect:

   ```bash
   vps-stack check-dns app.example.com
   ```

4. Add the site:

   ```bash
   sudo vps-stack add-site app.example.com example-app-web:80
   ```

   Caddy obtains the certificate by itself. Details, aliases, redirects and
   testing against the staging environment: [adding-sites.md](adding-sites.md).

## 7. What next

- **Backup.** Without it the server is not ready for work:
  `sudo vps-stack backup init system`, then `backup init <project>` for every
  project ([backup-restore.md](backup-restore.md)).
- **Monitoring.** The minimum is an external uptime check:
  [monitoring.md](monitoring.md).
- **Changing the SSH port** (optional): `sudo vps-stack ssh-port <port>`.
  If your provider has a firewall in its panel (a cloud firewall, security
  groups), open the new port **there first**: `vps-stack` changes only ufw.
  Keep the current session open until the command has finished, then update
  `Port` in `~/.ssh/config` on your computer ([ssh-keys.md](ssh-keys.md)).
- Lock the provider's default user once you have confirmed that the
  administrator account works. The provisioning summary prints the
  instructions.
