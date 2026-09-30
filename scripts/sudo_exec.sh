#!/usr/bin/env bash
# sudo_exec.sh — pipe a sudo password from the local password store into
# `sudo -S`: on a remote host via ssh-skill, or on the control machine
# itself via the reserved pseudo-alias "local". The secret never leaves the
# pipe; command text, transcripts, and logs stay free of secret material.
#
# Usage:
#   sudo_exec.sh probe  <alias>|local                 SUDO_NOPASSWD or SUDO_NEEDS_PASSWORD
#   sudo_exec.sh exec   <alias>|local <remote-cmd>    run one privileged command
#   sudo_exec.sh script <alias>|local <script-file>   password line + script → sudo bash -s
#
# The pseudo-alias "local" (override with SUDO_LOCAL_ALIAS) targets the
# control machine directly: no SSH, no sshd, no network, no ssh-skill
# dependency. Every mode emits one JSON document compatible with
# ssh-skill's result contract, so agents parse local and remote results
# identically.
#
# Environment:
#   SSH_SKILL_ROOT    ssh-skill directory (default: ~/.agents/skills/ssh-skill)
#   SUDO_PASS_ENTRY   pass entry name    (default: ops/sudo@<alias>)
#   SUDO_LOCAL_ALIAS  pseudo-alias name  (default: local)
#
# Exit codes: 2 = local setup problem (missing entry, missing ssh-skill CLI
# for remote targets) detected before any execution; otherwise the executed
# command's exit code is preserved. Security: never enable `set -x`; the
# password exists only inside the pipe.

set -euo pipefail

SSH_SKILL_ROOT="${SSH_SKILL_ROOT:-$HOME/.agents/skills/ssh-skill}"
SSH_SKILL_CLI="$SSH_SKILL_ROOT/scripts/ssh_skill.py"
LOCAL_ALIAS="${SUDO_LOCAL_ALIAS:-local}"

die() { printf 'sudo_exec: %s\n' "$*" >&2; exit 2; }

[ $# -ge 2 ] || die "usage: sudo_exec.sh probe|exec|script <alias>|$LOCAL_ALIAS [<remote-cmd>|<script-file>]"
mode="$1"
alias="$2"
entry="${SUDO_PASS_ENTRY:-ops/sudo@$alias}"

is_local() { [ "$alias" = "$LOCAL_ALIAS" ]; }

require_entry() {
  command -v pass >/dev/null 2>&1 || die "pass(1) not installed"
  # Fail fast before any execution; gpg-agent caches the passphrase, so the
  # second decryption below is cheap.
  pass show "$entry" >/dev/null 2>&1 \
    || die "no password-store entry '$entry' (owner must run: pass insert $entry)"
}

require_cli() {
  [ -f "$SSH_SKILL_CLI" ] || die "ssh-skill CLI not found at $SSH_SKILL_CLI (set SSH_SKILL_ROOT)"
}

# Emit one JSON document compatible with ssh-skill's result contract.
# Args: rc stdout_file stderr_file command
emit_json() {
  python3 - "$@" <<'PY'
import json, sys
rc, out_f, err_f, cmd = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
with open(out_f) as f:
    out = f.read()
err = ""
if err_f != "/dev/null":
    with open(err_f) as f:
        err = f.read()
print(json.dumps({
    "schema_version": "1.0",
    "success": rc == 0,
    "operation": "exec",
    "data": {"alias": "local", "command": cmd, "exit_code": rc,
             "stdout": out, "stderr": err},
    "error": None if rc == 0 else {
        "code": "local_command_failed", "message": err,
        "retryable": False, "outcome": "failed"},
    "meta": {"transport": "local"},
}, ensure_ascii=False))
PY
}

# Run a privileged command string on the control machine. The command string
# is interpreted once by bash, mirroring ssh-skill exec semantics (including
# the documented operator-precedence caveat: use script mode or bash -c for
# compound commands).
run_local() {
  local cmd="$1" out err rc
  out="$(mktemp)"; err="$(mktemp)"
  pass show "$entry" | bash -c "sudo -S -k -p \"\" $cmd" >"$out" 2>"$err" && rc=0 || rc=$?
  emit_json "$rc" "$out" "$err" "$cmd"
  rm -f "$out" "$err"
  return "$rc"
}

run_local_script() {
  local file="$1" out err rc
  out="$(mktemp)"; err="$(mktemp)"
  { pass show "$entry"; cat "$file"; } | sudo -S -k -p "" bash -s >"$out" 2>"$err" && rc=0 || rc=$?
  emit_json "$rc" "$out" "$err" "bash -s < $file"
  rm -f "$out" "$err"
  return "$rc"
}

case "$mode" in
  probe)
    # Close stdin: a probe must never consume the caller's input stream.
    if is_local; then
      out="$(mktemp)"
      bash -c 'sudo -n true 2>/dev/null && echo SUDO_NOPASSWD || echo SUDO_NEEDS_PASSWORD' \
        >"$out" 2>/dev/null && rc=0 || rc=$?
      emit_json "$rc" "$out" /dev/null "sudo -n true (probe)"
      rm -f "$out"
      exit 0
    fi
    require_cli
    # --timeout bounds unreachable targets; stdin closed (see above).
    exec python3 "$SSH_SKILL_CLI" exec "$alias" \
      'sudo -n true 2>/dev/null && echo SUDO_NOPASSWD || echo SUDO_NEEDS_PASSWORD' \
      --timeout 30 < /dev/null
    ;;
  exec)
    [ $# -ge 3 ] || die "exec mode needs a command"
    require_entry
    if is_local; then
      run_local "$3"
      exit $?
    fi
    require_cli
    pass show "$entry" \
      | python3 "$SSH_SKILL_CLI" exec "$alias" "sudo -S -k -p \"\" $3"
    ;;
  script)
    [ $# -ge 3 ] || die "script mode needs a local script file"
    [ -f "$3" ] || die "script file not found: $3"
    require_entry
    if is_local; then
      run_local_script "$3"
      exit $?
    fi
    require_cli
    { pass show "$entry"; cat "$3"; } \
      | python3 "$SSH_SKILL_CLI" exec "$alias" 'sudo -S -k -p "" bash -s'
    ;;
  *)
    die "unknown mode: $mode (expected probe|exec|script)"
    ;;
esac
