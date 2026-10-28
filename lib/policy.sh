# shellcheck shell=bash
# claude-sudo — the guardrail that stays on even in sudo mode.
#
# Two layers, both TAB-separated, one rule per line:
#   $CS_ROOT/config/policy.default.conf   shipped rules, each named: deny:<name>
#   $CS_CONFIG/policy.conf                per-user overrides
#
# Rule lines:  <action>[:<name>]\t<extended-regex>\t<reason>
#   action: deny  -> hard block, Claude cannot run it even armed
#           ask   -> hand the decision back to you
# The user file adds its own rules, and switches shipped ones off with:
#   off\t<name>   one shipped rule
#   off\task      every shipped ask rule (likewise off\tdeny, off\tall)
# Lines starting with # and blank lines are ignored.
#
# A deny anywhere wins over an ask, so a user rule can never shadow a deny
# that matches another part of the same command (`crontab -l; rm -rf /`).
#
# Matching uses bash's own =~ rather than grep: this runs on every Bash command
# of an armed session, and ~25 rules should not mean ~25 processes.

CS_POLICY_DEFAULT="$CS_ROOT/config/policy.default.conf"
CS_POLICY_USER="$CS_CONFIG/policy.conf"

# Kept for `status`: the file a person would edit.
cs_policy_file() { printf '%s' "$CS_POLICY_USER"; }

# _cs_policy_load -> fills the parallel arrays CS_R_{ACT,NAME,RE,WHY,SRC} with
# the active rules, and CS_R_OFF with the switched-off names/groups.
_cs_policy_load() {
  CS_R_ACT=() CS_R_NAME=() CS_R_RE=() CS_R_WHY=() CS_R_SRC=() CS_R_OFF=" "
  local action re reason act name
  if [ -f "$CS_POLICY_USER" ]; then
    while IFS=$'\t' read -r action re reason || [ -n "${action:-}" ]; do
      case $action in
        ''|'#'*) continue ;;
        off) CS_R_OFF+="$re " ; continue ;;
        'off '*) CS_R_OFF+="${action#off } " ; continue ;;
      esac
      act=${action%%:*}
      case $act in deny|ask) ;; *) continue ;; esac
      [ -n "$re" ] || continue
      name=; [ "$act" = "$action" ] || name=${action#*:}
      CS_R_ACT+=("$act") CS_R_NAME+=("$name") CS_R_RE+=("$re")
      CS_R_WHY+=("${reason:-blocked by claude-sudo policy}") CS_R_SRC+=(user)
    done <"$CS_POLICY_USER"
  fi
  [ -f "$CS_POLICY_DEFAULT" ] || return 0
  case $CS_R_OFF in *" all "*) return 0 ;; esac
  while IFS=$'\t' read -r action re reason || [ -n "${action:-}" ]; do
    case $action in ''|'#'*) continue ;; esac
    act=${action%%:*}
    case $act in deny|ask) ;; *) continue ;; esac
    [ -n "$re" ] || continue
    name=; [ "$act" = "$action" ] || name=${action#*:}
    case $CS_R_OFF in *" $act "*) continue ;; esac
    [ -n "$name" ] && case $CS_R_OFF in *" $name "*) continue ;; esac
    CS_R_ACT+=("$act") CS_R_NAME+=("$name") CS_R_RE+=("$re")
    CS_R_WHY+=("${reason:-blocked by claude-sudo policy}") CS_R_SRC+=(default)
  done <"$CS_POLICY_DEFAULT"
}

# cs_policy_check <command> -> prints "allow" | "deny\t<reason>" | "ask\t<reason>"
cs_policy_check() {
  local cmd=$1 i re ask=
  _cs_policy_load
  for i in "${!CS_R_RE[@]}"; do
    re=${CS_R_RE[i]}
    # A malformed user rule must not take the whole gate down with it.
    if [[ $cmd =~ $re ]] 2>/dev/null; then
      case ${CS_R_ACT[i]} in
        deny) printf 'deny\t%s' "${CS_R_WHY[i]}"; return 0 ;;
        ask) [ -n "$ask" ] || ask=${CS_R_WHY[i]} ;;
      esac
    fi
  done
  if [ -n "$ask" ]; then printf 'ask\t%s' "$ask"; else printf 'allow'; fi
}

# cs_policy_count -> "<deny-rules> <ask-rules>" (active rules only)
cs_policy_count() {
  local d=0 a=0 act
  _cs_policy_load
  for act in "${CS_R_ACT[@]}"; do
    case $act in deny) d=$((d+1)) ;; ask) a=$((a+1)) ;; esac
  done
  printf '%s %s' "$d" "$a"
}

# cs_policy_names -> every shipped rule name, one per line
cs_policy_names() {
  [ -f "$CS_POLICY_DEFAULT" ] || return 0
  awk -F'\t' '$1 ~ /^(deny|ask):/ { sub(/^[a-z]+:/, "", $1); print $1 }' "$CS_POLICY_DEFAULT"
}
