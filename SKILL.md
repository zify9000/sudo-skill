---
name: sudo-skill
version: 1.3.0
description: "Use when a task requires password-authenticated sudo without exposing the password — on remote SSH hosts via ssh-skill, or on the control machine itself via the reserved pseudo-alias 'local' (direct pipe, no SSH): privileged commands, multi-line privileged scripts, same command across targets with per-target passwords, or probing whether sudo needs a password; Chinese triggers include 远程sudo, 本机sudo, sudo密码, sudo脱敏, 提权运维, 批量sudo. DO NOT use for NOPASSWD targets (plain sudo), root SSH accounts, or sudoers edits (owner-approved fallback only)."
allowed-tools: Bash, Read, Write, Glob
keywords: sudo,password,privilege,escalation,pass,gpg,ssh,remote,local,ops,远程sudo,本机sudo,sudo密码,提权,运维
---

# Sudo Skill

## Purpose

Run password-authenticated `sudo` without ever exposing the password — on
remote SSH hosts via ssh-skill, and on the control machine itself via the
reserved pseudo-alias `local`. The secret flows from the local password
store through a pipe into `sudo -S`; command text, chat transcripts, wire
logs, shell history, process lists, and auth logs all stay free of secret
material.

For remote targets this skill pairs with ssh-skill: ssh-skill owns
transport, aliases, and its JSON result contract; this skill owns privilege
escalation on top of it. Never construct raw `ssh` commands here.

## Dependencies

- **ssh-skill (required for remote targets; the `local` pseudo-alias runs
  without it)** — provides SSH transport, alias resolution, and the result
  contract this skill builds on. Upstream project:
  https://github.com/badseal/ssh-skill. Developed and tested against
  ssh-skill v4.0 (result `schema_version` 1.0); the contract surface used
  here is the `scripts/ssh_skill.py` CLI with the `exec` and
  `config list-servers` operations plus the single-JSON-document stdout
  result. Pin to ssh-skill major version v4; treat a major-version bump as a
  compatibility review point. Resolve `<SSH_SKILL_ROOT>` from the loaded
  ssh-skill copy and export it as `SSH_SKILL_ROOT` when it differs from the
  default (`~/.agents/skills/ssh-skill`); the helper scripts exit with code
  2 and a clear message if the CLI is absent, before opening any connection.
- **pass (required for entry-backed modes)** — the local GPG password store;
  see references/setup.md for initialization and alternative backends.
- **python3** — required by ssh-skill's CLI and this skill's JSON handling.

## Scope

Use for:

- Privileged commands on SSH hosts where sudo requires a password.
- The control machine itself via the reserved pseudo-alias `local` — a
  direct pipe to local `sudo -S`; no SSH, sshd, or ssh-skill involved.
- Multi-line privileged scripts on one target.
- One privileged command across several targets with different passwords.
- Probing whether a target's sudo needs a password at all.

Do NOT use for:

- Targets already configured NOPASSWD — run plain `sudo` (via ssh-skill for
  remote hosts).
- SSH accounts that log in as root (no sudo involved).
- sudoers changes — references/fallbacks.md only, with owner approval.

## Hard Rules

1. Never write a password into command text, environment variables, files
   outside the password store, or the conversation. The only permitted
   reference is the password-store entry name.
2. Never ask the user to paste a password in chat. Password-store entries
   are created, rotated, and revoked by the owner in their own terminal
   (`pass insert`), never by the agent.
3. Route remote execution through ssh-skill's CLI; no raw ssh/scp wrappers.
   The `local` pseudo-alias executes directly — no transport at all.
4. Probe before privileged mutation: on each previously untested target,
   verify the mechanism with a harmless `true`/`whoami` run before any
   state-changing command.
5. Authentication failure is a stop condition. Report it; never retry with
   guessed, alternate, or transformed passwords.
6. Do not add NOPASSWD rules or otherwise weaken sudoers without explicit
   owner approval and a preview of the exact rule text.
7. Resolve `<SSH_SKILL_ROOT>` from the loaded ssh-skill copy; pass it to the
   helper script via the SSH_SKILL_ROOT environment variable when it differs
   from the default.

## Password Store Convention

One entry per target:

```text
ops/sudo@<ssh-alias>   # remote hosts, named by ssh-skill / ssh-config alias
ops/sudo@local         # the control machine (reserved pseudo-alias)
```

Managed with `pass` (GPG-encrypted, one file per entry, local only — never
copied to remote hosts). Setup, rotation, multi-machine sync, and
alternative stores (Bitwarden, 1Password, Vault) are in
references/setup.md.

Guided onboarding: the owner runs `<SUDO_SKILL_ROOT>/scripts/init.sh` in
their own terminal (interactive insert; `--probe` auto-skips NOPASSWD
targets). The agent may run `scripts/init.sh --check` (which targets have
entries) and `scripts/init.sh --verify` (end-to-end entry test) — both are
non-interactive and never expose secret material.

## Helper Script

`<SUDO_SKILL_ROOT>/scripts/sudo_exec.sh` wraps the pattern deterministically:

```bash
sudo_exec.sh probe  <alias>                             # SUDO_NOPASSWD or SUDO_NEEDS_PASSWORD
sudo_exec.sh exec   <alias> 'systemctl restart nginx'   # remote, via ssh-skill
sudo_exec.sh exec   local   'apt list --upgradable'     # control machine, no SSH
sudo_exec.sh script <alias> ./ops.sh                    # password line + script → sudo bash -s
```

Environment: `SSH_SKILL_ROOT` (default `~/.agents/skills/ssh-skill`),
`SUDO_PASS_ENTRY` (default `ops/sudo@<alias>`), `SUDO_LOCAL_ALIAS`
(default `local`).

Every mode emits one JSON document compatible with ssh-skill's result
contract — local and remote results parse identically — and preserves the
command's exit code. Exit code 2 means a local setup problem (missing entry,
missing CLI) detected before any execution.

## Raw Pattern

When ssh-skill options (`--timeout`, `--no-daemon`) are needed, compose the
pattern directly:

```bash
# remote:
pass show "ops/sudo@$ALIAS" | python3 "$SSH_SKILL_ROOT/scripts/ssh_skill.py" exec "$ALIAS" 'sudo -S -k -p "" systemctl restart nginx'

# control machine (no SSH):
pass show ops/sudo@local | sudo -S -k -p "" apt list --upgradable
```

Flags: `-S` reads the password from stdin, `-k` forces fresh authentication
(and prevents the password line from leaking into the command's own stdin
when a cached timestamp exists), `-p ""` suppresses the prompt so it cannot
pollute output.

Multi-line scripts share stdin: sudo consumes the first line, the rest
reaches the command:

```bash
{ pass show "ops/sudo@$ALIAS"; cat ./ops.sh; } | python3 "$SSH_SKILL_ROOT/scripts/ssh_skill.py" exec "$ALIAS" 'sudo -S -k -p "" bash -s'
```

Multi-target with per-target passwords is a loop of single exec calls, not
ssh-skill `cluster` (each connection needs its own stdin) — and `local`
mixes in naturally:

```bash
for t in local web-1 web-2 db-1; do
  sudo_exec.sh exec "$t" 'apt list --upgradable'
done
```

## Behavior Notes (validated)

- Wrong password: sudo retries, the pipe is already at EOF, exit code 1
  within seconds — no hang. Remote results report `success=false,
  retryable=false`; stop and report.
- Non-interactive SSH gets no usable sudo timestamp cache; feed the password
  on every call. Measured overhead is negligible (~0.7 s end to end).
- The `local` pseudo-alias bypasses ssh-skill entirely: no sshd, no network,
  works offline. If a real SSH alias named `local` exists, set
  `SUDO_LOCAL_ALIAS` to a different reserved name.
- `auth.log` records the executed COMMAND, never the password.
- Legacy hosts with `Defaults requiretty` reject non-tty sudo; fix in
  sudoers, never by forcing a tty.
- `pass` decryption needs the GPG passphrase once per gpg-agent cache
  window. In unattended runs, a cold cache fails fast with a decryption
  error (not a hang); the owner warms the cache with any local `pass show`.
- `exec` mode wraps the command as `sudo ... <cmd>` in a shell; quote the
  command exactly as you would for ssh-skill exec.
- Shell operators bind tighter than the sudo wrap: `exec <alias> 'a && b'`
  runs only `a` privileged. For compound commands use `script` mode or
  `exec <alias> 'bash -c "a && b"'`.

## Error Decisions

- Probe prints `SUDO_NOPASSWD`: run plain `sudo` (via ssh-skill for remote
  targets); no entry needed.
- Missing store entry (exit 2): stop; ask the owner to run
  `pass insert ops/sudo@<alias>` in their own terminal.
- `no password was provided` / `Sorry, try again` from sudo: wrong or stale
  password — stop; owner re-inserts the entry. Never retry automatically.
- `outcome_unknown` from ssh-skill: follow ssh-skill's stop condition with
  its request ID.
- Target sudoers/syntax errors: report verbatim; do not edit sudoers.

## Fallbacks

references/fallbacks.md covers, in order of preference for recurring work:
NOPASSWD command-whitelist sudoers with a safe owner-run bootstrap,
time-boxed NOPASSWD leases for long deployments, SUDO_ASKPASS for human
interactive local sudo, and Ansible + vault when host count or change
frequency justifies it.

## Final Check

- Password referenced only by store entry name; no secret in any text.
- Mechanism verified with a harmless probe on new targets before mutation.
- One JSON result parsed; failures reported, never retried.
- No sudoers weakening without explicit owner approval.
