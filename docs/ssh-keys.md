# SSH keys, step by step

After provisioning the server accepts SSH logins **by key only**. This
document shows how to create a key, get its public half onto the server and
point `stack.env` at it. Do it before [quickstart.md](quickstart.md), step 3.

Every block below says where to run it: on **your computer** or on the
**server**.

## How it works, in three sentences

A key is a pair of files. The **private** key (`id_ed25519`) stays on your
computer and is never copied anywhere. The **public** key (`id_ed25519.pub`)
is the part you give to the server; it is not a secret.

## 1. Check whether you already have a key

On your computer (Linux, macOS, or PowerShell on Windows 10/11):

```bash
ls ~/.ssh/*.pub
```

If the list contains `id_ed25519.pub` and you know the passphrase of that key,
you can use it and go to step 3. If there is nothing, or only an old
`id_rsa.pub` of unknown origin, create a new key.

## 2. Create a key

On your computer:

```bash
ssh-keygen -t ed25519 -C "admin@example.com"
```

- **File location:** press Enter to accept the default
  (`~/.ssh/id_ed25519`). If a key already exists there, do not overwrite it;
  give another name, e.g. `~/.ssh/vps-stack`, and use that name in the rest of
  this document.
- **Passphrase:** set one. It protects the private key if your computer or
  its disk falls into the wrong hands. Save it in your password manager.
- The text after `-C` is only a label that helps you recognise the key later.

The command creates two files:

| File | What it is | Where it goes |
|---|---|---|
| `~/.ssh/id_ed25519` | private key | nowhere; it stays on your computer |
| `~/.ssh/id_ed25519.pub` | public key | onto the server |

Show the public key (one line starting with `ssh-ed25519`):

```bash
cat ~/.ssh/id_ed25519.pub
```

So that you do not have to type the passphrase on every connection, add the
key to the agent:

```bash
ssh-add ~/.ssh/id_ed25519
```

On Windows the agent is a service that is switched off by default. In
PowerShell started as administrator:

```powershell
Get-Service ssh-agent | Set-Service -StartupType Automatic
Start-Service ssh-agent
ssh-add $env:USERPROFILE\.ssh\id_ed25519
```

## 3. First login to the fresh server

How you log in the first time depends on the provider:

- **You pasted the public key when ordering the server** (recommended): the
  provider installed it for the default user, usually `root` or `ubuntu`.
- **The provider sent you a password:** you log in with it this one time.

On your computer:

```bash
ssh root@<server-address>
```

On the first connection `ssh` shows the server's fingerprint and asks whether
to continue. If the provider's panel shows the fingerprint, compare them
before you type `yes`.

## 4. Copy the public key to the server

`vps-stack` creates a new administrator account and installs the key for it
from a file **on the server**. So the public key has to be there as a file.

On your computer:

```bash
scp ~/.ssh/id_ed25519.pub root@<server-address>:/root/admin.pub
```

If the default user is not `root`, copy the file to that user's home
directory instead, e.g. `ubuntu@<server-address>:/home/ubuntu/admin.pub`.

Without `scp`: log in to the server, run `nano /root/admin.pub`, paste the
line printed by `cat ~/.ssh/id_ed25519.pub` and save.

Check on the server that the file holds a valid key:

```bash
ssh-keygen -l -f /root/admin.pub
```

The command should print one line with the key size, a fingerprint starting
with `SHA256:` and `(ED25519)`. Provisioning runs the same check and refuses
to start when it fails.

Copy **only** the `.pub` file. If you ever copy the private key to a server by
mistake, treat it as leaked and create a new pair.

## 5. Point the configuration at the key

On the server, in the `stack.env` you are preparing:

```bash
ADMIN_SSH_PUBKEY_FILE=/root/admin.pub
```

The file may hold several keys, one per line (for example the keys of your
laptop and your desktop). Empty lines and lines starting with `#` are skipped.

## 6. Your IP address for fail2ban (optional)

fail2ban bans addresses that fail to log in several times. To make sure it
never bans you, find out which address the server sees you under. On the
server, in your SSH session and without `sudo`:

```bash
echo "${SSH_CLIENT%% *}"
```

Put the result in `stack.env`:

```bash
FAIL2BAN_IGNOREIP=<your-IP-address>
```

Skip this if your address changes often (mobile network, most home
connections without a static IP): the entry would soon point at someone else.

## 7. A key for the deployment account (optional)

`DEPLOY_USER` is a separate account without `sudo`, meant for deployments. Use
a **separate** key pair for it, never the administrator's key.

On your computer:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/example-app-deploy -C "deploy@example-app"
scp ~/.ssh/example-app-deploy.pub root@<server-address>:/root/deploy.pub
```

In `stack.env`:

```bash
DEPLOY_SSH_PUBKEY_FILE=/root/deploy.pub
```

If the key is meant for an automated system that cannot type a passphrase,
create it without one and keep the private key only in that system's secret
store.

## 8. After provisioning: test the key

Provisioning stops and asks you to test a second session before it disables
passwords and root login. On your computer, in a **new** terminal:

```bash
ssh admin@<server-address>
sudo -v
```

If you created the key under a non-default name, name it explicitly:

```bash
ssh -i ~/.ssh/vps-stack admin@<server-address>
```

`Permission denied (publickey)` at this point means the key did not get
through. Do not confirm in the first terminal; see
[ssh-recovery.md](ssh-recovery.md).

## 9. A shortcut on your computer (optional)

Add an entry to `~/.ssh/config` on your computer:

```
Host example-vps
    HostName <server-address>
    User admin
    Port 22
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

From then on `ssh example-vps` is enough. Update `Port` if you later change
the port with `vps-stack ssh-port`.

## Looking after the key

- Keep the passphrase in your password manager.
- Add a **second key** from another device, so that a lost laptop does not
  mean a lost server. On the server, as the administrator, append its public
  line to `~/.ssh/authorized_keys`.
- If a private key is lost or may have leaked, remove its line from
  `~/.ssh/authorized_keys` of every account that had it, then create a new
  pair.
- Without any working key the only way in is the provider's rescue console:
  [ssh-recovery.md](ssh-recovery.md).
