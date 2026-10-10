**English** | [日本語](README.ja.md)

---

# Emacs Client for Claude Code

An Emacs client for the Claude Code CLI. Conversations run directly inside ordinary Emacs buffers.

![Emacs 29.1+](https://img.shields.io/badge/Emacs-29.1%2B-7F5AB6)
![Claude Code CLI](https://img.shields.io/badge/Claude%20Code-CLI-D97757)

![A whole session: two prompts, the tools each one ran, the diffs they were allowed to make, and the answers](docs/images/overview.png)

**Documentation:** <https://wakamenod.github.io/emacs-claude-code/>

> **Pre-1.0.** ecc is not stable yet, and breaking changes are likely: commands, key bindings and settings can change or go away from one release to the next. Read [CHANGELOG.md](CHANGELOG.md) before upgrading.

## Overview

ecc runs `claude` in headless mode, communicates over pipes using its stream-json protocol, and renders the session in a standard Emacs buffer.

The transcript is ordinary buffer text, so search, `occur`, narrowing, copying, and exporting to Markdown work as usual. ecc puts faces on at insertion, and you can customize them with `M-x customize`.

### Scope and Trade-offs

- **No terminal emulation:** ecc does not replicate the CLI's terminal UI. `ecc-tui-open` hands a live session to a terminal and takes it back when you are done.
- **Claude Code only:** ecc speaks the Claude Code protocol directly; it is not a general-purpose LLM frontend.
- **Built-in renderers:** ecc's own small parsers draw Markdown, tables, and diffs, without external packages.
- **Direct protocol reflection:** Permission requests, usage figures (`get_usage`), and conversation logs come from the CLI as it reports them, not from guesswork.

### Key Features

- **[Claude in the review](https://wakamenod.github.io/emacs-claude-code/features/review-claude/):** With the MCP server on, Claude reads the diff review through the `review_*` tools and comments on it line by line. It opens the review of its session, puts comments on lines or hunks, replies to your comments, and scrolls the review to the place it is talking about. Its comments have a face of their own, and `a` hides them. `T` in the review asks Claude for a tour of the changes, one stop at a time, and `M` sends it a message without leaving the review. In ediff, a pane beside the diff shows Claude's reply and lets you answer its permission requests.
- **[Diff reviews](https://wakamenod.github.io/emacs-claude-code/features/review/):** See every change a session made in one `diff-mode` buffer, whether it came from an edit, a shell command, or a script. `C-c c D` opens a menu to choose what to compare instead: uncommitted, staged or unstaged changes, the current branch against another, a GitHub pull request when the `gh` CLI is installed, a commit, or a range. Comment on lines or whole hunks and submit them as a single prompt. The review stays open after you send, so Claude can answer each comment in it, and the next send carries only the new comments. `s` lists the files beside the diff, and `/` hides the files that do not match a filter. The open review follows the files as they change. Setting `ecc-review-style` opens the same review in ediff, with every file in one session and the words that changed marked in every difference on the screen. The old side is above the new one, and `|` puts them side by side. Claude's comments and following the files work there too. The keys work in both ediff windows: `c` comments on the line at point, moving point brings the other side along, and `RET` opens the file at that line in a frame of its own.
- **[Interactive edits](https://wakamenod.github.io/emacs-claude-code/features/permissions/#editing-a-proposal-before-allowing-it):** Review and modify proposed file edits before approving them.
- **[Jump to source](https://wakamenod.github.io/emacs-claude-code/features/prompt/#opening-the-source):** Press `RET` on a diff line, on the heading of a tool call that names a file, or on a path in Claude's reply (`foo.el:12`) to open the file at that line; a path in a reply also opens on a click. The line number accounts for later changes to the same file.
- **[Plan mode](https://wakamenod.github.io/emacs-claude-code/features/permissions/#plan-mode):** Read and adjust a proposed plan in a writable buffer.
- **[Global access](https://wakamenod.github.io/emacs-claude-code/reference/key-bindings/):** Approve or deny pending tool requests from any buffer.
- **[Session management](https://wakamenod.github.io/emacs-claude-code/features/sessions/):** Manage multiple concurrent sessions from a dashboard.
- **[Spaces and worktrees](https://wakamenod.github.io/emacs-claude-code/features/spaces/):** Every project gets an Emacs tab of its own -- a Space -- and the windows in it stay where you put them (`ecc-use-spaces`, on by default). A sidebar lists every project and session with what each is doing, and `ecc-start-worktree` checks a branch out beside the repository and opens it as a Space of its own.
- **Safe defaults:** In the `default` [permission mode](https://wakamenod.github.io/emacs-claude-code/features/permissions/#permission-modes), Claude asks before it edits a file or runs a command, and a request that can no longer be answered is recorded as denied. Other modes let some of these through without asking. The built-in loopback MCP server is disabled by default. When it is on, its review tools are allowed without asking, since they write no files. Evaluating Elisp requires explicit opt-in.

## Requirements

- **Emacs 29.1+** (`transient` is built-in; no required external packages)
- **[Claude Code CLI](https://docs.claude.com/en/docs/claude-code)** on `PATH` or configured via `ecc-executable`

### Optional Dependencies

ecc uses these packages when they are installed and works without them:

- [ghostel](https://github.com/dakra/ghostel) — Terminal emulator for sessions handed over by `ecc-tui-open`.
- [posframe](https://github.com/tumashu/posframe) — Floating popups for `/btw` side-queries and usage reports.
- [nerd-icons](https://github.com/rainstormstudio/nerd-icons.el) — Icons for tool calls in the transcript.
- [markdown-mode](https://github.com/jrblevin/markdown-mode) — Major mode for plan and review buffers.

## Installation

ecc is not currently on MELPA; install it directly from this repository.

### Emacs 30+ (`use-package` with `:vc`)

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest))
```

*To pin a specific commit, pass `:rev "<commit-sha>"`.*

### Emacs 29 (`package-vc-install`)

```
M-x package-vc-install RET https://github.com/wakamenod/emacs-claude-code RET
```

Then configure it with a standard `use-package` declaration (without `:vc`).

<details>
<summary>straight.el or Elpaca</summary>

Because the repository name is `emacs-claude-code` while the package name is `ecc`, package managers that infer the package name from the repository URL must declare it explicitly:

```elisp
;; straight.el
(use-package ecc
  :straight (ecc :type git :host github :repo "wakamenod/emacs-claude-code"))

;; Elpaca
(use-package ecc
  :ensure (ecc :host github :repo "wakamenod/emacs-claude-code"))
```
</details>

## Configuration

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest)
  :bind-keymap ("C-c c" . ecc-global-map)
  :custom
  (ecc-permission-mode "auto")
  (ecc-notify-level 'pulse)
  (ecc-usage-display 'posframe)
  (ecc-btw-display 'posframe)
  (ecc-prompt-suggestions-enabled t)
  ;; Uncomment to review in ediff instead of one diff-mode buffer.
  ;; (ecc-review-style 'ediff)
  ;; The Emacs MCP server: xref, imenu and flymake for Claude, and the
  ;; tool that hands work to a session in a worktree of its own.
  (ecc-mcp-enabled t))
```

For all other settings, see the [configuration reference](https://wakamenod.github.io/emacs-claude-code/reference/configuration/).

## Quickstart

1. Run `M-x ecc-start` in a project buffer to start a session.
2. Type your message in the bottom prompt region.
3. Press `C-c C-c` to send (`RET` inserts a newline).
4. When Claude requests tool permissions, press `C-c C-a` to allow or `C-c C-d` to deny.
5. Press `C-c ?` to open the command menu.

## Key Bindings

For the prompt and transcript key bindings, see
[Prompt and transcript](https://wakamenod.github.io/emacs-claude-code/features/prompt/).
For the global key bindings that work from any buffer, see the
[key bindings reference](https://wakamenod.github.io/emacs-claude-code/reference/key-bindings/).

## Acknowledgements

ecc builds on ideas from:

- **[claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el)** — IDE-side CLI integration patterns.
- **[claude-code.el](https://github.com/stevemolitor/claude-code.el)** — Terminal-buffer ergonomics in Emacs.
- **[eca-emacs](https://github.com/editor-code-assistant/eca-emacs)** — Buffer-based chat formatting and inline overlays.
- **[emacs-gravity](https://github.com/gdanov/emacs-gravity)** — Structured tree navigation, plan reviews, and approval workflows.

## Comparison

Comparison of Emacs packages for Claude Code:

| Project | Protocol / Transport | UI Type | Dependencies | Emacs Version | Source |
|---|---|---|---|---|---|
| [claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el) | CLI TUI + WebSocket MCP server | Terminal emulator | `websocket`, `transient`, `web-server` | 28.1 | GitHub |
| [claude-code.el](https://github.com/stevemolitor/claude-code.el) | CLI TUI | Terminal emulator | `transient`, `inheritenv` | 30 | GitHub |
| [eca-emacs](https://github.com/editor-code-assistant/eca-emacs) | JSON-RPC via standalone `eca` binary | Markdown buffer + overlays | `dash`, `s`, `f`, `markdown-mode`, `compat` | 28.1 | MELPA |
| [emacs-gravity](https://github.com/gdanov/emacs-gravity) | Plugin hooks + Node shim + socket | Magit-section tree | `magit-section`, `transient`, Node.js | 27.1 | GitHub |
| **ecc** | Headless `claude` stream-json via pipe | Standard buffer (transcript + prompt) | None | 29.1 | GitHub |

Dependencies are what each project's `Package-Requires` names besides Emacs itself, read from the projects on 2026-09-18. `transient` has been part of Emacs since 28.1, so a package using the bundled version does not declare it; the three that do require a newer one than the Emacs they support ships. ecc uses `posframe` and `nerd-icons` when they happen to be installed and works without either, which is why neither is a dependency.

### Architectural Focus

- **claude-code-ide.el:** Preserves the native TUI in a terminal buffer while providing full IDE-side MCP integration.
- **claude-code.el:** Lightweight wrapper running the native CLI TUI directly in an Emacs terminal buffer.
- **eca-emacs:** Provider-agnostic architecture backed by an external server binary.
- **emacs-gravity:** Deep hook-based integration capturing external sessions across Emacs, tmux, and system trays.
- **ecc:** Converts CLI streams into standard editable Emacs text buffers without running a terminal emulator.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
