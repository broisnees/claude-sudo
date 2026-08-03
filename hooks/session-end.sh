#!/usr/bin/env bash
# claude-sudo SessionEnd hook — sudo mode never outlives the session that armed it.
set -uo pipefail

_here=$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/common.sh
. "$_here/../lib/common.sh"

input=$(cat 2>/dev/null || printf '')
sid=
if [ -n "$input" ] && command -v jq >/dev/null 2>&1; then
  sid=$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null) || sid=
fi
[ -n "$sid" ] || sid=$(cs_current_session)

if [ -n "$sid" ] && cs_disarm "$sid" 2>/dev/null; then
  cs_log disarm "session=$sid" source=session-end
fi

# Drop any sudo credential this session may have cached, so the password stays
# useless to anything that is not an armed Claude Code session.
if [ "${CLAUDE_SUDO_KILL_TIMESTAMP:-0}" = 1 ]; then
  sudo -K >/dev/null 2>&1 || true
else
  sudo -k >/dev/null 2>&1 || true
fi

cs_reap
exit 0
