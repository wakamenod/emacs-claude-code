---
title: Key binding reference
description: The keys ecc binds, from any buffer and inside a session buffer.
sidebar:
  order: 2
---

:::caution[Partial]
The two tables below are the ones from the README. The full `ecc-chat-mode`
map (around forty bindings) and the transcript-area map are still to be
written up. `C-c ?` opens the menu, and `C-h m` in a session buffer lists
everything.
:::

## Global map (`C-c c`)

Usable from any buffer, once `ecc-global-map` is bound to a prefix.

| Key | Command | Action |
|---|---|---|
| `a` | `ecc-answer-allow` | Allow oldest waiting request |
| `d` | `ecc-answer-deny` | Deny oldest waiting request |
| `1`–`4` | `ecc-answer-option-N` | Select response option N |
| `n` | `ecc-next-attention` | Switch to waiting session |
| `N` | `ecc-next-attention-in-project` | Switch to waiting session in current project |
| `D` | `ecc-dashboard` | Open sessions dashboard |
| `h` | `ecc-history-open` | Open past conversation |

## Session buffer

| Key | Action |
|---|---|
| `C-c C-c` | Send prompt |
| `S-RET` | Insert newline |
| `TAB` | Completion in prompt; fold/unfold in transcript |
| `C-c C-a` / `C-c C-d` | Allow / Deny tool permission |
| `C-c ?` | Open command menu |
