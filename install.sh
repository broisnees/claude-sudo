#!/usr/bin/env bash
# claude-sudo installer.
#
# One line, from anywhere:
#   curl -fsSL https://raw.githubusercontent.com/broisnischal/claude-sudo/main/install.sh | bash
#
# From a checkout:
#   ./install.sh                  install, wire everything, ask for the password
#   ./install.sh --in-place       run from this checkout instead of copying out
#   ./install.sh --no-password    wire only; store the password later
#   ./install.sh --prefix DIR     install somewhere else (or set CLAUDE_SUDO_PREFIX)
#   ./install.sh --bindir DIR     put the claude-sudo symlink somewhere specific
#   ./install.sh --no-statusline  skip the [SUDO ⏵⏵] status line badge
set -euo pipefail

REPO_URL="${CLAUDE_SUDO_REPO:-https://github.com/broisnischal/claude-sudo}"
: "${XDG_DATA_HOME:=$HOME/.local/share}"
PREFIX="${CLAUDE_SUDO_PREFIX:-$XDG_DATA_HOME/claude-sudo}"

die()  { printf '  \033[31merror\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
info() { printf '  \033[2m·\033[0m %s\n' "$*"; }

SELF_DIR=$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || printf '.')")" 2>/dev/null && pwd || printf '.')

# ------------------------------------------------------------- bootstrap ---
# Piped from curl there is no checkout to install from, so fetch one first and
# hand over to it. The install directory stays a git checkout, which is what
# `claude-sudo update` later pulls into.
if [ ! -f "$SELF_DIR/lib/common.sh" ]; then
  printf '\n\033[1mclaude-sudo\033[0m — fetching the source\n\n'
  prev=
  for a in "$@"; do [ "$prev" = --prefix ] && PREFIX=$a; prev=$a; done
  command -v git >/dev/null 2>&1 || die "git is required to bootstrap the install"
  if [ -d "$PREFIX/.git" ]; then
    git -C "$PREFIX" fetch --depth 1 -q origin HEAD 2>/dev/null \
      && git -C "$PREFIX" reset --hard -q FETCH_HEAD 2>/dev/null \
      && ok "updated the existing checkout at $PREFIX" \
      || warn "could not update $PREFIX; using what is already there"
  else
    if [ -e "$PREFIX" ]; then
      mv "$PREFIX" "$PREFIX.old.$(date +%Y%m%d%H%M%S)"
      warn "moved the previous install aside"
    fi
    mkdir -p "$(dirname -- "$PREFIX")"
    git clone --depth 1 -q "$REPO_URL" "$PREFIX" || die "could not clone $REPO_URL"
    ok "cloned into $PREFIX"
  fi
  exec bash "$PREFIX/install.sh" --in-place "$@"
fi

SRC="$SELF_DIR"
BINDIR=
DO_PASSWORD=1
DO_STATUSLINE=1
IN_PLACE=0

while [ $# -gt 0 ]; do
  case $1 in
    --prefix) PREFIX=${2:?}; shift 2 ;;
    --bindir) BINDIR=${2:?}; shift 2 ;;
    --no-password) DO_PASSWORD=0; shift ;;
    --no-statusline) DO_STATUSLINE=0; shift ;;
    --in-place) IN_PLACE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

VERSION=$(sed -n 's/^CLAUDE_SUDO_VERSION="\(.*\)"/\1/p' "$SRC/lib/common.sh" | head -1)
printf '\n\033[1mclaude-sudo %s\033[0m — a sudo mode for Claude Code\n\n' "${VERSION:-?}"

# ---------------------------------------------------------- prerequisites ---
[ -n "${BASH_VERSION:-}" ] || die "run this with bash"
case ${BASH_VERSION%%.*} in [0-3]) die "bash 4+ required (found $BASH_VERSION)" ;; esac
command -v jq >/dev/null 2>&1 || die "jq is required — install it first (pacman -S jq / apt install jq / brew install jq)"
command -v sudo >/dev/null 2>&1 || die "sudo is not installed"
command -v claude >/dev/null 2>&1 || warn "claude is not on PATH; install Claude Code before using sudo mode"

if command -v secret-tool >/dev/null 2>&1; then ok "secret store: libsecret (secret-tool)"
elif [ "$(uname -s)" = Darwin ] && command -v security >/dev/null 2>&1; then ok "secret store: macOS keychain"
elif command -v pass >/dev/null 2>&1; then ok "secret store: pass"
elif command -v gpg >/dev/null 2>&1; then warn "secret store: gpg fallback (gpg-agent will cache the passphrase)"
else die "no secret store found. Install libsecret (secret-tool), pass, or gnupg."
fi

# ------------------------------------------------------------ place files ---
if [ "$IN_PLACE" = 1 ] || [ "$SRC" = "$PREFIX" ]; then
  DEST="$SRC"
  info "running from $DEST"
else
  DEST="$PREFIX"
  case $DEST in *\"*) die "install path must not contain a double quote: $DEST" ;; esac
  for d in bin lib libexec libexec/shim hooks commands config tests; do mkdir -p "$DEST/$d"; done
  cp -f "$SRC/bin/claude-sudo" "$SRC/bin/claude-sudo-statusline" "$DEST/bin/"
  cp -f "$SRC/lib/"*.sh                       "$DEST/lib/"
  cp -f "$SRC/libexec/claude-sudo-askpass"    "$DEST/libexec/"
  cp -f "$SRC/libexec/shim/sudo"              "$DEST/libexec/shim/"
  cp -f "$SRC/hooks/"*.sh                     "$DEST/hooks/"
  # Carried along so the installed tree is a complete copy, usable as a plugin
  # source too. Nothing registers it on its own.
  cp -f "$SRC/hooks/hooks.json"               "$DEST/hooks/" 2>/dev/null || true
  mkdir -p "$DEST/.claude-plugin" && cp -f "$SRC/.claude-plugin/"*.json "$DEST/.claude-plugin/" 2>/dev/null || true
  cp -f "$SRC/commands/sudo.md"               "$DEST/commands/"
  cp -f "$SRC/config/policy.default.conf"     "$DEST/config/"
  cp -f "$SRC/tests/smoke.sh"                 "$DEST/tests/" 2>/dev/null || true
  ok "installed to $DEST"
fi

chmod 755 "$DEST/bin/"* "$DEST/libexec/claude-sudo-askpass" \
          "$DEST/libexec/shim/sudo" "$DEST/hooks/"*.sh 2>/dev/null || true

# --------------------------------------------------------------- symlink ---
# PATH entries are compared after resolution — ~/.local/share/../bin and
# ~/.local/bin are the same directory, and a spurious warning is worse than none.
on_path() {
  local want dir entry
  want=$(readlink -f "$1" 2>/dev/null || printf '%s' "$1")
  IFS=: read -r -a _path_entries <<<"${PATH:-}"
  for entry in "${_path_entries[@]}"; do
    [ -n "$entry" ] || continue
    dir=$(readlink -f "$entry" 2>/dev/null || printf '%s' "$entry")
    [ "$dir" = "$want" ] && return 0
  done
  return 1
}

if [ -z "$BINDIR" ]; then
  for c in "$HOME/.local/bin" "$HOME/bin"; do
    if on_path "$c"; then BINDIR=$c; break; fi
  done
  [ -n "$BINDIR" ] || BINDIR="$HOME/.local/bin"
fi
mkdir -p "$BINDIR"
ln -sf "$DEST/bin/claude-sudo" "$BINDIR/claude-sudo"
ln -sf "$DEST/bin/claude-sudo" "$BINDIR/csudo"
ok "linked $BINDIR/claude-sudo (and csudo)"
if ! on_path "$BINDIR"; then
  warn "$BINDIR is not on your PATH — add this to your shell rc:"
  printf '        export PATH="%s:$PATH"\n' "$BINDIR"
fi

# ---------------------------------------------------------------- wiring ---
"$DEST/bin/claude-sudo" hooks install
[ "$DO_STATUSLINE" = 1 ] && "$DEST/bin/claude-sudo" statusline install

# -------------------------------------------------------------- password ---
if [ "$DO_PASSWORD" = 1 ]; then
  if [ "${CLAUDECODE:-0}" = 1 ]; then
    warn "inside a Claude Code session, so the password step is skipped"
    info "run this in your own terminal:  claude-sudo passwd"
  elif [ ! -r /dev/tty ]; then
    warn "no terminal available, so the password step is skipped"
    info "run this when you have one:  claude-sudo passwd"
  else
    printf '\n\033[1mStore your sudo password\033[0m\n'
    info "verified against sudo, then kept in the OS keyring"
    info "never written to disk in plaintext, never in an env var, never in the transcript"
    printf '\n'
    "$DEST/bin/claude-sudo" passwd || warn "password step failed — rerun: claude-sudo passwd"
  fi
fi

# --------------------------------------------------------------- the choice ---
"$DEST/bin/claude-sudo" autoarm ask

printf '\n\033[1mDone.\033[0m Sudo mode is installed and OFF until you arm it.\n\n'
cat <<'EOF'
  claude-sudo autoarm on               arm every new session automatically
  Shift+Tab → ⏵⏵ bypass permissions    arms sudo mode; cycling out disarms it
  /sudo on                             arm the current session explicitly
  csudo                                start Claude Code already armed

  claude-sudo doctor                   verify end to end
  claude-sudo audit                    every privileged command it has run
  claude-sudo update                   pull the latest version

EOF
