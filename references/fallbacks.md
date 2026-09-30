# Fallbacks And Alternatives

Ordered by preference for recurring work. The pipe pattern in SKILL.md
remains the default for ad-hoc privileged commands.

## 1. NOPASSWD Command Whitelist (best for fixed recurring commands)

Eliminates the password entirely for a narrow command set:

```text
# /etc/sudoers.d/ops-agent — mode 0440, validate with visudo -cf before relying on it
zify ALL=(ALL) NOPASSWD: /usr/bin/systemctl *, /usr/bin/docker *, /usr/bin/journalctl, /usr/bin/tail
```

Safe bootstrap — the agent prepares the exact rule text and explains it; the
OWNER reviews and runs one command per host in their own terminal, so the
agent never handles the password:

```bash
echo 'zify ALL=(ALL) NOPASSWD: /usr/bin/systemctl *' | ssh <alias> \
  'sudo tee /etc/sudoers.d/ops-agent && sudo chmod 440 /etc/sudoers.d/ops-agent && sudo visudo -cf /etc/sudoers.d/ops-agent'
```

Afterward, plain `sudo` via ssh-skill suffices and this skill is not needed
for whitelisted commands. Keep `NOPASSWD: ALL` for disposable VMs only.

## 2. Time-Boxed NOPASSWD Lease (long deployments)

Pattern borrowed from free5gc/agent-skills' privilege workflow:

1. The agent explains the account, unrestricted root scope, duration
   (e.g. 15–240 min), and cleanup plan, then obtains explicit owner approval.
2. The owner adds the rule in their own terminal.
3. The agent performs the deployment.
4. The lease is removed at the end — either explicitly, or self-expiring via
   a timer the owner sets up front:

```bash
# Owner: auto-remove the lease file after 60 minutes
sudo systemd-run --on-active=60min --unit=sudo-lease-expire \
  /bin/rm -f /etc/sudoers.d/ops-lease
```

Never leave a lease behind silently; always verify and report removal.

## 3. Local Sudo: SUDO_ASKPASS

The pipe pattern is for remote hosts. For sudo on the control machine
itself, back `sudo -A` with the same store:

```bash
# ~/.local/bin/askpass-pass  (chmod 700)
#!/bin/sh
exec pass show local/sudo
```

```bash
export SUDO_ASKPASS="$HOME/.local/bin/askpass-pass"
sudo -A <command>
```

For a hardened standalone implementation with GUI confirmation dialogs, TOTP
for headless sessions, and audit logging, see GlassOnTin/secure-askpass
(MIT): https://github.com/GlassOnTin/secure-askpass

## 4. Ansible + Vault (many hosts, repeated changes)

When work becomes repeatable change management rather than ad-hoc commands:

- Keep sudo passwords in an `ansible-vault`-encrypted file (safe in git).
- Unlock the vault via pass: point `vault_password_file` in `ansible.cfg` at
  an executable script containing `#!/bin/sh` + `exec pass show ansible/vault-pass`.
- Playbooks carry `become: yes`; SSH auth still uses the same ssh-skill
  aliases and keys.
- Use `--check --diff` to preview changes before applying.

Ansible and this skill share the same password store, so rotation stays
single-source.
