---
name: ssh-target-setup
description: Configure a remote Linux target device for passwordless SSH login and passwordless sudo. Covers SSH key generation, key deployment via ssh-copy-id, and sudoers NOPASSWD configuration. Use when user mentions configuring SSH access, setting up a remote device, enabling passwordless login, or deploying to a new target host.
---

# SSH Target Setup

Configure a remote Linux target so the first connection uses password, and all subsequent SSH and sudo commands are passwordless.

## Prerequisites

- Local machine with `ssh-keygen`, `ssh-copy-id`, and `sshpass` installed
- Target device IP/hostname and an SSH user with password access
- Target device has `sudo` and `sshd` running

## Workflows

### 1. Generate SSH Key (if none exists)

```bash
ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)-$(date +%Y%m%d)"
```

> **Note**: Replace `<PASSWORD>` with the actual SSH password. If the password contains special characters (e.g. a space `' '`), keep the single quotes around it.

### 1.5. Resolve All Identity Keys for the Target

A `~/.ssh/config` `Host` block may specify an `IdentityFile` that differs from the default key. Both the default and config-specific keys must be deployed.

```bash
ssh -G <target-host> | grep -i "^identityfile"
```

Keep every path returned. For each key file that lacks a `.pub` companion, derive it:

```bash
ssh-keygen -y -f ~/.ssh/<key>   # prints the public key to stdout
```

### 2. Deploy All Keys to Target (sshpass)

Deploy the default key (always a good baseline):

```bash
sshpass -p '<PASSWORD>' ssh-copy-id -o StrictHostKeyChecking=accept-new user@target-host
```

Then deploy every additional key found in step 1.5. If the `.pub` file exists:

```bash
sshpass -p '<PASSWORD>' ssh-copy-id -o StrictHostKeyChecking=accept-new -i ~/.ssh/<key>.pub user@target-host
```

If the `.pub` file is missing, pipe the derived public key directly:

```bash
ssh-keygen -y -f ~/.ssh/<key> | sshpass -p '<PASSWORD>' ssh user@target-host "tee -a ~/.ssh/authorized_keys"
```

If the target has a non-standard SSH port:

```bash
sshpass -p '<PASSWORD>' ssh-copy-id -p <port> -o StrictHostKeyChecking=accept-new user@target-host
```

### 3. Verify Passwordless SSH

```bash
ssh user@target-host "echo OK"   # should not prompt for password
```

If SSH still asks for a password, check:

- `~/.ssh/authorized_keys` permissions: must be `600`
- `~/.ssh` permissions: must be `700`
- `/etc/ssh/sshd_config`: `PubkeyAuthentication yes`, `PasswordAuthentication no` (optional after verification)
- SELinux: restorecon `restorecon -Rv ~/.ssh`

### 4. Configure Passwordless Sudo on Target

SSH into the target and run:

```bash
echo "user ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/user
sudo chmod 0440 /etc/sudoers.d/user
```

Replace `user` with the actual username. Validate the sudoers syntax:

```bash
sudo visudo -c -f /etc/sudoers.d/user
```

### 5. Verify Passwordless Sudo

```bash
ssh user@target-host "sudo whoami"   # should print "root" without password prompt
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Permission denied (publickey) | Wrong key or permissions | `chmod 600 ~/.ssh/authorized_keys` on target |
| Still asks password after ssh-copy-id | SSH server config | Check `sshd_config` then restart sshd |
| sudo asks password remotely | Missing NOPASSWD rule | Check `/etc/sudoers.d/user` exists and valid |
| sshpass: command not found | sshpass not installed | `apt install sshpass` / `pacman -S sshpass` / `brew install sshpass` |
| Permission denied (password) | Wrong password in `<PASSWORD>` | Verify password, check single quotes around it |
| Connection refused | SSH not running or wrong port | `systemctl status sshd` on target |
| Host key changed | Target reimaged | `ssh-keygen -R target-host` on local machine |
| IP connects, hostname fails | `~/.ssh/config` Host block specifies `IdentityFile` not deployed | Use `ssh -G <hostname> \| grep -i identityfile` to find the key, then deploy it (step 2) |
| `.pub` file missing for private key | `ssh-copy-id -i` requires `.pub` | Derive with `ssh-keygen -y -f ~/.ssh/<key> \| ssh <target> "tee -a ~/.ssh/authorized_keys"` |
