---
title: Command reference
description: Every command ecc offers, in the order the menu presents them.
sidebar:
  order: 1
---

`C-c ?` in a session, or `M-x ecc-menu` from anywhere, opens one transient menu
that reaches every command worth a key. This page follows that menu, group by
group, and adds the commands that live in a mode map rather than in the menu.

The menu key is given for each command, so `C-c ?` then `c` starts a session.

## Session

| Key | Command | What it does |
|---|---|---|
| `c` | `ecc-start` | Start a session in a directory, under a name. Autoloaded — `M-x ecc-start` works before ecc is loaded |
| `r` | `ecc-resume-menu` | Start a session again with `--resume`. Opens a menu of its own, where `-f` forks the conversation and `r` resumes |
| `k` | `ecc-kill` | Stop a session and forget it |
| `R` | `ecc-rename-session` | Rename a session, and its buffers with it |
| `v` | `ecc-show-session` | Show the session this buffer talks to, and go to its prompt |
| `w` | `ecc-toggle` | Hide the session windows of this project, or bring the hidden ones back |
| `S` | `ecc-switch-session` | Show another session in this window, the way clicking its tab would |
| `i` | `ecc-interrupt` | Interrupt the running turn |
| `t` | `ecc-tui-open` | Carry on with the session in the real terminal UI |
| `u` | `ecc-tui-return` | Take it back from the terminal and run it in Emacs again |

`ecc-toggle-all` hides or restores the session windows of every project, not
just this one. It is not on the menu: `C-u` before `w` does the same, and the
menu keeps a prefix argument while it is open.

:::caution[Resuming a live session forks it]
A second process running `--resume` on a session that is still alive forks the
conversation, and there is no lock to stop it. Stop the session first.
`ecc-history-resume` asks before doing this.
:::

## Send

Most of these work from an ordinary source buffer, not from the transcript.
They are the point of having the client inside the editor: what Emacs knows
that the CLI does not.

| Key | Command | What it does |
|---|---|---|
| `s` | `ecc-send` | Send a line typed in the minibuffer. A prefix argument asks which session |
| `x` | `ecc-send-with-context` | Send text along with the file and line of the current buffer |
| `g` | `ecc-send-region` | Send the region, or the whole buffer, quoted. A prefix argument asks for an instruction to put before it |
| `f` | `ecc-send-buffer-file` | Send this buffer's file as an `@path` reference |
| `e` | `ecc-fix-error-at-point` | Ask Claude to fix the diagnostic at point |
| `l` | `ecc-inline-prompt` | Ask about the region, or this file, and answer right here in an overlay |
| `W` | `ecc-rewrite` | Rewrite the region as an instruction says. The answer is shown; nothing is written until it is accepted |
| `/` | `ecc-slash-command` | Send a slash command, chosen with completion |

The slash commands are offered under `/` as a submenu of their own, built from
what the session reports it has. In the prompt region, typing `/` does the same
thing.

`ecc-btw-ask` asks a question on the side, without interrupting whatever Claude
is doing — the `/btw` of the terminal client. `ecc-btw-show` shows what has been
asked. Neither is on the main menu; `C-c C-b` in a session reaches the second,
and `a` there asks the next one.

## Review

| Key | Command | What it does |
|---|---|---|
| `D` | `ecc-review` | Open every change of the session as one diff to review |
| `F` | `ecc-goto-files` | Move to the Files section |
| `P` | `ecc-goto-plan` | Move to the Plan section |
| `T` | `ecc-timeline` | Pick a turn of this session |

`ecc-session-export-markdown` (`C-c C-e`) writes the conversation out as
Markdown. Because the transcript is ordinary buffer text, `occur`, `isearch`
and narrowing work on it without any help from ecc.

## Respond

Every key in this group except `A` is also in `ecc-global-map`, under the same
letter, so it works from any buffer at all. See the
[key binding reference](/emacs-claude-code/reference/key-bindings/).

| Key | Command | What it does |
|---|---|---|
| `a` | `ecc-answer-allow` | Allow the oldest waiting request |
| `A` | `ecc-allow-all-menu` | Allow every request waiting in this session. Opens a menu of its own, where `-r` also stops the tools involved being asked about again and `A` allows |
| `d` | `ecc-answer-deny` | Deny the oldest waiting request, with a reason |
| `n` | `ecc-next-attention` | Jump to the next request waiting, across sessions |
| `N` | `ecc-next-attention-in-project` | The same, restricted to the current project |
| `1`–`4` | `ecc-answer-option-N` | Answer the oldest question with option N |

Two commands carry a switch, and each has a menu of its own to carry it: `r`
in the Session group opens one holding `-f` (fork the conversation), and `A`
here opens one holding `-r` (stop asking about the tools involved). In
transient a switch belongs to the menu it sits in rather than to one command,
so a switch shown beside a column of commands reads as though the whole column
obeyed it. Given its own menu, a switch can only mean the command next to it.
A switch is still set before the command runs and shows its state on screen,
which suits forking in particular — a second process resuming a live session
forks the conversation, with no lock to stop it.

Permission prompts **default to deny**. Inside a session, `ecc-perm-allow` and
`ecc-perm-deny` answer the request at point, and `ecc-perm-allow-always`,
`ecc-perm-approve-turn` and `ecc-perm-add-pattern` widen that answer to
everything like it, to the rest of the turn, or to a pattern you give.

## View

| Key | Command | What it does |
|---|---|---|
| `b` | `ecc-dashboard` | Every session this Emacs runs, in one list |
| `y` | `ecc-capabilities-show` | The skills, agents, commands, MCP servers and plugins a session has |
| `h` | `ecc-history-open` | Open a recorded conversation in a session buffer |
| `U` | `ecc-usage` | How much of the Claude Code plan has been used |
| `L` | `ecc-show-log` | The raw protocol log of this session |

`ecc-history-open` reads back what the CLI wrote under `~/.claude/projects`.
Those recordings are trees, not lists: editing, interrupting and resuming all
grow branches. Abandoned branches are folded away, except that `/compact`
starts a new root and is never treated as abandoned.

The dashboard sees headless sessions too, because it reads the same files the
CLI writes about itself under `~/.claude/sessions`.

## Config

| Key | Command | What it does |
|---|---|---|
| `m` | `ecc-set-model` | Ask this session to use another model |
| `p` | `ecc-set-permission-mode` | Ask this session to switch permission mode |
| `o` | `ecc-remote-control-toggle` | Turn Remote Control on or off for this session |
| `O` | `ecc-remote-control-open` | Open this session at claude.ai/code |
| `K` | `ecc-remote-control-copy-url` | Put that URL in the kill ring |
| `C` | `ecc-customize` | Open the customization group |

`ecc-set-model` changes the model of a running session without restarting it,
which is why there is no setting that names one. `S-TAB` in a session cycles
the permission mode without going through the menu.

## The MCP server

| Command | What it does |
|---|---|
| `ecc-mcp-start` | Start the MCP server and return the port it listens on |
| `ecc-mcp-stop` | Stop it |

Neither is normally needed: with `ecc-mcp-enabled` set, the server starts the
first time a session wants it. See the
[configuration reference](/emacs-claude-code/reference/configuration/#the-mcp-server).
