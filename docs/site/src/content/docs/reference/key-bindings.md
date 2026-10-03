---
title: Key bindings
description: The global keymap, bound to a prefix of your choice, for the commands you need from any buffer.
sidebar:
  order: 1
---

`ecc-global-map` holds the commands you need while editing other files: answering requests, going to a session, opening a review. Bind it to a prefix; the [installation page](/emacs-claude-code/start/installation/#initial-configuration) uses `C-c c`:

```elisp
(use-package ecc
  :bind-keymap ("C-c c" . ecc-global-map))
```

Or, without `use-package`:

```elisp
(global-set-key (kbd "C-c c") 'ecc-global-map)
```

| Key | Action |
|---|---|
| `c` / `r` / `R` | Start a session / resume one (`C-u r` forks it) / rename |
| `v` / `i` / `t` | Go to the prompt / interrupt the turn / hand over to the terminal |
| `a` / `d` | Allow or deny the oldest waiting request |
| `1`–`4` | Answer a waiting question with that option |
| `n` / `N` | Jump to the next waiting request (anywhere / in this project) |
| `B` / `D` / `h` / `U` | Dashboard / review menu / read a recording / usage |
| `j` / `b` / `z` / `V` | [Spaces](/emacs-claude-code/features/spaces/): go to one / the sidebar / zoom this window / reset this Space's windows |
| `/` | Search past conversations |
| `?` | Open the [menu](/emacs-claude-code/reference/menu/), which has every command |

The keys mean the same in the menu. The worktree commands are under `?` then `W`.

The keys inside a session buffer are on [Prompt and transcript](/emacs-claude-code/features/prompt/).
