#!/usr/bin/env bash
# claude-sudo uninstaller.
#
#   ./uninstall.sh            unwire hooks, remove the symlinks and the installed copy
#   ./uninstall.sh --purge    also delete the stored password, audit log and config
set -euo pipefail

: "${XDG_DATA_HOME:=$HOME/.local/share}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"
: "${XDG_CONFIG_HOME:=$HOME/.config}"

PURGE=0
[ "${1:-}" = --purge ] && PURGE=1

ok() { printf '  \033[32m✔\033[0m %s\n' "$*"; }
info() { printf '  \033[2m·\033[0m %s\n' "$*"; }

printf '\n\033[1mclaude-sudo uninstall\033[0m\n\n'

CLI=
for c in "$(command -v claude-sudo 2>/dev/null || true)" \
         "$XDG_DATA_HOME/claude-sudo/bin/claude-sudo" \
         "$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/bin/claude-sudo"; do
  [ -n "$c" ] && [ -x "$c" ] && { CLI=$c; break; }
done

if [ -n "$CLI" ]; then
  "$CLI" statusline uninstall || true
  "$CLI" hooks uninstall || true
  if [ "$PURGE" = 1 ]; then "$CLI" forget || true; fi
else
  info "CLI not found; clean ~/.claude/settings.json by hand if it still mentions claude-sudo"
fi

for d in "$HOME/.local/bin" "$HOME/bin" /usr/local/bin; do
  for n in claude-sudo csudo; do
    if [ -L "$d/$n" ] && readlink -f "$d/$n" 2>/dev/null | grep -q 'claude-sudo'; then
      rm -f "$d/$n"; ok "removed $d/$n"
    fi
  done
done

rm -f "$HOME/.claude/commands/sudo.md" 2>/dev/null && ok "removed the /sudo command" || true
rm -rf "$XDG_STATE_HOME/claude-sudo/sessions" 2>/dev/null || true
ok "disarmed every session"

if [ -d "$XDG_DATA_HOME/claude-sudo" ]; then
  rm -rf "$XDG_DATA_HOME/claude-sudo"; ok "removed $XDG_DATA_HOME/claude-sudo"
fi

if [ "$PURGE" = 1 ]; then
  rm -rf "$XDG_STATE_HOME/claude-sudo" "$XDG_CONFIG_HOME/claude-sudo"
  ok "purged state, audit log, config and the stored password"
else
  info "kept: $XDG_STATE_HOME/claude-sudo (audit log) and the keyring entry — use --purge to delete them"
fi

sudo -k >/dev/null 2>&1 || true
printf '\ndone\n\n'
