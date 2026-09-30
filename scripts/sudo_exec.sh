#!/usr/bin/env bash
# sudo_exec.sh — pipe a sudo password from the local password store into
# remote `sudo -S` via ssh-skill, without exposing the secret.
#
# Usage:
#   sudo_exec.sh probe  <alias>                 SUDO_NOPASSWD or SUDO_NEEDS_PASSWORD
#   sudo_exec.sh exec   <alias> <remote-cmd>    run one privileged command
#   sudo_exec.sh script <alias> <script-file>   password line + script → sudo bash -s
#
# Environment:
#   SSH_SKILL_ROOT   ssh-skill directory (default: ~/.agents/skills/ssh-skill)
#   SUDO_PASS_ENTRY  pass entry name   (default: ops/sudo@<alias>)
#
# Exit codes: 2 = local setup problem (no SSH connection was opened);
# otherwise the exit code of ssh_skill.py is preserved. stdout carries
# ssh-skill's single JSON result; parse it per the ssh-skill contract.
#
# Security: the password exists only inside the pipe. Never enable `set -x`
# and never add logging of command output beyond what ssh-skill returns.

set -euo pipefail

SSH_SKILL_ROOT="${SSH_SKILL_ROOT:-$HOME/.agents/skills/ssh-skill}"
SSH_SKILL_CLI="$SSH_SKILL_ROOT/scripts/ssh_skill.py"

die() { printf 'sudo_exec: %s\n' "$*" >&2; exit 2; }

[ $# -ge 2 ] || die "usage: sudo_exec.sh probe|exec|script <alias> [<remote-cmd>|<script-file>]"
mode="$1"
alias="$2"
entry="${SUDO_PASS_ENTRY:-ops/sudo@$alias}"

[ -f "$SSH_SKILL_CLI" ] || die "ssh-skill CLI not found at $SSH_SKILL_CLI (set SSH_SKILL_ROOT)"

require_entry() {
  command -v pass >/dev/null 2>&1 || die "pass(1) not installed"
  # Fail fast before opening any SSH connection; gpg-agent caches the
  # passphrase, so the second decryption below is cheap.
  pass show "$entry" >/dev/null 2>&1 \
    || die "no password-store entry '$entry' (owner must run: pass insert $entry)"
}

case "$mode" in
  probe)
    # Close stdin: a probe must never consume the caller's input stream.
    exec python3 "$SSH_SKILL_CLI" exec "$alias" \
      'sudo -n true 2>/dev/null && echo SUDO_NOPASSWD || echo SUDO_NEEDS_PASSWORD' \
      < /dev/null
    ;;
  exec)
    [ $# -ge 3 ] || die "exec mode needs a remote command"
    require_entry
    pass show "$entry" \
      | python3 "$SSH_SKILL_CLI" exec "$alias" "sudo -S -k -p \"\" $3"
    ;;
  script)
    [ $# -ge 3 ] || die "script mode needs a local script file"
    [ -f "$3" ] || die "script file not found: $3"
    require_entry
    { pass show "$entry"; cat "$3"; } \
      | python3 "$SSH_SKILL_CLI" exec "$alias" 'sudo -S -k -p "" bash -s'
    ;;
  *)
    die "unknown mode: $mode (expected probe|exec|script)"
    ;;
esac
