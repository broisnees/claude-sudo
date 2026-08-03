# shellcheck shell=bash
# claude-sudo — the guardrail that stays on even in sudo mode.
#
# Rule file format, one rule per line, TAB-separated:
#   <action>\t<extended-regex>\t<reason>
# action: deny  -> hard block, Claude cannot run it even armed
#         ask   -> hand the decision back to you
# First matching rule wins. Lines starting with # and blank lines are ignored.
# User rules at $CS_CONFIG/policy.conf replace the shipped defaults entirely.
#
# Matching uses bash's own =~ rather than grep: this runs on every Bash command
# of an armed session, and ~25 rules should not mean ~25 processes.

cs_policy_file() {
  if [ -f "$CS_CONFIG/policy.conf" ]; then printf '%s' "$CS_CONFIG/policy.conf"
  else printf '%s' "$CS_ROOT/config/policy.default.conf"; fi
}

# cs_policy_check <command> -> prints "allow" | "deny\t<reason>" | "ask\t<reason>"
cs_policy_check() {
  local cmd=$1 file action re reason
  file=$(cs_policy_file)
  [ -f "$file" ] || { printf 'allow'; return 0; }
  while IFS=$'\t' read -r action re reason || [ -n "${action:-}" ]; do
    case $action in ''|'#'*) continue ;; esac
    [ -n "$re" ] || continue
    # A malformed user rule must not take the whole gate down with it.
    if [[ $cmd =~ $re ]] 2>/dev/null; then
      printf '%s\t%s' "$action" "${reason:-blocked by claude-sudo policy}"
      return 0
    fi
  done <"$file"
  printf 'allow'
}

# cs_policy_count -> "<deny-rules> <ask-rules>"
cs_policy_count() {
  local file d=0 a=0 action rest
  file=$(cs_policy_file)
  while IFS=$'\t' read -r action rest || [ -n "${action:-}" ]; do
    case $action in deny) d=$((d+1)) ;; ask) a=$((a+1)) ;; esac
  done <"$file"
  printf '%s %s' "$d" "$a"
}
