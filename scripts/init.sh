#!/usr/bin/env bash
# init.sh — guided onboarding for sudo-skill: one password-store entry per
# ssh-skill alias.
#
# Modes:
#   init.sh             interactive entry setup; the OWNER runs this in their
#                       own terminal. Passwords go straight into `pass insert`
#                       with hidden terminal input — they never appear on the
#                       command line, in files, or in any agent transcript.
#   init.sh --probe     same, but first probes each host and auto-skips hosts
#                       whose sudo is already NOPASSWD.
#   init.sh --check     list aliases and whether a store entry exists.
#                       Non-interactive and agent-safe (no decryption).
#   init.sh --verify    end-to-end test every existing entry by piping it into
#                       remote `sudo -S true`. Agent-safe: the secret stays
#                       inside the pipe.
#
# Environment:
#   SSH_SKILL_ROOT    ssh-skill directory (default: ~/.agents/skills/ssh-skill)
#   SUDO_ENTRY_PREFIX entry name prefix  (default: ops/sudo@)
#   PASSWORD_STORE_DIR pass store dir    (default: ~/.password-store)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUDO_EXEC="$SCRIPT_DIR/sudo_exec.sh"
SSH_SKILL_ROOT="${SSH_SKILL_ROOT:-$HOME/.agents/skills/ssh-skill}"
SSH_SKILL_CLI="$SSH_SKILL_ROOT/scripts/ssh_skill.py"
STORE_DIR="${PASSWORD_STORE_DIR:-$HOME/.password-store}"
ENTRY_PREFIX="${SUDO_ENTRY_PREFIX:-ops/sudo@}"

die() { printf 'init: %s\n' "$*" >&2; exit 2; }

list_aliases() {
  [ -f "$SSH_SKILL_CLI" ] || die "ssh-skill CLI not found at $SSH_SKILL_CLI (set SSH_SKILL_ROOT)"
  python3 "$SSH_SKILL_CLI" config list-servers \
    | python3 -c 'import json,sys; print("\n".join(s["alias"] for s in json.load(sys.stdin)["data"]["servers"]))'
}

entry_exists() { [ -f "$STORE_DIR/$ENTRY_PREFIX$1.gpg" ]; }

probe_host() {
  # Echoes exactly one marker line (SUDO_NOPASSWD / SUDO_NEEDS_PASSWORD),
  # or nothing on probe failure. Only the JSON data.stdout field is
  # inspected — the result's echoed command text also contains the marker
  # strings and would false-match a naive grep.
  # stdin is closed explicitly: a probe must never consume the caller's
  # terminal input, and an open/flooded stdin can stall the exec transport.
  # --timeout bounds unreachable hosts.
  python3 "$SSH_SKILL_CLI" exec "$1" \
    'sudo -n true 2>/dev/null && echo SUDO_NOPASSWD || echo SUDO_NEEDS_PASSWORD' \
    --timeout 30 < /dev/null 2>/dev/null \
    | python3 -c '
import json, sys
try:
    out = (json.load(sys.stdin).get("data") or {}).get("stdout") or ""
except Exception:
    out = ""
if "SUDO_NEEDS_PASSWORD" in out:
    print("SUDO_NEEDS_PASSWORD")
elif "SUDO_NOPASSWD" in out:
    print("SUDO_NOPASSWD")
'
}

mode="${1:-}"

case "$mode" in
  --check)
    for alias in $(list_aliases); do
      if entry_exists "$alias"; then st="有条目"; else st="缺条目"; fi
      printf '%-16s %s\n' "$alias" "$st"
    done
    ;;

  --verify)
    rc=0
    for alias in $(list_aliases); do
      if ! entry_exists "$alias"; then
        printf '%-16s 跳过（缺条目）\n' "$alias"
        continue
      fi
      if "$SUDO_EXEC" exec "$alias" 'true' >/dev/null 2>&1; then
        printf '%-16s 验证通过\n' "$alias"
      else
        printf '%-16s 验证失败（密码错误、主机不可达或 sudo 异常）\n' "$alias"
        rc=1
      fi
    done
    exit "$rc"
    ;;

  ""|--probe)
    [ -t 0 ] || die "交互模式需要真实终端；请在你自己的 shell 里运行本脚本"
    [ -f "$STORE_DIR/.gpg-id" ] || die "密码库未初始化，请先运行: pass init <GPG_KEY_ID>"
    command -v pass >/dev/null 2>&1 || die "pass(1) 未安装"

    aliases="$(list_aliases)"
    [ -n "$aliases" ] || die "未发现任何 SSH 别名"

    echo "ssh-skill 中已配置的主机别名："
    for alias in $aliases; do
      if entry_exists "$alias"; then mark="[已有条目]"; else mark="[缺条目]"; fi
      printf '  %-16s %s\n' "$alias" "$mark"
    done
    echo

    for alias in $aliases; do
      if entry_exists "$alias"; then
        echo ">>> $alias：条目已存在，跳过"
        continue
      fi
      if [ "$mode" = "--probe" ]; then
        case "$(probe_host "$alias")" in
          SUDO_NOPASSWD) echo ">>> $alias：sudo 已免密（NOPASSWD），无需条目，跳过"; continue ;;
          SUDO_NEEDS_PASSWORD) echo ">>> $alias：sudo 需要密码" ;;
          *) echo ">>> $alias：探测失败（主机不可达或非 Linux），仍可手动录入" ;;
        esac
      fi
      printf '为 %s 录入 sudo 密码？[y/N] ' "$alias"
      read -r ans
      case "$ans" in
        y|Y|yes|YES)
          if pass insert "$ENTRY_PREFIX$alias"; then
            echo ">>> $alias：已录入 $ENTRY_PREFIX$alias"
          else
            echo ">>> $alias：录入失败" >&2
          fi
          ;;
        *) echo ">>> $alias：跳过" ;;
      esac
    done

    echo
    echo "录入结束。可运行以下命令做端到端验证："
    echo "  $0 --verify"
    ;;

  *)
    die "用法: init.sh [--probe | --check | --verify]"
    ;;
esac
