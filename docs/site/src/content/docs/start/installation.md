---
title: Installation
description: System requirements, installation instructions, and recommended initial configuration.
sidebar:
  order: 1
---

## Requirements

- **Emacs 29.1 or later.** ecc needs no other package; `transient` is part of Emacs.
- **The [Claude Code CLI](https://docs.claude.com/en/docs/claude-code)**, on your `PATH` or set in `ecc-executable`.

These packages are optional:

| Package | Feature |
|---|---|
| [ghostel](https://github.com/dakra/ghostel) | Terminal emulator for sessions handed over by `ecc-tui-open` |
| [posframe](https://github.com/tumashu/posframe) | Floating popups for `/btw` side-queries and usage reports |
| [nerd-icons](https://github.com/rainstormstudio/nerd-icons.el) | Icons for tool calls in the transcript |
| [markdown-mode](https://github.com/jrblevin/markdown-mode) | Major mode for plan and review buffers |

## Installation

ecc is not on MELPA; install it from the Git repository. The repository is `emacs-claude-code` and the package is `ecc`, so a package manager that takes the name from the URL needs to be told.

### Emacs 30 and later

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest))
```

`:rev "<commit-sha>"` pins a commit.

### Emacs 29

```
M-x package-vc-install RET https://github.com/wakamenod/emacs-claude-code RET
```

Then configure it with `use-package` without `:vc`.

### straight.el

```elisp
(use-package ecc
  :straight (ecc :type git :host github :repo "wakamenod/emacs-claude-code"))
```

## Initial configuration

`M-x ecc-start` is autoloaded, so ecc works without configuration. Bind the global keymap to a prefix:

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest)
  :bind-keymap ("C-c c" . ecc-global-map))
```

`ecc-global-map` answers requests, jumps to waiting sessions and opens the dashboard from any buffer. The site writes its keys with `C-c c`; see [Key bindings](/emacs-claude-code/reference/key-bindings/).

## Enabling the MCP server

The built-in MCP server, on the loopback interface, lets Claude read `xref` references, `imenu` symbols and diagnostics from Emacs, [work in the review](/emacs-claude-code/features/review-claude/), and [hand work to a session in a worktree](/emacs-claude-code/features/spaces/#handing-work-to-a-session-in-a-worktree). It is off by default, and evaluating Elisp is a separate opt-in:

```elisp
(setq ecc-mcp-enabled t)
;; Only if you want Claude to be able to evaluate Elisp:
;; (setq ecc-mcp-enable-execute-code t)
```

## Verifying the setup

Open a file of a project, run `M-x ecc-start`, type a message in the prompt region at the bottom and press `C-c C-c`. [A first session](/emacs-claude-code/start/first-session/) goes on from there.

If the CLI does not start, `M-x ecc-show-log` (`C-c ?` then `L`) shows the command ecc ran and what the CLI wrote back.

Every setting is in `M-x customize-group RET ecc` and on the [configuration page](/emacs-claude-code/reference/configuration/).
