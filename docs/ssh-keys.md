# SSH keys, step by step

After provisioning the server accepts SSH logins **by key only**. This
document takes you from no key at all to logging in to the provisioned
server. Do it before [quickstart.md](quickstart.md), step 3.

Every block says where to run it: on **your computer** or on the **server**.
The examples use a key named `example-vps` and the address
`<server-address>`; put in your own.

## How it works

A key is a pair of files:

| File | What it is | Where it goes |
|---|---|---|
| `~/.ssh/example-vps` | private key | nowhere: it never leaves your computer |
| `~/.ssh/example-vps.pub` | public key, one line starting with `ssh-ed25519` | to the server, into `~/.ssh/authorized_keys` of an account |

The server lets in whoever proves they hold the private key matching a line
in `authorized_keys`. The public key is not a secret.

You will put the public key on the server **twice**, for two different
purposes:

1. into `authorized_keys` of the provider's default account, so that you can
   log in before provisioning (step 4);
2. as a file that provisioning installs for the new administrator account
   (step 6).

## 1. Check whether you already have a key

On your computer (Linux, macOS, or PowerShell on Windows 10/11):

```bash
ls ~/.ssh/*.pub
```

You can reuse an existing key whose passphrase you know. A separate key for
the server is cleaner, though: you can revoke it without touching anything
else.

## 2. Create a key

On your computer:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/example-vps -C "admin@example.com"
```

- `-f` gives the key its own name, so an existing `~/.ssh/id_ed25519` is not
  overwritten.
- **Passphrase:** set one. It protects the private key if your computer or its
  disk falls into the wrong hands. Save it in your password manager.
- `-C` is only a label that helps you recognise the key later.

## 3. A shortcut on your computer

With a key of its own name, every `ssh` command would need `-i` and more
options. Add an entry to `~/.ssh/config` on your computer instead (create the
file if it does not exist):

```
Host example-vps
    HostName <server-address>
    User ubuntu
    IdentityFile ~/.ssh/example-vps
    IdentitiesOnly yes
```

- `User` is the provider's default account for now: `ubuntu` on most Ubuntu
  images (OVH, AWS, many others), `root` at some providers. The provider's
  panel or welcome e-mail says which. After provisioning you change it (step
  7).
- `IdentitiesOnly yes` makes `ssh` offer only this key. Without it, with
  several keys in the agent, the server may close the connection with "Too
  many authentication failures" before it gets to the right one.
- On macOS, add `UseKeychain yes` and `AddKeysToAgent yes` to store the
  passphrase in the keychain, so that you do not type it on every connection.

From now on `ssh example-vps` is enough.

## 4. Put the key on the provider's default account

Pick the case that matches your server.

**a) You pasted the public key when ordering the server.** The provider
installed it already; go to step 5.

**b) You have a password for the default account** (usually from the
provider's welcome e-mail). On your computer:

```bash
ssh-copy-id -i ~/.ssh/example-vps.pub example-vps
```

It asks for the account's password once and adds the key to
`~/.ssh/authorized_keys` on the server with the right permissions. Without
`ssh-copy-id` (e.g. on Windows), the same in one command:

```bash
cat ~/.ssh/example-vps.pub | ssh example-vps \
    'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```

**c) Copy and paste,** for example through the provider's web console. Show
the public key on your computer and copy the whole line:

```bash
cat ~/.ssh/example-vps.pub
```

then on the server, as the default account:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
nano ~/.ssh/authorized_keys      # paste the line at the end; save: Ctrl+O, Enter; exit: Ctrl+X
chmod 600 ~/.ssh/authorized_keys
```

On the first connection `ssh` shows the server's fingerprint and asks whether
to continue. If the provider's panel shows the fingerprint, compare them
before you type `yes`.

## 5. Test the key

On your computer, in a **new** terminal:

```bash
ssh example-vps
```

You get in without the account's password (at most the passphrase of the
key): the key works. If not, see [When it does not work](#when-it-does-not-work).

## 6. The key file for provisioning

Provisioning creates a new administrator account and installs your key for
it from a file **on the server**, named by `ADMIN_SSH_PUBKEY_FILE` in
`stack.env`. Copy the public key into the home directory of the account you
log in with. On your computer:

```bash
scp ~/.ssh/example-vps.pub example-vps:admin.pub
```

The file lands in that account's home directory, e.g.
`/home/ubuntu/admin.pub` (or `/root/admin.pub` when you log in as root).
Check on the server that it holds a valid key:

```bash
ssh-keygen -l -f ~/admin.pub
```

It prints one line with the size, a fingerprint starting with `SHA256:` and
`(ED25519)`. Provisioning runs the same check and refuses to start when it
fails. Then, in `stack.env`, the full path:

```bash
ADMIN_SSH_PUBKEY_FILE=/home/ubuntu/admin.pub
```

The file may hold several keys, one per line (for example the keys of your
laptop and your desktop). Empty lines and lines starting with `#` are skipped.

Copy **only** the `.pub` file. If you ever copy a private key to a server by
mistake, treat it as leaked and create a new pair.

## 7. After provisioning

Provisioning stops and asks you to test a second session before it disables
passwords and root login, and from then on only the new administrator (by
default `admin`) and the deployment account may log in over SSH. The
provider's default account, `ubuntu` included, no longer can.

So when provisioning asks for the test, change `User` in the entry on your
computer:

```
Host example-vps
    HostName <server-address>
    User admin
    IdentityFile ~/.ssh/example-vps
    IdentitiesOnly yes
```

and in a **new** terminal, without closing the one where provisioning runs:

```bash
ssh example-vps
sudo -v          # the password you set for admin during provisioning
```

Only when both work, type `YES` in the first terminal.

If you later change the SSH port with `vps-stack ssh-port`, add `Port <port>`
to the entry.

## 8. A key for the deployment account (optional)

`DEPLOY_USER` is a separate account without `sudo`, meant for deployments. Use
a **separate** key pair for it, never the administrator's key.

On your computer:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/example-app-deploy -C "deploy@example-app"
scp ~/.ssh/example-app-deploy.pub example-vps:deploy.pub
```

In `stack.env`:

```bash
DEPLOY_SSH_PUBKEY_FILE=/home/ubuntu/deploy.pub
```

If the key is meant for an automated system that cannot type a passphrase,
create it without one and keep the private key only in that system's secret
store.

## 9. Your IP address for fail2ban (optional)

fail2ban bans addresses that fail to log in several times. To make sure it
never bans you, find out which address the server sees you under. On the
server, in your SSH session:

```bash
echo "${SSH_CLIENT%% *}"
```

Put the result in `stack.env`:

```bash
FAIL2BAN_IGNOREIP=<your-IP-address>
```

Skip this if your address changes often (mobile network, most home
connections without a static IP): the entry would soon point at someone else.

## When it does not work

Run the connection with details and look at the last lines:

```bash
ssh -v example-vps
```

| Symptom | Usual cause | Fix |
|---|---|---|
| it asks for the account's password | the key is not in `authorized_keys`, or `ssh` does not offer it | repeat step 4; check `IdentityFile` in `~/.ssh/config`; `ssh -v` shows `Offering public key: ...example-vps` |
| `Permission denied (publickey)` | the key is not in `authorized_keys` of **this** account, or the permissions are too open | on the server: `chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`; after provisioning: are you logging in as `admin`? |
| `Too many authentication failures` | `ssh` offered other keys first | `IdentitiesOnly yes` in the entry |
| `Connection refused` | wrong port, or sshd not running | `Port` in the entry; after `ssh-port`, the new port |
| no reply (a timeout) | a firewall (ufw or the provider's), or a fail2ban ban | [ssh-recovery.md](ssh-recovery.md) |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` | the server was reinstalled (new host key) or, rarely, an attack | if you reinstalled it: `ssh-keygen -R <server-address>`; otherwise stop and check |
| a line in `authorized_keys` does not work | it was cut or wrapped when pasted | one key = one line; compare with `cat ~/.ssh/example-vps.pub` |

## Looking after the key

- Keep the passphrase in your password manager. Some password managers
  (1Password, Bitwarden) can also hold the key itself and act as the SSH
  agent, so that it is available on every device you use them on.
- Add a **second key** from another device, so that a lost laptop does not
  mean a lost server. On the server, as the administrator, append its public
  line to `~/.ssh/authorized_keys`.
- If a private key is lost or may have leaked, remove its line from
  `~/.ssh/authorized_keys` of every account that had it, then create a new
  pair.
- Without any working key the only way in is the provider's rescue console:
  [ssh-recovery.md](ssh-recovery.md).
