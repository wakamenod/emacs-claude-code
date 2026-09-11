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

### straight.el and Elpaca

```elisp
;; straight.el
(use-package ecc
  :straight (ecc :type git :host github :repo "wakamenod/emacs-claude-code"))

;; Elpaca
(use-package ecc
  :ensure (ecc :host github :repo "wakamenod/emacs-claude-code"))
```

### A manual clone

```sh
git clone https://github.com/wakamenod/emacs-claude-code \
  ~/.emacs.d/site-lisp/emacs-claude-code
```

```elisp
(add-to-list 'load-path "~/.emacs.d/site-lisp/emacs-claude-code")
(require 'ecc)
```

## The first configuration

`M-x ecc-start` is autoloaded, so ecc works with no configuration at all. Two
things are worth setting on the first day anyway.

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest)
  ;; `ecc-global-map' is a prefix keymap: answering a permission, jumping to
  ;; the session that is waiting, opening the dashboard -- from any buffer.
  ;; `:bind-keymap' defers loading ecc until the prefix is first pressed.
  :bind-keymap ("C-c c" . ecc-global-map)
  :bind ("C-c C-v" . ecc-start)
  :config
  (setq ecc-chat-text-width 100)   ; transcript width, in columns
  (setq ecc-notify-level 'pulse)   ; nil, `message', `pulse' or `desktop'
  (setq ecc-permission-mode nil)   ; nil leaves the CLI's own default alone

  ;; t makes RET send, as the terminal client does.
  ;; nil (the default) makes RET a newline and C-c C-c the send.
  (setq ecc-chat-return-sends nil))
```

The keymap is the half that matters. A session stops the moment it needs a word
from you, and `ecc-global-map` is what lets you answer without first going to
find which session it was.

:::note[The model is not a setting]
There is no variable naming a model, on purpose. A new session takes the model
from your Claude Code settings, and a resumed one takes the model its recording
ends on. Passing `--model` would override both for good, undoing every `/model`
made since. `ecc-set-model` changes the model of a running session instead.
Cost is likewise a matter for the Claude Code settings, not for ecc.
:::

## Turning on the MCP server

The loopback MCP server lets Claude ask Emacs for what only Emacs knows: the
references `xref` finds, the symbols `imenu` lists, the diagnostics `flymake`
holds. It is off until you say otherwise, and evaluating Elisp needs a second
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
[configuration reference](/emacs-claude-code/reference/configuration/).
Next: [your first session](/emacs-claude-code/start/first-session/).
