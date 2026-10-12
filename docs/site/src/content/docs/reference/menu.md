---
title: Transient menu
description: Every key of the C-c ? menu, with the page that covers it.
sidebar:
  order: 2
---

`C-c ?` in a session buffer, `C-c c ?` from any buffer, or `M-x ecc-menu` opens the menu, built with [transient](https://magit.vc/manual/transient/). `C-g` closes it. A line starting with `-` is a switch for the command after it.

![The transient menu open under a session, showing its six groups: Session, Send, Review, Respond, View and Config](../../../assets/menu.png)

The menu acts on the session of the current buffer. Elsewhere it takes the project's only session, the only session on the screen, or the session used last; when that is ambiguous, it asks once and remembers the answer for the buffer.

## Session

| Key | Action | See |
|---|---|---|
| `c` | Start a session (`C-u c` asks for the directory and the name) | [Sessions](/emacs-claude-code/features/sessions/#where-a-session-starts) |
| `r` | Resume a conversation (`-f` forks it) | [Resuming](/emacs-claude-code/features/sessions/#resuming-conversations) |
| `k` | Stop the process and kill the buffers; the recording stays | [Sessions](/emacs-claude-code/features/sessions/) |
| `R` | Rename the session | [Sessions](/emacs-claude-code/features/sessions/) |
| `v` | Show the session and go to the prompt | [Sessions](/emacs-claude-code/features/sessions/) |
| `i` | Interrupt the turn | [Sessions](/emacs-claude-code/features/sessions/) |
| `t` / `u` | Hand over to the terminal / take it back | [Handing over](/emacs-claude-code/features/sessions/#handing-over-to-the-terminal) |

## Send

| Key | Action | See |
|---|---|---|
| `s` / `x` / `g` / `f` | Send a line / a line with context / the region / the file | [Sending from your code](/emacs-claude-code/features/send/#sending-a-line-the-region-or-a-file) |
| `e` | Fix the error at point | [Fixing the error](/emacs-claude-code/features/send/#fixing-the-error-at-point) |
| `l` | Ask inline | [Asking inline](/emacs-claude-code/features/send/#asking-inline) |
| `H` | Insert a past prompt | [Prompt](/emacs-claude-code/features/prompt/#the-prompt-region) |
| `w` | Rewrite the region | [Rewriting](/emacs-claude-code/features/send/#rewriting-a-region) |

## Review

| Key | Action | See |
|---|---|---|
| `D` | Open the review menu | [Reviewing changes](/emacs-claude-code/features/review/) |
| `F` / `P` | Jump to the Files section / the plan | [Files section](/emacs-claude-code/features/prompt/#the-files-section) |
| `T` | Jump to a turn | [Timeline](/emacs-claude-code/features/prompt/#the-timeline) |

## Respond

| Key | Action | See |
|---|---|---|
| `a` / `d` | Allow / deny the oldest request | [Permissions](/emacs-claude-code/features/permissions/#answering-a-request) |
| `A` | Allow every waiting request (`-r` remembers the tools) | [Permissions](/emacs-claude-code/features/permissions/#answering-a-request) |
| `n` / `N` | Next waiting request (anywhere / in this project) | [Waiting sessions](/emacs-claude-code/features/sessions/#waiting-sessions) |
| `1`–`4` | Answer a question with that option | [Questions](/emacs-claude-code/features/permissions/#questions) |

## View

| Key | Action | See |
|---|---|---|
| `B` | Dashboard | [Dashboard](/emacs-claude-code/features/sessions/#the-dashboard) |
| `C` | Capabilities | [Capabilities](/emacs-claude-code/features/other/#capabilities) |
| `h` | Read a recorded conversation; `r` in it resumes it | [Resuming](/emacs-claude-code/features/sessions/#resuming-conversations) |
| `/` | Search past conversations | [Searching](/emacs-claude-code/features/sessions/#searching-past-conversations) |
| `U` | Usage and rate limits | [Usage](/emacs-claude-code/features/other/#usage) |
| `L` | The protocol log (`<<` in, `>>` out), for troubleshooting and bug reports | [Configuration](/emacs-claude-code/reference/configuration/#logging) |

## Spaces

| Key | Action | See |
|---|---|---|
| `j` | Go to a Space | [Spaces](/emacs-claude-code/features/spaces/#how-a-space-works) |
| `b` | The sidebar | [Sidebar](/emacs-claude-code/features/spaces/#the-sidebar) |
| `V` / `z` | Reset this Space's windows / zoom this window | [Spaces](/emacs-claude-code/features/spaces/#how-a-space-works) |
| `X` | Close this Space | [Spaces](/emacs-claude-code/features/spaces/#how-a-space-works) |
| `W` | Worktrees: `c` new, `o` open, `k` remove | [Worktrees](/emacs-claude-code/features/spaces/#worktrees) |

## Config

| Key | Action | See |
|---|---|---|
| `m` | Change the model of the running session | |
| `p` | Change the permission mode | [Permission modes](/emacs-claude-code/features/permissions/#permission-modes) |
| `o` | Turn Remote Control on or off, to drive the session from the Claude web or desktop app | |
| `O` / `K` | Open the session at claude.ai/code / copy that URL (needs Remote Control) | |
| `I` | Show or hide images in the transcript | [Images](/emacs-claude-code/features/prompt/#images) |
