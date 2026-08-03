#!/usr/bin/env bash
# claude-sudo PreToolUse gate. Runs on every tool call; returns in about a
# millisecond unless something could be armed.
#
# Sudo mode rides on a permission mode. Every hook payload carries
# `permission_mode`, so cycling Shift+Tab into bypassPermissions arms sudo mode
# and cycling out of it disarms again — Shift+Tab is the switch. `/sudo on`
# still works independently and is not affected by mode changes.
#
# While armed it:
#   1. blocks commands the policy calls unrecoverable (deny) and hands
#      credential/firewall/package-removal work back to a human decision;
#   2. rewrites Bash commands that use sudo so they authenticate through the
#      askpass helper — this is what makes arming a *running* session work,
#      since its environment cannot be changed from outside;
#   3. auto-approves everything else, which is the "stop asking me" half.
#
# Claude Code consults this hook before the permission system in every mode, and
# a `deny` here is returned as-is, so the guardrails hold even in a mode that
# never prompts. An `ask` would not: in bypassPermissions it degrades to allow,
# so `ask` is escalated to a refusal there (see cs_ask_in_bypass).
set -uo pipefail

_here=$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=../lib/common.sh
. "$_here/../lib/common.sh"
# shellcheck source=../lib/policy.sh
. "$_here/../lib/policy.sh"

input=$(cat)
[ -n "$input" ] || exit 0

# --- fast path, no jq -------------------------------------------------------
# Anything already armed?
maybe_armed=0
[ -n "${CLAUDE_SUDO_ARMED:-}" ] && maybe_armed=1
[ "$maybe_armed" = 0 ] && compgen -G "$CS_SESSIONS/*" >/dev/null 2>&1 && maybe_armed=1

# Is the session in a permission mode that arms sudo mode by itself?
mode_arms=0
while IFS= read -r m || [ -n "$m" ]; do
  [ -n "$m" ] || continue
  [ "$m" = none ] && break
  case $input in *"\"permission_mode\":\"$m\""*) mode_arms=1; break ;; esac
done < <(cs_arm_modes)

[ "$maybe_armed" = 1 ] || [ "$mode_arms" = 1 ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# One jq pass for the scalar fields. Unit-separated, because unlike a tab it is
# not IFS whitespace, so an empty field cannot shift the columns. The command is
# fetched separately below: it can contain newlines, which `read` would truncate.
IFS=$'\x1f' read -r sid mode tool cwd < <(
  jq -r '[(.session_id//""),(.permission_mode//""),(.tool_name//""),(.cwd//"")]|join("")' \
    <<<"$input" 2>/dev/null
) || true

# --- arm / disarm from the permission mode ----------------------------------
if expiry=$(cs_expiry "$sid"); then
  # Armed by the mode, but the mode has since been left: sudo mode goes with it.
  if [ "$mode_arms" = 0 ] && [ -n "$sid" ] && [ "$(cs_session_source "$sid" 2>/dev/null)" = permission-mode ]; then
    cs_disarm "$sid" && cs_log disarm "session=$sid" source=permission-mode "mode=$mode"
    exit 0
  fi
  # Armed through the launcher's environment: materialise the session file so
  # `claude-sudo status`, /sudo and the SessionEnd cleanup all see it too.
  if [ -n "$sid" ] && [ ! -f "$(cs_session_file "$sid")" ]; then
    cs_arm "$sid" "$CS_DEFAULT_TTL" launcher >/dev/null
    cs_log arm "session=$sid" source=launcher "expires=$expiry"
  fi
elif [ "$mode_arms" = 1 ] && [ -n "$sid" ]; then
  # A mode that never prompts is only worth arming if there is a password to
  # use. The marker keeps that check to once per session instead of per call.
  marker=$(cs_marker_file "$sid")
  [ -f "$marker" ] && exit 0
  # shellcheck source=../lib/vault.sh
  . "$_here/../lib/vault.sh"
  if cs_vault_has; then
    expiry=$(cs_arm "$sid" "$CS_DEFAULT_TTL" permission-mode)
    cs_log arm "session=$sid" source=permission-mode "mode=$mode" "expires=$expiry"
  else
    cs_init_dirs && : >"$marker"
    cs_log arm-skipped "session=$sid" reason=no-password "mode=$mode"
    exit 0
  fi
else
  exit 0
fi

# --- decide ------------------------------------------------------------------
emit() { # emit <allow|deny|ask> <reason> [updated-input-json]
  local decision=$1 reason=$2 updated=${3:-}
  if [ -n "$updated" ]; then
    jq -cn --arg d "$decision" --arg r "$reason" --argjson u "$updated" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r,updatedInput:$u}}'
  else
    jq -cn --arg d "$decision" --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  fi
  exit 0
}

if [ "$tool" != Bash ]; then
  emit allow "claude-sudo: sudo mode armed"
fi

cmd=$(jq -r '.tool_input.command // ""' <<<"$input" 2>/dev/null)
if [ -n "$cmd" ]; then
  IFS=$'\t' read -r verdict reason <<<"$(cs_policy_check "$cmd")"
  case $verdict in
    deny)
      cs_log policy-deny "session=$sid" "mode=$mode" "reason=$reason" "cmd=$cmd"
      emit deny "claude-sudo policy: $reason. Refusing even in sudo mode — do this yourself if you really mean it." ;;
    ask)
      # `ask` only means something in a mode that still prompts.
      if [ "$mode_arms" = 1 ] && [ "$(cs_ask_in_bypass)" = deny ]; then
        cs_log policy-deny-escalated "session=$sid" "mode=$mode" "reason=$reason" "cmd=$cmd"
        emit deny "claude-sudo policy: $reason — and in $mode nothing prompts, so an approval request would be rubber-stamped. Shift+Tab back to a mode that asks, then approve it yourself."
      fi
      cs_log policy-ask "session=$sid" "mode=$mode" "reason=$reason" "cmd=$cmd"
      emit ask "claude-sudo policy: $reason — needs your explicit approval." ;;
  esac
fi

# Not a sudo command, and policy is happy: just skip the prompt.
if ! [[ $cmd =~ (^|[^[:alnum:]_./-])sudo(edit)?([[:space:]]|$) ]]; then
  emit allow "claude-sudo: sudo mode armed"
fi

# Already carrying our environment (hook ran twice, or the launcher set it up).
case $cmd in
  *CLAUDE_SUDO_SESSION=*)
    cs_log sudo-command "session=$sid" "mode=$mode" "cwd=$cwd" "cmd=$cmd"
    emit allow "claude-sudo: sudo mode armed (askpass already wired)" ;;
esac

prefix="export PATH=\"$CS_SHIM:\$PATH\" SUDO_ASKPASS=\"$CS_ASKPASS\" CLAUDE_SUDO_SESSION=\"$sid\"; "
updated=$(jq -c --arg c "$prefix$cmd" '.tool_input + {command:$c}' <<<"$input" 2>/dev/null) || updated=
cs_log sudo-command "session=$sid" "mode=$mode" "cwd=$cwd" "cmd=$cmd"
emit allow "claude-sudo: sudo mode armed; sudo will authenticate from the stored password" "$updated"
