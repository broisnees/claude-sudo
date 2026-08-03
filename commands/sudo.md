---
description: Toggle claude-sudo mode for this session (on | off | status)
argument-hint: "[on|off|status]"
allowed-tools: Bash(__CLAUDE_SUDO_BIN__:*)
---

!`__CLAUDE_SUDO_BIN__ toggle $ARGUMENTS`

That is the current state of **claude-sudo mode** for this session.

When it is ON: permission prompts are skipped, and any `sudo` command you run
authenticates with the password stored in the OS keyring — so do not ask the
user to type it, and do not use `sudo -S`, `echo password |`, or NOPASSWD edits.
Commands the claude-sudo policy considers unrecoverable are still blocked, and a
few sensitive ones still ask; if you hit one, report the reason instead of
working around it.

When it is OFF: behave normally. Tell the user they can run `/sudo on`, or
Shift+Tab into "bypass permissions", which arms sudo mode on its own.

Sudo mode armed this way stays on until it expires or the session ends; arming it
by cycling into bypass permissions instead ends when they cycle out.

Say nothing more than one line acknowledging the state.
