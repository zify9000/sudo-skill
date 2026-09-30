# Password Store Setup

The store lives only on the control machine. Remote hosts never receive the
store, the GPG key, or the password at rest.

## pass (default backend)

```bash
gpg --full-generate-key          # once, if no GPG key exists
pass init <GPG_KEY_ID>

# Per host — the OWNER runs this in their own terminal, input is hidden:
pass insert ops/sudo@<ssh-alias>
```

Recommended instead of manual per-host inserts: the owner runs
`scripts/init.sh` (or `scripts/init.sh --probe` to auto-skip NOPASSWD
hosts), which enumerates all ssh-skill aliases and walks through each
missing entry interactively.

Entry naming mirrors ssh-skill aliases so batch loops stay clean:

```bash
for h in web-1 web-2 db-1; do pass insert "ops/sudo@$h"; done
```

Verify an entry decrypts (also warms the gpg-agent cache):

```bash
pass show ops/sudo@<ssh-alias> >/dev/null && echo OK
```

## Rotation

```bash
# 1. Change the password on the remote host (passwd), then:
pass insert -f "ops/sudo@<alias>"        # manual overwrite
# or generate a fresh random one and set it remotely in the same session:
pass generate -i "ops/sudo@<alias>" 24
```

## Sync Between Control Machines (optional)

```bash
pass git init
pass git remote add origin <private-repo-url>
pass git push
```

Use a private repository only; the files are GPG-encrypted, but metadata
(entry names = host aliases) is visible in paths.

## gpg-agent Notes

- Decryption needs the GPG passphrase once per cache window; agent runs are
  non-interactive, so the owner should warm the cache (`pass show` anything)
  before long unattended sessions.
- Tune cache TTL in `~/.gnupg/gpg-agent.conf` (`default-cache-ttl`,
  `max-cache-ttl`).

## Alternative Backends

Any CLI that prints the password on stdout works. Keep the trailing newline
that `sudo -S` expects:

```bash
bw get password "ops/sudo@$ALIAS"                      # Bitwarden (after bw unlock)
op read "op://Ops/sudo-$ALIAS/password"; echo          # 1Password (needs the extra echo)
vault kv get -field=password "secret/ops/sudo/$ALIAS"  # HashiCorp Vault
```

Either keep the entry in pass and let the helper script use it, or substitute
the backend command in the raw pattern from SKILL.md. Never substitute a
literal password anywhere.
