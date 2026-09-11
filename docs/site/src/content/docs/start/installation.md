---
title: Installation
description: System requirements, installation instructions, and recommended initial configuration.
sidebar:
  order: 2
---

## Requirements

- **Emacs 29.1 or later.** `transient` is built into Emacs 29.1+, and ecc requires no other external packages.
- **The [Claude Code CLI](https://docs.claude.com/en/docs/claude-code)**, available on your `PATH` or configured via `ecc-executable`.

These are the only hard requirements. The following packages are optional:

| Package | Feature |
|---|---|
| [ghostel](https://github.com/dakra/ghostel) | Terminal emulator for sessions handed over by `ecc-tui-open` |
| [posframe](https://github.com/tumashu/posframe) | Floating popups for `/btw` side-queries and usage reports |
| [nerd-icons](https://github.com/rainstormstudio/nerd-icons.el) | Icons for tool calls in the transcript |
| [markdown-mode](https://github.com/jrblevin/markdown-mode) | Major mode for plan and review buffers |

## Installation

ecc is not currently on MELPA; install it directly from the Git repository.

Note that the repository name is `emacs-claude-code` while the package name is `ecc`. Package managers that infer the package name from the repository URL must be configured explicitly.

### Emacs 30 and later

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest))
```

Use `:rev "<commit-sha>"` to pin a specific commit instead of tracking the latest changes.

### Emacs 29

```
M-x package-vc-install RET https://github.com/wakamenod/emacs-claude-code RET
```

Then configure it with a standard `use-package` declaration (without `:vc`).

### straight.el

```elisp
(use-package ecc
  :straight (ecc :type git :host github :repo "wakamenod/emacs-claude-code"))
```

## Initial configuration

Because `M-x ecc-start` is autoloaded, ecc works without any extra configuration. The most useful initial addition is binding the global keymap:

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest)
  :bind-keymap ("C-c c" . ecc-global-map))
```

`ecc-global-map` lets you respond to permission prompts, jump to waiting sessions, and open the dashboard from any buffer — so you never have to search for a paused session. See the [key binding reference](/emacs-claude-code/reference/key-bindings/) for all available bindings.

## Enabling the MCP server

The built-in loopback MCP server allows Claude to query Emacs for editor-specific context: `xref` references, `imenu` symbols, and `flymake` diagnostics. It is disabled by default, and evaluating arbitrary Elisp requires an additional explicit opt-in:

```elisp
(setq ecc-mcp-enabled t)
;; Only if you want Claude to be able to evaluate Elisp:
;; (setq ecc-mcp-enable-execute-code t)
```

## Verifying the setup

1. Open any file in a project.
2. Run `M-x ecc-start`.
3. Type a message in the bottom prompt area and press `C-c C-c`.

If the CLI fails to start, check the session log buffer (`C-c ?` then `L`, or `M-x ecc-show-log`), which records the exact command executed and the raw output received from the CLI process.

For all other options, run `M-x customize-group RET ecc` or consult the [configuration reference](/emacs-claude-code/reference/configuration/). Pressing `C-c ?` inside any session opens the transient menu, showing all commands and their keybindings.
