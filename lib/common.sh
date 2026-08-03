# shellcheck shell=bash
# claude-sudo — shared state, arming and audit helpers.
# Sourced by bin/claude-sudo, libexec/* and hooks/*. No side effects beyond var defs.

CLAUDE_SUDO_VERSION="1.0.0"

: "${XDG_STATE_HOME:=$HOME/.local/state}"
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_DATA_HOME:=$HOME/.local/share}"

# Install root = parent of the dir holding this file.
CS_ROOT="${CLAUDE_SUDO_ROOT:-$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
CS_STATE="${CLAUDE_SUDO_STATE:-$XDG_STATE_HOME/claude-sudo}"
CS_CONFIG="${CLAUDE_SUDO_CONFIG:-$XDG_CONFIG_HOME/claude-sudo}"
CS_SESSIONS="$CS_STATE/sessions"
CS_AUDIT="$CS_STATE/audit.log"
CS_ASKPASS="$CS_ROOT/libexec/claude-sudo-askpass"
CS_SHIM="$CS_ROOT/libexec/shim"
CS_SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
# Default arming window, minutes. 0 = until the session ends.
CS_DEFAULT_TTL="${CLAUDE_SUDO_TTL:-480}"

cs_die() { printf 'claude-sudo: %s\n' "$*" >&2; exit 1; }
cs_warn() { printf 'claude-sudo: %s\n' "$*" >&2; }

# cs_colors [force|off] — sets CS_RED/GREEN/YELLOW/DIM/BOLD/RST.
# Honours NO_COLOR and a non-terminal stdout; the status line passes `force`
# because its stdout is always a pipe yet its output is rendered in a terminal.
cs_colors() {
  local want=${1:-auto}
  if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = dumb ]; then want=off; fi
  if [ "$want" = force ] || { [ "$want" != off ] && [ -t 1 ]; }; then
    CS_RED=$'\033[38;5;167m'; CS_GREEN=$'\033[38;5;108m'; CS_YELLOW=$'\033[38;5;179m'
    CS_DIM=$'\033[38;5;245m'; CS_BOLD=$'\033[1m'; CS_RST=$'\033[0m'
  else
    CS_RED=; CS_GREEN=; CS_YELLOW=; CS_DIM=; CS_BOLD=; CS_RST=
  fi
}

cs_init_dirs() {
  umask 077
  mkdir -p "$CS_SESSIONS" "$CS_CONFIG" || return 1
  [ -e "$CS_AUDIT" ] || : >"$CS_AUDIT"
  chmod 700 "$CS_STATE" "$CS_SESSIONS" "$CS_CONFIG" 2>/dev/null || true
  chmod 600 "$CS_AUDIT" 2>/dev/null || true
}

cs_now() { date +%s; }
cs_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# cs_log <event> [key=value ...]  — single-line, newline-sanitised audit record.
cs_log() {
  local ev=$1 kv; shift
  cs_init_dirs 2>/dev/null || return 0
  {
    printf 'ts=%s event=%s pid=%s' "$(cs_iso)" "$ev" "$$"
    for kv in "$@"; do
      kv=${kv//$'\n'/ }; kv=${kv//$'\r'/ }
      printf ' %s' "$kv"
    done
    printf '\n'
  } >>"$CS_AUDIT" 2>/dev/null || true
}

cs_is_uint() { case ${1:-} in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

# Session ids come from Claude Code; keep them filesystem-safe regardless.
cs_session_file() { printf '%s/%s' "$CS_SESSIONS" "${1//[^A-Za-z0-9._-]/_}"; }

cs_current_session() {
  printf '%s' "${CLAUDE_SUDO_SESSION:-${CLAUDE_CODE_SESSION_ID:-}}"
}

# Permission modes that arm sudo mode on their own, so Shift+Tab is the switch.
# One mode per line in $CS_CONFIG/arm-modes; `none` disables the coupling.
cs_arm_modes() {
  local f="$CS_CONFIG/arm-modes"
  if [ -f "$f" ]; then
    grep -vE '^\s*(#|$)' "$f" 2>/dev/null | tr -d ' \t\r'
  else
    # Trailing newline matters: `while read` drops the last line without one.
    printf '%s\n' "${CLAUDE_SUDO_ARM_MODES:-bypassPermissions}" | tr ',' '\n'
  fi
}

# Auto-arm: sudo mode on from the first prompt of every session, no Shift+Tab and
# no /sudo on. Off unless the user opts in, because it makes every new session
# skip permission prompts.
cs_autoarm() {
  local f="$CS_CONFIG/autoarm" v=
  if [ -n "${CLAUDE_SUDO_AUTOARM:-}" ]; then printf '%s' "$CLAUDE_SUDO_AUTOARM"; return 0; fi
  if [ -f "$f" ]; then read -r v <"$f" 2>/dev/null || v=; fi
  printf '%s' "${v:-off}"
}

cs_autoarm_on() { [ "$(cs_autoarm)" = on ]; }

# In a mode that never prompts, a policy `ask` would be silently allowed, so it
# is escalated to a refusal instead. Set to `allow` to accept the old behaviour.
cs_ask_in_bypass() {
  local f="$CS_CONFIG/ask-in-bypass" v=
  if [ -f "$f" ]; then
    read -r v <"$f" 2>/dev/null || v=
    printf '%s' "${v:-deny}"
  else
    printf '%s' "${CLAUDE_SUDO_ASK_IN_BYPASS:-deny}"
  fi
}

# cs_arm <session-id> [ttl-minutes] [source]  — persist the armed window.
# Line 1 is the expiry, line 2 records who armed it: a session armed by the
# permission mode is disarmed again when that mode is left, while one armed by
# hand stays until it expires.
cs_arm() {
  local sid=$1 ttl=${2:-$CS_DEFAULT_TTL} src=${3:-manual} exp f
  [ -n "$sid" ] || return 1
  cs_is_uint "$ttl" || ttl=$CS_DEFAULT_TTL
  if [ "$ttl" -eq 0 ]; then exp=0; else exp=$(( $(cs_now) + ttl * 60 )); fi
  cs_init_dirs || return 1
  f=$(cs_session_file "$sid")
  printf '%s\n%s\n' "$exp" "$src" >"$f" && chmod 600 "$f" 2>/dev/null
  printf '%s' "$exp"
}

# cs_session_source <session-id> -> manual | permission-mode | launcher
cs_session_source() {
  local f src
  f=$(cs_session_file "$1")
  [ -f "$f" ] || return 1
  src=$(sed -n '2p' "$f" 2>/dev/null)
  printf '%s' "${src:-manual}"
}

cs_disarm() {
  local sid=$1 f
  [ -n "$sid" ] || return 1
  f=$(cs_session_file "$sid")
  [ -f "$f" ] || return 1
  rm -f "$f"
}

# cs_expiry <session-id> -> epoch on stdout (0 = no expiry), non-zero rc if not armed.
cs_expiry() {
  local sid=${1:-} exp now
  now=$(cs_now)
  if [ -n "${CLAUDE_SUDO_ARMED:-}" ]; then
    exp=${CLAUDE_SUDO_EXPIRES:-0}
    cs_is_uint "$exp" || exp=0
    if [ "$exp" -eq 0 ] || [ "$exp" -gt "$now" ]; then printf '%s' "$exp"; return 0; fi
  fi
  [ -n "$sid" ] || sid=$(cs_current_session)
  [ -n "$sid" ] || return 1
  local f; f=$(cs_session_file "$sid")
  [ -f "$f" ] || return 1
  read -r exp <"$f" 2>/dev/null || exp=0
  cs_is_uint "$exp" || exp=0
  if [ "$exp" -ne 0 ] && [ "$exp" -le "$now" ]; then rm -f "$f"; return 1; fi
  printf '%s' "$exp"
}

# cs_armed [session-id] — true when sudo mode is active for that session.
cs_armed() { cs_expiry "${1:-}" >/dev/null 2>&1; }

cs_fmt_expiry() {
  local exp=$1
  [ "$exp" = 0 ] && { printf 'until session end'; return; }
  printf 'until %s (%dm left)' "$(date -d "@$exp" '+%H:%M' 2>/dev/null || date -r "$exp" '+%H:%M' 2>/dev/null || printf '%s' "$exp")" \
    "$(( (exp - $(cs_now) + 59) / 60 ))"
}

# Drop session files whose window has closed, and any marker left behind.
cs_reap() {
  local f exp now; now=$(cs_now)
  [ -d "$CS_SESSIONS" ] || return 0
  for f in "$CS_SESSIONS"/*; do
    [ -f "$f" ] || continue
    read -r exp <"$f" 2>/dev/null || exp=0
    cs_is_uint "$exp" || exp=0
    [ "$exp" -ne 0 ] && [ "$exp" -le "$now" ] && rm -f "$f"
  done
  # Markers only matter while their session lives.
  for f in "$CS_STATE"/no-password.*; do
    [ -f "$f" ] || continue
    [ -f "$CS_SESSIONS/${f##*/no-password.}" ] || rm -f "$f"
  done
  return 0
}

cs_marker_file() { printf '%s/no-password.%s' "$CS_STATE" "${1//[^A-Za-z0-9._-]/_}"; }

# True when this copy is running from a Claude Code plugin directory, in which
# case hooks come from the plugin manifest and must not also go into settings.
cs_is_plugin_install() {
  case $CS_ROOT in
    */.claude/plugins/*|*/plugins/cache/*) return 0 ;;
    *) return 1 ;;
  esac
}
