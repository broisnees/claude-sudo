# Changelog

## 1.0.0

First release.

- **Auto-arm, if you want it.** `claude-sudo autoarm on` arms sudo mode from the
  first message of every session, and the session tells Claude that sudo
  authenticates from the keyring so it stops asking for a password. Off until you
  choose it; the installer asks once.
- **Sudo mode as a Shift+Tab mode.** Claude Code's permission modes are a
  compiled set, so instead of adding a seventh entry, claude-sudo rides on
  `bypassPermissions`: cycling into it arms sudo mode, cycling out disarms it.
  A session armed by hand with `/sudo on` is not affected by mode changes.
- **`sudo` stops hanging inside tool calls.** A `PATH` shim adds `-A` and an
  askpass helper answers from the OS keyring, so no password prompt is written
  to a terminal Claude cannot see.
- **The password never leaves the keyring in the clear.** Verified against sudo
  before it is stored; served only to `sudo`, only while armed; never on disk in
  plaintext, in argv, in an environment variable, or in the transcript.
- **A policy that holds even in sudo mode.** 13 refuse rules and 9 ask rules.
  Hook denials are honoured in every permission mode; because an `ask` would be
  silently allowed in a mode that never prompts, it is escalated to a refusal
  there instead.
- **Audit log** of every privileged command, refusal and password hand-off.
- **A `sudo` status line badge** that wraps whatever renderer you already had.
  Relabel it with `CLAUDE_SUDO_BADGE`; `CLAUDE_SUDO_BADGE_TIME=1` appends the
  minutes left.
- `claude-sudo doctor` proves the whole chain by making sudo authenticate once.
- One-line install that bootstraps itself, plus `claude-sudo update`.
- The keyring lookup does not require the hostname to match. A machine that
  renames itself (randomised or DHCP-assigned hostnames do) would otherwise
  orphan a stored password and report it as "no password stored".
- 126 smoke tests that need neither your real password nor real sudo.
