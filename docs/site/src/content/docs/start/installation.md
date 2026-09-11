---
title: Installation
description: What ecc needs, how to install it from the repository, and the configuration worth setting on the first day.
sidebar:
  order: 2
---

## What it needs

- **Emacs 29.1 or later.** `transient` is built in at that version, and ecc
  requires no external package at all.
- **The [Claude Code CLI](https://docs.claude.com/en/docs/claude-code)**, on
  your `PATH` or named by `ecc-executable`.

That is the whole list. These are optional, and ecc does without any of them:

| Package | What it adds |
|---|---|
| [ghostel](https://github.com/dakra/ghostel) | The terminal a session is handed to by `ecc-tui-open` |
| [posframe](https://github.com/tumashu/posframe) | Popups for `/btw` answers and the usage report |
| [nerd-icons](https://github.com/rainstormstudio/nerd-icons.el) | An icon per tool in the transcript |
| [markdown-mode](https://github.com/jrblevin/markdown-mode) | The major mode of the plan and review buffers |

## Installing

ecc is not on MELPA. Install it from the repository.

The repository is `emacs-claude-code` and the package is `ecc`, so any recipe
that guesses the package name from the repository name has to be told
otherwise.

### Emacs 30 and later

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest))
```

`:rev "<commit-sha>"` pins a commit instead of following the branch.

### Emacs 29

```
M-x package-vc-install RET https://github.com/wakamenod/emacs-claude-code RET
```

Then configure it with an ordinary `use-package` form, without `:vc`.

### straight.el

```elisp
(use-package ecc
  :straight (ecc :type git :host github :repo "wakamenod/emacs-claude-code"))
```

## The first configuration

`M-x ecc-start` is autoloaded, so ecc works with no configuration at all. The
one thing worth adding is the keymap:

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest)
  :bind-keymap ("C-c c" . ecc-global-map))
```

`ecc-global-map` answers a permission, jumps to the session that is waiting and
opens the dashboard — from any buffer, so a session that stops does not make
you go and find it first. Every key it holds is on the
[key binding reference](/emacs-claude-code/reference/key-bindings/).

## Turning on the MCP server

The loopback MCP server lets Claude ask Emacs for what only Emacs knows: the
references `xref` finds, the symbols `imenu` lists, the diagnostics `flymake`
holds. It is off until you turn it on, and evaluating Elisp needs a second
opt-in:

```elisp
(setq ecc-mcp-enabled t)
;; Only if you want Claude to be able to evaluate Elisp:
;; (setq ecc-mcp-enable-execute-code t)
```

## Checking it works

1. Open a file in a project.
2. `M-x ecc-start`.
3. Type something in the prompt region at the bottom and press `C-c C-c`.

If the CLI cannot be started, the session's log buffer — `C-c ?` then `L`, or
`M-x ecc-show-log` — holds the command line that was run and everything that
came back on the pipe.

Every other setting is in `M-x customize-group RET ecc` and on the
[configuration reference](/emacs-claude-code/reference/configuration/). `C-c ?`
in a session opens the menu, which reaches every command and shows its key.
