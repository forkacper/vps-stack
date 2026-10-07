# Regaining access after an SSH lockout

Read this **before** you need it, and find out how to start the rescue console
at your provider.

## First: are you really locked out

- Do you still have an old SSH session open? **Do not close it.** You can fix
  most problems from it with the commands further down.
- Check that you are connecting as the right user and to the right port:
  `ssh -v -p <port> admin@<address>`. After provisioning only the accounts in
  `AllowUsers` (the administrator and the deployment account) log in over SSH,
  by key only. Root and the provider's default user no longer do.
- `Connection refused` points to a wrong port or sshd not running. No reply (a
  timeout) points to the firewall or a fail2ban ban.
  `Permission denied (publickey)` points to the key or `AllowUsers`.

## Emergency access

**Provider console (VNC, KVM, serial console).** It gives you the machine's
login screen, independently of the network and SSH. Log in as the
administrator with their password (the one set for `sudo` during
provisioning).

**Rescue mode.** If you do not know the password or the system does not boot:
start the rescue system in the provider's panel, mount the server's disk and
fix the files directly. The paths in this document are then prefixed with the
mount point, e.g. `/mnt/etc/ssh/...`.

## Fixes

After every change, test logging in from a **new** session, without closing
the current one.

### Undoing the SSH hardening

The whole hardening is one file. Removing it brings back the image's
configuration:

```bash
sudo mv /etc/ssh/sshd_config.d/00-hardening.conf /root/00-hardening.conf.off
sudo sshd -t && sudo systemctl reload ssh
```

Copies from before the changes lie next to it as
`00-hardening.conf.bak.<date-time>` (sshd does not load them, because they do
not end in `.conf`).

The service is called `ssh` or `sshd`; check: `systemctl status ssh sshd`.

After fixing the cause (usually a missing or wrong key in
`/home/<admin>/.ssh/authorized_keys`, mode 700 on `.ssh` and 600 on the file),
run `sudo vps-stack provision` again.

### Resetting the SSH port (socket activation)

If the system starts sshd through `ssh.socket`, the port is set by
`/etc/systemd/system/ssh.socket.d/override.conf`. Removing that file brings
back the default port:

```bash
sudo rm /etc/systemd/system/ssh.socket.d/override.conf
sudo systemctl daemon-reload
sudo systemctl restart ssh.socket
sudo ss -tlnp | grep -E 'ssh|:22'
```

To check which variant your system uses: `systemctl is-active ssh.socket`.

### Resetting the SSH port (plain service)

The port is set by the `Port` line in `00-hardening.conf`. Remove it and
reload:

```bash
sudo sed -i '/^Port /d' /etc/ssh/sshd_config.d/00-hardening.conf
sudo sshd -t && sudo systemctl reload ssh
```

After a manual port reset also correct `SSH_PORT` in
`/etc/vps-stack/stack.env`, so that it matches reality.

### Firewall

```bash
sudo ufw status verbose
sudo ufw allow 22/tcp          # or your SSH port
```

As a last resort, while diagnosing: `sudo ufw disable`. Remember to enable it
again (`sudo ufw enable`) after making sure the SSH rule exists.

### A fail2ban ban

```bash
sudo fail2ban-client status sshd
sudo fail2ban-client set sshd unbanip <your-IP-address>
```

To keep it from happening again, put your address in `FAIL2BAN_IGNOREIP` in
`/etc/vps-stack/stack.env` and run provisioning again.

### An interrupted port change

If `vps-stack ssh-port` ended without the `YES` confirmation, sshd already
listens on the new port and ufw allows both. Run the same command once more to
finish the change, or undo it with one of the resets above.

## After regaining access

1. `sudo vps-stack verify`
2. Find the cause before you retry the change.
3. If the problem came from a bug in the scripts, report it (without IP
   addresses, domains and keys in the logs).
