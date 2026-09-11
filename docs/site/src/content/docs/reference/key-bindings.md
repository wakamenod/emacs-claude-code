---
title: Key bindings
description: Global keybindings accessible from any buffer, and configuration instructions.
sidebar:
  order: 1
---

`ecc-global-map` is a prefix keymap containing commands you frequently need while editing other files — allowing you to respond to permission prompts and switch to active sessions without navigating to their buffers first. Bind it to any convenient prefix; the README recommends `C-c c`:

```elisp
(use-package ecc
  :bind-keymap ("C-c c" . ecc-global-map))
```

Or, without `use-package`:

```elisp
(global-set-key (kbd "C-c c") ecc-global-map)
```

| Key | Action |
|---|---|
| `c` / `r` / `R` | Start session / resume / rename |
| `v` / `i` / `t` | Focus prompt / interrupt turn / hand over to terminal |
| `a` / `d` | Allow or deny oldest pending request |
| `1`–`4` | Select corresponding option for pending question |
| `n` / `N` | Jump to next pending request (globally or within current project) |
| `b` / `D` / `h` / `U` | Open dashboard / review diffs / view history / check usage |
| `?` | Open transient menu |

Keybindings correspond directly to commands in the [transient menu](/emacs-claude-code/features/menu/), ensuring consistent mnemonic shortcuts across Emacs. `?` opens the transient menu itself, providing quick access to all ecc commands from outside a session buffer.

For buffer-local bindings inside session buffers, see [Prompt and transcript](/emacs-claude-code/features/prompt/).
