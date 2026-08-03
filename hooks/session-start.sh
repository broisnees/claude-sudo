#!/usr/bin/env bash
# claude-sudo SessionStart hook — the opt-in "always on" path.
#
# With auto-arm enabled, sudo mode is live from the first prompt of every
# session: no Shift+Tab, no /sudo on. Arming here is attributed to `auto`, so
# cycling permission modes does not disarm it; only /sudo off, the TTL, or the
# end of the session does.
#
# Prints one line when it arms, which Claude Code adds to the session context —
# so the model knows not to ask for a password or suggest editing sudoers.
set -uo pipefail

_here=$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/common.sh
. "$_here/../lib/common.sh"

cs_autoarm_on || exit 0

input=$(cat 2>/dev/null || printf '')
sid=
if [ -n "$input" ] && command -v jq >/dev/null 2>&1; then
  sid=$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null) || sid=
fi
[ -n "$sid" ] || sid=$(cs_current_session)
[ -n "$sid" ] || exit 0

# Already armed by hand or by a launcher: leave that alone.
cs_armed "$sid" && exit 0

# shellcheck source=../lib/vault.sh
. "$_here/../lib/vault.sh"
if ! cs_vault_has; then
  cs_init_dirs && : >"$(cs_marker_file "$sid")"
  cs_log arm-skipped "session=$sid" reason=no-password source=auto
  printf 'claude-sudo: auto-arm is on but no password is stored — tell the user to run `claude-sudo passwd` in their own terminal.\n'
  exit 0
fi

exp=$(cs_arm "$sid" "$CS_DEFAULT_TTL" auto) || exit 0
cs_log arm "session=$sid" source=auto "expires=$exp"
printf 'claude-sudo: sudo mode is armed for this session (%s). Permission prompts are skipped and `sudo` authenticates from the OS keyring — never ask the user for their password, never use `sudo -S`, and never edit /etc/sudoers. Some commands are still refused by policy; if that happens, report the reason instead of working around it.\n' \
  "$(cs_fmt_expiry "$exp")"
exit 0
