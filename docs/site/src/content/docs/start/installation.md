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

`M-x ecc-start` is autoloaded, so ecc works without configuration. This configuration binds the global keymap to a prefix and changes a few defaults:

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest)
  :bind-keymap ("C-c c" . ecc-global-map)
  :custom
  ;; Start sessions in the CLI's auto mode, which answers most requests itself.
  (ecc-permission-mode "auto")
  ;; Flash the transcript as well as writing to the echo area.
  (ecc-notify-level 'pulse)
  ;; Float usage reports and /btw answers over the frame (needs posframe).
  (ecc-usage-display 'posframe)
  (ecc-btw-display 'posframe)
  ;; Open a review in ediff instead of one diff-mode buffer.
  (ecc-review-style 'ediff)
  ;; Register the Emacs MCP server with every session.
  (ecc-mcp-enabled t)
  ;; Have the CLI suggest a next prompt after a turn.
  (ecc-prompt-suggestions-enabled t))
```

`ecc-global-map` answers requests, jumps to waiting sessions and opens the dashboard from any buffer. The site writes its keys with `C-c c`; see [Key bindings](/emacs-claude-code/reference/key-bindings/).

You can leave out any of these settings:

- Without `ecc-permission-mode`, a session starts in the CLI's default mode, which asks before Claude edits a file or runs a command. `S-TAB` changes the mode of a running session; see [Permission modes](/emacs-claude-code/features/permissions/#permission-modes).
- The `posframe` displays need the [posframe](https://github.com/tumashu/posframe) package and a graphical frame. Without them, the buffer opens in a window.
- The default `ecc-review-style` is `'diff`, one `diff-mode` buffer. `'ediff` shows the two sides of each file; see [Reviewing in ediff](/emacs-claude-code/features/review-ediff/).
- The next section covers `ecc-mcp-enabled`.
- The suggested prompt appears in the empty prompt region, and `C-c C-s` takes it; see [Suggestions](/emacs-claude-code/features/prompt/#suggestions).

If you use [corfu](https://github.com/minad/corfu), turn it on in session buffers to complete slash commands and `@` references in its popup:

```elisp
(add-hook 'ecc-chat-mode-hook #'corfu-mode)
```

## Enabling the MCP server

The built-in MCP server, on the loopback interface, lets Claude read `xref` references, `imenu` symbols and diagnostics from Emacs, [work in the review](/emacs-claude-code/features/review-claude/), and [hand work to a session in a worktree](/emacs-claude-code/features/spaces/#handing-work-to-a-session-in-a-worktree). It is off by default, and `(ecc-mcp-enabled t)` in the configuration above turns it on. Evaluating Elisp is a separate opt-in:

```elisp
;; Only if you want Claude to be able to evaluate Elisp:
;; (setq ecc-mcp-enable-execute-code t)
```

## Verifying the setup

Open a file of a project, run `M-x ecc-start`, type a message in the prompt region at the bottom and press `C-c C-c`. [A first session](/emacs-claude-code/start/first-session/) goes on from there.

If the CLI does not start, `M-x ecc-show-log` (`C-c ?` then `L`) shows the command ecc ran and what the CLI wrote back.

Every setting is in `M-x customize-group RET ecc` and on the [configuration page](/emacs-claude-code/reference/configuration/).
