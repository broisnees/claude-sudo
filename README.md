# claude-sudo

[![ci](https://github.com/broisnischal/claude-sudo/actions/workflows/ci.yml/badge.svg)](https://github.com/broisnischal/claude-sudo/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A **sudo mode** for Claude Code. While it is armed:

- Claude stops asking you to approve every tool call.
- `sudo` inside a tool call just works — no hanging password prompt, no password
  in the transcript, no `NOPASSWD` line in `/etc/sudoers`.
- Your password lives in the OS keyring. Claude never sees it; `sudo` gets it
  directly from an askpass helper.
- A policy still blocks the unrecoverable things, and every privileged command
  is written to an audit log.

Off by default. Armed per session, expires on its own, and never outlives the
session that armed it.

```
Shift+Tab  →  ⏵⏵ bypass permissions        sudo
> install ripgrep system-wide
  ● sudo pacman -S --noconfirm ripgrep      (no prompt, no password question)
```

```bash
curl -fsSL https://raw.githubusercontent.com/broisnischal/claude-sudo/main/install.sh | bash
```

## Turning it on

Pick whichever fits how you work — the installer asks once, and you can change
your mind at any time.

| | |
| --- | --- |
| `claude-sudo autoarm on` | **Every new session starts in sudo mode.** No keystroke, no command. |
| `Shift+Tab` → `⏵⏵ bypass permissions` | Arms that session; cycling out of the mode disarms it. |
| `/sudo on` | Arms the current session explicitly, until it expires or ends. |
| `csudo` | Starts Claude Code already armed. |

Auto-arm is off until you choose it, because it means every new session skips
permission prompts from its first message. When it is on, the session also tells
Claude that sudo authenticates from the keyring — so it stops asking you for a
password or offering to edit `/etc/sudoers`.

## Sudo mode as a Shift+Tab mode

Claude Code's permission modes are a compiled-in set —
`default`, `plan`, `acceptEdits`, `auto`, `bypassPermissions`, `dontAsk` — so a
seventh entry called "sudo" cannot be added to the cycle. Instead claude-sudo
*becomes* one of them.

Every hook payload carries `permission_mode`, so cycling into **bypass
permissions** arms sudo mode, and cycling out of it disarms again. Shift+Tab is
the switch, and the status line says `sudo` while it is live.

That entry is also the honest place for it: it is already the "don't ask me"
mode. Riding on it makes it *safer* than bare bypass, because the policy below
still applies — Claude Code consults hooks before the permission system in every
mode, and a hook `deny` is returned unchanged.

One wrinkle worth knowing: a hook `ask` is *not* honoured in a mode that never
prompts — it degrades to allow. So in bypass permissions the `ask` tier is
escalated to a refusal that tells you to Shift+Tab back to a mode that prompts.
Set `ask-in-bypass` to `allow` if you would rather have the old behaviour.

```bash
claude-sudo modes show           # which modes arm sudo mode
claude-sudo modes set dontAsk    # use a different entry
claude-sudo modes off            # no coupling; arm only with /sudo on
```

## Why plain sudo hangs inside Claude Code

A Bash tool call runs as a child of `claude`. It has no terminal of its own, but
it *does* inherit the controlling terminal, so `sudo` decides it can prompt —
and writes `[sudo] password for you:` to a terminal Claude cannot read and you
cannot see. The command sits there until it times out.

claude-sudo fixes that the way sudo intends: `sudo -A`, with `SUDO_ASKPASS`
pointing at a helper that answers from the keyring.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/broisnischal/claude-sudo/main/install.sh | bash
```

Needs `bash` 4+, `jq`, `sudo`, and one secret store: **libsecret**
(`secret-tool`, i.e. gnome-keyring or KWallet), the **macOS keychain**, **pass**,
or **gnupg** as a fallback.

The one-liner clones into `~/.local/share/claude-sudo` and keeps it a git
checkout, so `claude-sudo update` pulls later versions. To work from your own
clone instead:

```bash
git clone https://github.com/broisnischal/claude-sudo ~/src/claude-sudo
cd ~/src/claude-sudo && ./install.sh --in-place
```

It links `claude-sudo` and `csudo` into `~/.local/bin`, wires three hooks into
`~/.claude/settings.json` (backing it up first, keeping the last five backups),
installs the `/sudo` command and the `sudo` status line badge, asks for your sudo
password once — **in your own terminal**, never inside a Claude session — and
asks whether to arm every session automatically.

The status line is a wrapper: whatever renderer you already had is recorded and
runs inside it, so your existing status line keeps working untouched.
`claude-sudo statusline uninstall` puts the original back.

Want to store the password later? `./install.sh --no-password`, then
`claude-sudo passwd`. Any install prefix works — nothing depends on the
directory being named `claude-sudo`.

As a Claude Code plugin instead:

```
/plugin marketplace add broisnischal/claude-sudo
/plugin install claude-sudo
claude-sudo setup      # still needed once, for the password and the vault
```

## Commands

```bash
claude-sudo status         # armed? auto-arm? backend? wiring? all of it
claude-sudo doctor         # full check, makes sudo really authenticate once
claude-sudo audit -f       # follow every privileged command as it happens
claude-sudo autoarm on     # arm every new session (off | status)
claude-sudo policy         # the guardrails currently in force
claude-sudo modes          # which Shift+Tab modes arm sudo mode
claude-sudo passwd         # replace the stored password
claude-sudo forget         # delete it
claude-sudo update         # pull the latest version
claude-sudo launch --ttl 60
```

## How it works

Three moving parts, all of which fail closed.

**1. The gate** — a `PreToolUse` hook. Costs about a millisecond unless
something could be armed: it decides from the raw payload, before parsing any
JSON. It arms or disarms from `permission_mode`, returns
`permissionDecision: "allow"` (the "stop asking me" half) and, for commands that
use `sudo`, rewrites the command with `updatedInput` to put the shim first on
`PATH` and set `SUDO_ASKPASS`. The rewrite is what makes arming a *running*
session work: its environment cannot be changed from outside, but its tool input
can. A session armed by hand is left alone when you cycle modes; one armed by
the mode goes away with it.

**2. The shim** — a `sudo` in a directory that is only ever first on `PATH`
inside an armed session. It adds `-A` so sudo authenticates through the askpass
helper, and `-k` so every privileged command re-authenticates and therefore
lands in the audit log. It parses only sudo's own options, so `sudo grep -n foo`
is not mistaken for `sudo -n`. If you passed `-A`, `-S` or `-n` yourself, it
steps aside.

**3. The askpass helper** — the only thing that ever touches the password. It
refuses unless sudo mode is armed for the current session, refuses unless its
parent process is `sudo` or `sudoedit`, and writes both outcomes to the audit
log. On failure it exits non-zero, so sudo fails in a second instead of hanging.

`claude-sudo launch` sets `PATH` and `SUDO_ASKPASS` in Claude's own environment,
so nested scripts that call `sudo` work too. Mid-session arming only rewrites
commands Claude runs directly.

## Security model

What it protects:

- The password is stored by the OS keyring (encrypted at rest, unlocked by your
  login), never in plaintext on disk, never in argv, never in an exported
  environment variable, never in the transcript sent to the model.
- It is verified against `sudo` before being stored, so a typo cannot be saved.
- The helper serves it only to `sudo`, only while a session is armed.
- `/etc/sudoers` is untouched. Nothing becomes passwordless outside Claude Code.
- Sudo mode expires (default 480 minutes, `CLAUDE_SUDO_TTL`) and the `SessionEnd`
  hook disarms it and runs `sudo -k` so no cached credential lingers.
- Every privileged command, denial and password hand-off is in
  `~/.local/state/claude-sudo/audit.log` (mode 0600).

What it does not protect against, stated plainly:

- **Any process running as you can read your keyring.** That is true of every
  keyring-backed tool; claude-sudo does not make it worse, but it does mean the
  boundary here is your user account, not your password.
- **While a session is armed, Claude runs privileged commands without asking
  you.** That is the feature. The policy below is the only thing between an
  armed session and your system — but it is real: hook denials are returned
  unchanged in every permission mode, including bypass.
- Arming is one keystroke away. Shift+Tab is convenient by design, which also
  means it is easy to land in by accident — the `sudo` badge exists so that
  is always visible, and `claude-sudo modes off` removes the coupling entirely.
- **Auto-arm removes the last speed bump on purpose.** With it on, a session is
  privileged before you have typed anything, so anything that can reach a session
  inherits that. Keep it off if you paste untrusted content into Claude, or keep
  the TTL short. `claude-sudo status` always tells you which mode you are in.
- Nothing in claude-sudo ever prints the stored password, and neither should you:
  `secret-tool search` dumps secrets to the terminal. Use `claude-sudo status`,
  which only reports whether one is readable.
- A prompt injection that reaches an armed session inherits that power. Arm
  sessions you are watching; keep the TTL short if you are pasting untrusted
  content.

If `sudo -n -v` already succeeds for you (a `NOPASSWD` rule), claude-sudo tells
you so — the stored password is then only a fallback.

## Policy

The guardrails stay on **even in sudo mode**. `deny` is refused outright; `ask`
falls back to a normal interactive prompt so you decide.

Denied: `rm -rf /` and recursive deletes of system or home directories, `mkfs`,
`wipefs`/`shred`/`blkdiscard`, `dd`/redirects onto block devices, fork bombs,
`shutdown`/`reboot`, `userdel`, `chmod 777 /`, `curl … | sudo sh`, interactive
root shells (`sudo -i`, `sudo su` — claude-sudo cannot audit what happens inside
one).

Asks: `/etc/sudoers` and other credential files, `passwd`/`useradd`/`usermod`,
SSH keys, firewall rules, `systemctl mask|disable|stop`, package *removal*,
partition and LVM tools, `crontab`.

`claude-sudo policy` prints the active set. To change it, copy
`config/policy.default.conf` to `~/.config/claude-sudo/policy.conf` — your file
replaces the defaults entirely. Format is TAB-separated
`action<TAB>extended-regex<TAB>reason`, first match wins.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLAUDE_SUDO_TTL` | `480` | Arming window in minutes; `0` means until the session ends |
| `CLAUDE_SUDO_AUTOARM` | `off` | `on` arms every new session (`~/.config/claude-sudo/autoarm`, or `claude-sudo autoarm on`) |
| `CLAUDE_SUDO_ARM_MODES` | `bypassPermissions` | Permission modes that arm sudo mode (`~/.config/claude-sudo/arm-modes`, one per line, `none` to disable) |
| `CLAUDE_SUDO_ASK_IN_BYPASS` | `deny` | What a policy `ask` becomes in a mode that never prompts (`~/.config/claude-sudo/ask-in-bypass`) |
| `CLAUDE_SUDO_BACKEND` | auto | `libsecret`, `keychain`, `pass`, `gpg` (also `~/.config/claude-sudo/backend`) |
| `CLAUDE_SUDO_HOST` | unset | Set it to require an exact host match on the keyring entry — for one home directory shared between machines. Left unset, the hostname is recorded but not required, so a machine that renames itself does not orphan your password |
| `CLAUDE_SUDO_KEEP_CACHE` | `0` | `1` uses sudo's credential cache instead of re-authenticating each time |
| `CLAUDE_SUDO_KILL_TIMESTAMP` | `0` | `1` runs `sudo -K` instead of `sudo -k` at session end |
| `CLAUDE_SUDO_STATE` | `~/.local/state/claude-sudo` | Sessions and audit log |

## Uninstall

```bash
~/src/claude-sudo/uninstall.sh            # unwire, unlink, remove the install
~/src/claude-sudo/uninstall.sh --purge    # also delete the password and audit log
```

## Layout

```
bin/claude-sudo               CLI: setup, autoarm, on/off/status, audit, doctor
bin/claude-sudo-statusline    the sudo badge, wrapping your own renderer
hooks/gate.sh                 PreToolUse: mode coupling, policy, askpass rewrite
hooks/session-start.sh        SessionStart: auto-arm, and tell Claude about it
hooks/session-end.sh          SessionEnd: disarm, drop cached credentials
libexec/claude-sudo-askpass   the only code that reads the password
libexec/shim/sudo             adds -A (and -k) to sudo
lib/{common,vault,policy}.sh  state/audit, keyring backends, guardrails
config/policy.default.conf    the shipped guardrails
commands/sudo.md              the /sudo slash command
tests/smoke.sh                126 checks, no real password or sudo needed
```

Run the tests with `bash tests/smoke.sh` — isolated temp state, a dummy keyring
entry and a fake `sudo`; it never touches your real credentials or settings.
