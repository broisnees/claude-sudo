# shellcheck shell=bash
# claude-sudo — password vault. The password lives in an OS secret store, never
# on disk in plaintext, never in argv, never in an exported env var.
#
# Backends, in auto-detect order:
#   libsecret  gnome-keyring / KWallet via secret-tool (encrypted, unlocked at login)
#   keychain   macOS login keychain via `security`
#   pass       password-store (GPG-encrypted, gpg-agent caches the passphrase)
#   gpg        symmetric AES256 file under $CS_STATE (gpg-agent caches the passphrase)
# Override with CLAUDE_SUDO_BACKEND or by writing the name to $CS_CONFIG/backend.

CS_SERVICE="${CLAUDE_SUDO_SERVICE:-claude-sudo}"
CS_ACCOUNT="${CLAUDE_SUDO_ACCOUNT:-${USER:-$(id -un)}}"
CS_HOSTNAME="${CLAUDE_SUDO_HOST:-$(hostname 2>/dev/null || uname -n 2>/dev/null || printf 'localhost')}"
CS_VAULT_TIMEOUT="${CLAUDE_SUDO_VAULT_TIMEOUT:-15}"

# The host is stored as an attribute but NOT required when looking up, because
# machines rename themselves — a randomised or DHCP-assigned hostname would
# otherwise orphan a perfectly good password and look exactly like "no password
# stored". libsecret matches on a subset of attributes, so service+account is
# enough. Set CLAUDE_SUDO_HOST explicitly to demand an exact host match, which
# is what you want when one home directory is shared between machines.
if [ -n "${CLAUDE_SUDO_HOST:-}" ]; then CS_HOST_STRICT=1; else CS_HOST_STRICT=0; fi

cs_vault_backend() {
  local b
  if [ -n "${CLAUDE_SUDO_BACKEND:-}" ]; then printf '%s' "$CLAUDE_SUDO_BACKEND"; return 0; fi
  if [ -f "$CS_CONFIG/backend" ]; then
    read -r b <"$CS_CONFIG/backend" 2>/dev/null || b=
    [ -n "$b" ] && { printf '%s' "$b"; return 0; }
  fi
  if command -v secret-tool >/dev/null 2>&1 && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}${DBUS_SESSION_BUS_PID:-}" ]; then
    printf 'libsecret'; return 0
  fi
  if [ "$(uname -s)" = Darwin ] && command -v security >/dev/null 2>&1; then printf 'keychain'; return 0; fi
  if command -v pass >/dev/null 2>&1 && [ -d "${PASSWORD_STORE_DIR:-$HOME/.password-store}" ]; then printf 'pass'; return 0; fi
  if command -v gpg >/dev/null 2>&1; then printf 'gpg'; return 0; fi
  printf 'none'
}

cs_vault_set_backend() { cs_init_dirs; printf '%s\n' "$1" >"$CS_CONFIG/backend"; chmod 600 "$CS_CONFIG/backend"; }

cs_vault_pass_path() { printf '%s/%s@%s' "$CS_SERVICE" "$CS_ACCOUNT" "$CS_HOSTNAME"; }
cs_vault_gpg_file() { printf '%s/vault.gpg' "$CS_STATE"; }
cs_vault_label() { printf '%s: sudo password for %s@%s' "$CS_SERVICE" "$CS_ACCOUNT" "$CS_HOSTNAME"; }

cs_vault_available() {
  case $(cs_vault_backend) in
    libsecret) command -v secret-tool >/dev/null 2>&1 ;;
    keychain)  command -v security >/dev/null 2>&1 ;;
    pass)      command -v pass >/dev/null 2>&1 ;;
    gpg)       command -v gpg >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# cs_vault_store — reads the secret from stdin.
cs_vault_store() {
  local pw; IFS= read -r pw || true
  [ -n "$pw" ] || { cs_warn "refusing to store an empty password"; return 1; }
  cs_init_dirs
  case $(cs_vault_backend) in
    libsecret)
      printf '%s' "$pw" | secret-tool store --label="$(cs_vault_label)" \
        service "$CS_SERVICE" account "$CS_ACCOUNT" host "$CS_HOSTNAME" ;;
    keychain)
      # -w takes the value as an argument; briefly visible in `ps` on macOS.
      security add-generic-password -U -a "$CS_ACCOUNT" -s "$CS_SERVICE" \
        -D "claude-sudo" -l "$(cs_vault_label)" -w "$pw" ;;
    pass)
      printf '%s\n' "$pw" | pass insert -m -f "$(cs_vault_pass_path)" >/dev/null ;;
    gpg)
      local f; f=$(cs_vault_gpg_file)
      printf '%s' "$pw" | gpg --quiet --yes --symmetric --cipher-algo AES256 --output "$f" \
        && chmod 600 "$f" ;;
    *) cs_warn "no usable secret store found (install libsecret's secret-tool, pass, or gnupg)"; return 1 ;;
  esac
}

# cs_vault_get — prints the secret on stdout, nothing else.
cs_vault_get() {
  local pw rc=0
  case $(cs_vault_backend) in
    libsecret)
      if [ "$CS_HOST_STRICT" = 1 ]; then
        pw=$(timeout "$CS_VAULT_TIMEOUT" secret-tool lookup \
          service "$CS_SERVICE" account "$CS_ACCOUNT" host "$CS_HOSTNAME" 2>/dev/null) || rc=$?
      else
        pw=$(timeout "$CS_VAULT_TIMEOUT" secret-tool lookup \
          service "$CS_SERVICE" account "$CS_ACCOUNT" 2>/dev/null) || rc=$?
      fi ;;
    keychain)
      pw=$(security find-generic-password -a "$CS_ACCOUNT" -s "$CS_SERVICE" -w 2>/dev/null) || rc=$? ;;
    pass)
      pw=$(timeout "$CS_VAULT_TIMEOUT" pass show "$(cs_vault_pass_path)" 2>/dev/null | head -n1) || rc=$? ;;
    gpg)
      pw=$(timeout "$CS_VAULT_TIMEOUT" gpg --quiet --batch --decrypt "$(cs_vault_gpg_file)" 2>/dev/null) || rc=$? ;;
    *) return 1 ;;
  esac
  [ "$rc" -eq 0 ] || return "$rc"
  # Trailing newlines are an artefact of the store, not part of the password.
  pw=${pw%$'\n'}; pw=${pw%$'\r'}
  [ -n "$pw" ] || return 1
  printf '%s' "$pw"
}

cs_vault_has() { cs_vault_get >/dev/null 2>&1; }

cs_vault_clear() {
  case $(cs_vault_backend) in
    libsecret)
      if [ "$CS_HOST_STRICT" = 1 ]; then
        secret-tool clear service "$CS_SERVICE" account "$CS_ACCOUNT" host "$CS_HOSTNAME" 2>/dev/null
      else
        # Forget means forget, including entries left by a previous hostname.
        secret-tool clear service "$CS_SERVICE" account "$CS_ACCOUNT" 2>/dev/null
      fi ;;
    keychain)  security delete-generic-password -a "$CS_ACCOUNT" -s "$CS_SERVICE" >/dev/null 2>&1 ;;
    pass)      pass rm -f "$(cs_vault_pass_path)" >/dev/null 2>&1 ;;
    gpg)       rm -f "$(cs_vault_gpg_file)" ;;
    *) return 1 ;;
  esac
}

# cs_verify_password — reads the candidate from stdin, checks it against sudo.
cs_verify_password() {
  local pw; IFS= read -r pw || true
  [ -n "$pw" ] || return 1
  printf '%s\n' "$pw" | sudo -k -S -p '' -v >/dev/null 2>&1
}
