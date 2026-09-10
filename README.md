**English** | [日本語](README.ja.md)

---

# ecc

An Emacs client for the Claude Code CLI. The conversation lives in an ordinary Emacs buffer.

![Emacs 29.1+](https://img.shields.io/badge/Emacs-29.1%2B-7F5AB6)
![Claude Code CLI](https://img.shields.io/badge/Claude%20Code-CLI-D97757)

![A session buffer: the transcript above, the prompt below](docs/images/session.png)

**Documentation:** <https://wakamenod.github.io/emacs-claude-code/> *(in progress)*

## What ecc is

ecc runs `claude` headless, reads its stream-json protocol over a pipe, and draws the
conversation into one Emacs buffer: a read-only transcript above, an editable prompt
below, a rule between them. It is ordinary buffer text. You can search it, `occur` it,
narrow it, yank from it and export it to Markdown, and the faces are put on at insertion
time, so `customize` reaches them.

That has a price, and it is worth saying plainly. ecc does not reproduce the CLI's
terminal interface; when you want the real thing, `ecc-tui-open` hands the live session
over to it and takes it back afterwards. It speaks the Claude Code protocol, so it is a
Claude Code client and only that. Its Markdown, its tables and its diffs are ecc's own
reading of them rather than full implementations. It needs Emacs 29.1 and the `claude`
CLI. That is the whole list.

Speaking the CLI's own protocol means what you see is what the CLI said. Permission
requests are its real requests, the usage figures come from its `get_usage`, and past
conversations are read back out of its recordings. Nothing here is a guess.

The work around a session is first-class. Review every change a session made as one
`diff-mode` buffer, attach comments to the hunks and send them all as a single prompt.
Read a proposed edit before it is applied, and edit the proposal before allowing it. Work
through a plan in a buffer you can write in. Answer a waiting request from whatever buffer
you happen to be in. Run several sessions at once and keep them straight from a dashboard.
Deny is the default answer everywhere, the Emacs MCP server stays off until you turn it
on, and the tool that evaluates Elisp needs a second decision of its own. It is a Claude
Code client for people who would rather stay in Emacs.

## Requirements

- **Emacs 29.1 or later.** `transient` ships with Emacs; there is nothing else to install.
- **The [Claude Code CLI](https://docs.claude.com/en/docs/claude-code)** on `PATH`, or
  named by `ecc-executable`.

Four packages are used when they are there and skipped when they are not:
[ghostel](https://github.com/dakra/ghostel) for handing a session to the terminal,
[posframe](https://github.com/tumashu/posframe) for the `/btw` and usage popups,
[nerd-icons](https://github.com/rainstormstudio/nerd-icons.el) for the tool icons, and
[markdown-mode](https://github.com/jrblevin/markdown-mode) as the parent mode of the plan
and review buffers. Without them ecc falls back rather than fails.

## Installation

ecc is not on MELPA. Install it from this repository.

**Emacs 30 and later**, with `use-package` and `:vc`:

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest))
```

The `:vc` keyword arrived in Emacs 30. At 0.1.0 you may prefer to pin a commit with
`:rev "<sha>"` rather than track the branch.

**Emacs 29**, with `package-vc-install`:

```
M-x package-vc-install RET https://github.com/wakamenod/emacs-claude-code RET
```

then a plain `use-package` form with no `:vc`.

<details>
<summary>straight.el, Elpaca, or a manual clone</summary>

The repository is named `emacs-claude-code` and the package is named `ecc`, so the recipe
has to say `ecc` explicitly — the name cannot be taken from the repository.

```elisp
;; straight.el
(use-package ecc
  :straight (ecc :type git :host github :repo "wakamenod/emacs-claude-code"))

;; Elpaca
(use-package ecc
  :ensure (ecc :host github :repo "wakamenod/emacs-claude-code"))
```

Or by hand:

```sh
git clone https://github.com/wakamenod/emacs-claude-code ~/.emacs.d/site-lisp/emacs-claude-code
```

```elisp
(add-to-list 'load-path "~/.emacs.d/site-lisp/emacs-claude-code")
(require 'ecc)
```

`(require 'ecc)` loads every file. The commands are autoloaded, so `M-x ecc-start` works
without it — but `ecc-global-map` is a variable and has to be loaded before it can be
bound, which is why the configuration below loads ecc rather than deferring it.
</details>

## Configuration

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest)
  :demand t
  :bind (("C-c C-v" . ecc-start))
  :config
  ;; `ecc-global-map' is a keymap held in a variable, not a command, so
  ;; `:bind' cannot reach it and it has to exist before it is bound --
  ;; which is why this form asks for `:demand t' above.  It answers a
  ;; waiting request from any buffer; see the key bindings below.
  (keymap-global-set "C-c c" ecc-global-map)

  ;; " ⚠ecc:N " in the mode line, counting the requests waiting for you.
  (ecc-pending-indicator-mode 1)

  (setq ecc-chat-text-width 100)      ; columns the transcript is drawn across
  (setq ecc-notify-level 'pulse)      ; nil, `message', `pulse' or `desktop'
  (setq ecc-permission-mode nil)      ; nil leaves the CLI's own default

  ;; RET inserts a newline and C-c C-c sends.  Set this to make RET send,
  ;; the way the terminal client does.
  (setq ecc-chat-return-sends nil)

  ;; Let Claude ask this Emacs what only Emacs knows -- xref, imenu,
  ;; tree-sitter, project and diagnostics -- over a loopback MCP server
  ;; registered with each session.  Off by default.
  ;; (setq ecc-mcp-enabled t)
  ;; Evaluating arbitrary Elisp in your Emacs is a separate decision.
  ;; (setq ecc-mcp-enable-execute-code t)
  )
```

The rest — thirty `defcustom`s in all — are in `M-x customize-group RET ecc`. Anything
that is not a `defcustom` is a plain `defvar` that `setq` still reaches; see the
[configuration reference](https://wakamenod.github.io/emacs-claude-code/).

## Your first session

1. `M-x ecc-start` starts a session for the project of the current buffer.
2. Type in the prompt region, below the rule.
3. `C-c C-c` sends it. `RET` inserts a newline.
4. When Claude asks to use a tool, `C-c C-a` allows it and `C-c C-d` denies it. **Deny is
   the default**: nothing runs because you looked away.
5. `C-c ?` opens the menu with everything else on it.

## Key bindings

`ecc-global-map`, bound above to `C-c c`, works from any buffer:

| Key | Command | |
|---|---|---|
| `a` | `ecc-answer-allow` | allow the oldest waiting request |
| `d` | `ecc-answer-deny` | deny it |
| `1`–`4` | `ecc-answer-option-N` | answer a question with option N |
| `n` | `ecc-next-attention` | go to the session that is waiting |
| `N` | `ecc-next-attention-in-project` | the same, within this project |
| `D` | `ecc-dashboard` | list the sessions |
| `h` | `ecc-history-open` | open a past conversation |

In a session buffer:

| Key | |
|---|---|
| `C-c C-c` | send the prompt |
| `S-RET` | newline |
| `TAB` | complete in the prompt; fold and unfold in the transcript |
| `C-c C-a` / `C-c C-d` | allow / deny |
| `C-c ?` | the menu |

The other forty or so are in the
[key binding reference](https://wakamenod.github.io/emacs-claude-code/).

## Acknowledgements

ecc began by reading four projects, and owes each of them something:

- **[claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el)** — for showing
  what a full IDE-side integration with the CLI looks like.
- **[claude-code.el](https://github.com/stevemolitor/claude-code.el)** — for the
  conveniences that make a session feel like part of Emacs rather than a guest in it.
- **[eca-emacs](https://github.com/editor-code-assistant/eca-emacs)** — for rendering the
  conversation as a real Emacs buffer, and for the shape of an inline overlay chat.
- **[emacs-gravity](https://github.com/gdanov/emacs-gravity)** — for treating the
  conversation as a navigable structure, and for plan review and permission patterns.

Thank you to their authors.

## Comparison

Five defensible designs. This table records what each one chose, not who won. It is
accurate as far as I know in September 2026 and may already be out of date — if a row
about your project is wrong, please open an issue and I will fix it.

| Project | How it talks to Claude | Display | Beyond Emacs and the CLI | Emacs | Availability |
|---|---|---|---|---|---|
| [claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el) | the CLI's TUI in a terminal buffer, plus a WebSocket MCP server inside Emacs | terminal emulator | `websocket`, `transient`, `web-server` | 28.1 | MELPA |
| [claude-code.el](https://github.com/stevemolitor/claude-code.el) | the CLI's TUI in a terminal buffer | terminal emulator | `transient`, `inheritenv` | 30 | MELPA |
| [eca-emacs](https://github.com/editor-code-assistant/eca-emacs) | JSON-RPC to a separate `eca` server | Markdown chat buffer and inline overlays | `dash`, `s`, `f`, `markdown-mode`, `compat`, the `eca` binary | 28.1 | MELPA |
| [emacs-gravity](https://github.com/gdanov/emacs-gravity) | Claude Code plugin hooks, a Node shim, a socket server | magit-section turn tree | `magit-section`, `transient`, Node.js | 27.1 | GitHub |
| **ecc** | `claude` headless, stream-json over a pipe | one Emacs buffer: transcript and prompt | none | 29.1 | GitHub, 0.1.0 |

Where each of them is stronger:

- **claude-code-ide.el** is mature and on MELPA, and gives you the real TUI together with
  a full IDE-side MCP integration.
- **claude-code.el** is the lightest way to get Claude Code into Emacs, and its terminal
  fidelity is exact, because it is the terminal.
- **eca-emacs** is not tied to one vendor, so it survives a change of model provider.
- **emacs-gravity** works from plugin hooks, so it sees sessions this Emacs did not start,
  and it reaches outside Emacs to tmux and a menu-bar app.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
