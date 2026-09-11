---
title: Overview
description: What ecc does, in short.
sidebar:
  order: 1
---

ecc runs `claude` headless, talks to it over pipes in its stream-json protocol,
and draws the conversation into an ordinary Emacs buffer. There is no terminal
emulator in it.

A session buffer holds the transcript at the top and, under a divider, the
prompt you type in. The transcript is read-only text, so `isearch`, `occur`,
narrowing and `M-w` work on it as they do anywhere else. Because nothing is
typed into it, single letters act on it — `n`, `p`, `TAB`, `a`, `d`. In the
prompt region every letter stays a letter.

A few things worth knowing before you start:

- **Permission prompts default to deny.** Answer with `C-c C-a` / `C-c C-d`
  in the session, or from any buffer at all through `ecc-global-map`.
- **Emacs 29.1 and the `claude` CLI are the only requirements.** No external
  package is needed.
- **`ecc-tui-open` hands a session to the real terminal client** when you want
  the CLI's own interface, and `ecc-tui-return` takes it back.

[Install it](/emacs-claude-code/start/installation/), and the
[menu](/emacs-claude-code/features/menu/) has every command there is.
