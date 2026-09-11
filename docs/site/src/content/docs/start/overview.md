---
title: Overview
description: A brief overview of ecc.
sidebar:
  order: 1
---

ecc runs `claude` headless, communicates over pipes using its stream-json protocol,
and renders the conversation in an ordinary Emacs buffer — no terminal emulator required.

A session buffer displays the transcript at the top and the prompt input area below
a divider. The transcript is read-only text, so `isearch`, `occur`, narrowing,
and `M-w` work as they do anywhere in Emacs. Because the transcript is not an input
area, single keys act as immediate commands — `n`, `p`, `TAB`, `a`, `d`. In the
prompt area, normal character typing is preserved.

A few things worth knowing before you start:

- **Permission prompts default to deny.** Answer them with `C-c C-a` (allow) or `C-c C-d` (deny)
  within the session, or from any buffer via `ecc-global-map`.
- **Emacs 29.1 and the `claude` CLI are the only requirements.** No external
  packages are required.
- **`ecc-tui-open` hands off a session to the terminal client** when you want
  the CLI's native interface, and `ecc-tui-return` brings it back.

See the [installation guide](/emacs-claude-code/start/installation/) to get started,
or explore the [transient menu](/emacs-claude-code/features/menu/) to see all available commands.
