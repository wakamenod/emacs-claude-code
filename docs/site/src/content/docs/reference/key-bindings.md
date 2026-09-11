---
title: Key bindings
description: The keys that work from any buffer, and how to bind them.
sidebar:
  order: 1
---

`ecc-global-map` is a prefix keymap holding the handful of keys worth having
everywhere — a session that stops for a permission does not make you go and
find it first. Bind it where you like; the README suggests `C-c c`:

```elisp
(use-package ecc
  :bind-keymap ("C-c c" . ecc-global-map))
```

Or, without `use-package`:

```elisp
(global-set-key (kbd "C-c c") ecc-global-map)
```

| Key | What it does |
|---|---|
| `c` / `r` / `R` | Start a session, resume one, rename one |
| `v` / `i` / `t` | Go to its prompt, interrupt the turn, hand it to the terminal |
| `a` / `d` | Allow or deny the oldest request waiting |
| `1`–`4` | Answer the oldest question with that option |
| `n` / `N` | Next request waiting, anywhere or in this project |
| `b` / `D` / `h` / `U` | Dashboard, diff, a recorded conversation, usage |
| `?` | Open the menu |

Every letter means in the [menu](/emacs-claude-code/features/menu/) what it
means here, so one key carries one meaning wherever it is pressed. `?` is the
exception, being what opens that menu — and the only way to reach it from a
buffer that is not a session.

The keys inside a session buffer are on
[Prompt and transcript](/emacs-claude-code/features/prompt/); the menu reaches
every command there is.
