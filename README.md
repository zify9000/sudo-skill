# sudo-skill

An agent skill (Codex / Claude Code / Kimi Code) for running
password-authenticated `sudo` on remote SSH hosts **without ever exposing
the password**. The secret flows from the local password store through a
pipe into remote `sudo -S` — command text, chat transcripts, wire logs,
shell history, process lists, and remote `auth.log` all stay free of secret
material.

Companion to [ssh-skill](https://github.com/badseal/ssh-skill) (v4), which
provides the SSH transport, alias resolution, and result contract; this
skill adds the privilege-escalation layer on top.

## How it works

```bash
pass show "ops/sudo@<alias>" | ssh-skill exec <alias> 'sudo -S -k -p "" <command>'
```

- The command text contains only the password-store **entry name** — never
  the password.
- `sudo -S` consumes the first stdin line; multi-line scripts share the same
  pipe (`sudo bash -s`).
- Wrong password → clean exit 1 within seconds, never a hang (validated).
- Remote `auth.log` records the executed COMMAND, never the password
  (validated).

## Layout

- `SKILL.md` — the agent contract: hard rules, command patterns, error
  decisions
- `scripts/sudo_exec.sh` — deterministic wrapper: `probe` / `exec` /
  `script` modes
- `scripts/init.sh` — guided onboarding: `--check` (status), `--verify`
  (end-to-end entry test), interactive insert (owner-run, hidden input)
- `references/setup.md` — `pass` setup, rotation, sync, alternative backends
  (Bitwarden / 1Password / Vault)
- `references/fallbacks.md` — NOPASSWD whitelists, time-boxed leases,
  `SUDO_ASKPASS` for local sudo, Ansible + vault at scale

## Requirements

- [ssh-skill](https://github.com/badseal/ssh-skill) v4 (developed and tested
  against v4.0, result `schema_version` 1.0)
- `pass` + `gpg` (or any password-store CLI that prints to stdout)
- `python3`, OpenSSH

## Install

```bash
# skills CLI:
npx skills add zify9000/sudo-skill

# or clone straight into your user-scope skills directory:
git clone https://github.com/zify9000/sudo-skill.git ~/.agents/skills/sudo-skill
```

## Quick start

```bash
# 1. One-time onboarding, in YOUR OWN terminal (passwords never transit the
#    agent; input is hidden by pass):
~/.agents/skills/sudo-skill/scripts/init.sh --probe

# 2. End-to-end verification (agent-safe):
~/.agents/skills/sudo-skill/scripts/init.sh --verify

# 3. Daily use:
sudo_exec.sh exec web-1 'systemctl restart nginx'
sudo_exec.sh script web-1 ./maintenance.sh
```

## Security model

- Password-store entries are created and rotated **only by the owner** via
  `pass insert` — never typed into an agent conversation.
- The GPG-encrypted store never leaves the control machine.
- ssh-skill's host-key policy and result contract are inherited unchanged.
- Authentication failure is a stop condition; the skill never retries with
  guessed passwords.

## License

MIT
