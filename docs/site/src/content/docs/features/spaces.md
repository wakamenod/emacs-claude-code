---
title: Spaces and worktrees
description: One tab per project, a sidebar listing every project and session, and git worktrees a session can live in.
sidebar:
  order: 8
---

A **Space** is a project with an Emacs tab of its own. A git worktree is a Space of its own too, shown under its repository. Spaces are on by default (`ecc-use-spaces`); the layout without them is described [at the end](#without-spaces).

## How a Space works

![The sidebar listing every Space and session, a tab for each project across the top, and one Space holding its source with two transcripts beside it](../../../assets/spaces.png)

The sidebar is on the left, a tab for each project is at the top, and the transcripts sit to the right of the source, each new one splitting the rightmost window. They are ordinary windows: split, move and close them as you like. Leaving a Space and coming back restores its windows.

No transcript is made narrower than `ecc-space-session-min-width` (80). When the row is full, the session worked in longest ago gives up its window and keeps running; the sidebar or `C-c c V` brings it back.

Going to a Space with nothing running starts a session there, and killing its last session closes the Space. Type `/resume` in the new session to carry on an earlier conversation. With `ecc-space-always-session` off, a Space opens on the source alone and stays until you kill the project's last buffer.

| Key | Command | Action |
|---|---|---|
| `C-c c j` | `ecc-space-goto` | Go to a Space by name, including a project that only has recordings |
| `C-c c z` | `ecc-space-zoom` | Fill the tab with this window; again to restore |
| `C-c c V` | `ecc-space-reset-windows` | Lay the Space out as a new tab: the source on the left, transcripts beside it |
| `C-c c ?` then `X` | `ecc-space-close` | Close this Space and stop everything in it, its worktrees included, then offer to remove those worktrees |
| — | `ecc-space-jump` | Go to the Nth Space, as numbered in the sidebar |

`tab-bar-show` decides whether the tab bar is drawn; ecc does not turn `tab-bar-mode` on itself. With `(setq tab-bar-show nil)` the Spaces work the same, and the sidebar lists them.

## The sidebar

![The sidebar: two projects, one of them a repository with two worktrees under it, and the sessions below with what each is doing](../../../assets/sidebar.png)

`C-c c b` (`ecc-sidebar-focus`) opens the sidebar and moves point into it; again moves point back.

The top half lists the Spaces with their state, their number and their name. A repository shows its branch and how far it is from its upstream, with its worktrees below it. The bottom half lists the sessions, marked as in the [tab line](/emacs-claude-code/features/sessions/#the-tab-line).

| Key | Action |
|---|---|
| `RET` | Go to the Space or session on this line |
| `n`, `p` | Next, previous row |
| `TAB` | Fold or unfold a repository's worktrees |
| `1`–`9` | Go to the Space with that number |
| `c` | Start a session in this Space |
| `W` | Create a worktree from this Space and start a session there |
| `k` | Stop this session |
| `K` | Remove this worktree's directory |
| `X` | Close this Space |
| `a`, `d` | Allow or deny what this session waits on, as the [dashboard](/emacs-claude-code/features/sessions/#the-dashboard) does |
| `g` | Refresh git status and redraw |
| `q` | Hide the sidebar |

`ecc-sidebar-width` sets the width (28 columns). `ecc-sidebar-sessions-sort` orders the sessions: `spaces` (the default) under their Space, `priority` with those waiting for you first.

## Worktrees

A git worktree is a second working tree of a repository on a branch of its own, so two sessions can work on one project without seeing each other's edits. These commands work with Spaces on or off.

| Key | Command | Action |
|---|---|---|
| `C-c c ?` then `W c` | `ecc-start-worktree` | Check out a branch beside the repository and start a session there |
| `C-c c ?` then `W o` | `ecc-start-in-worktree` | Start a session in an existing worktree |
| `C-c c ?` then `W k` | `ecc-remove-worktree` | Stop the worktree's sessions and remove it |

`ecc-start-worktree` offers the existing branches. An existing branch is checked out as it is, and a new one is created from `HEAD`. If another worktree already has the branch, ecc offers to start the session there.

Worktrees go in `ecc-worktree-directory`, `.claude/worktrees` by default. A relative path is under the repository (`<repo>/.claude/worktrees/feat-x`); an absolute one is shared by every repository (`<directory>/<repository>/feat-x`).

When the last session in a worktree ends, ecc offers to remove the worktree. **No branch is deleted**: removing a worktree removes its directory. If the worktree has uncommitted changes or untracked files, ecc names it and asks again before forcing the removal.

## Handing work to a session in a worktree

With the [Emacs MCP server](/emacs-claude-code/start/installation/#enabling-the-mcp-server) on (`ecc-mcp-enabled`), asking a session to do something in a worktree gives the model `start_worktree_session`. It names a branch and writes a brief. Emacs makes the worktree from `HEAD`, opens it as a Space, and starts a session there with the brief, adding the files the conversation touched, its plans, its recording and the uncommitted changes. Commit that work first, or say in the brief that it is uncommitted.

If the model tries to make a worktree by itself, Emacs denies the request and points it to the tool. A draft that mentions a worktree goes out with one line reminding the model of the tool, shown folded under your prompt as "1 line Emacs added". A branch already checked out in another worktree is refused, so two sessions never share one. From Lisp the command is `ecc-worktree-delegate`.

Without the MCP server, the CLI runs `git worktree add` itself and carries on in the same conversation.

[A day in a Space](/emacs-claude-code/usecases/spaces/) follows a piece of work through this.

## Without Spaces

```elisp
(setq ecc-use-spaces nil)
```

With Spaces off, transcripts open in side windows, given the roles main, sub-1 and sub-2, with no tabs, no sidebar and no Space commands. Worktrees still work.

| Setting | Default | Description |
|---|---|---|
| `ecc-window-large-frame-min-height` | `80` | Frame height in lines needed for a third session window. Below it, sessions share two windows and the tab line switches between them |
| `ecc-window-sub-height` | `0.33` | Height of the third session window, as a fraction or in lines, taken from the main area |

`M-x ecc-focus-project` shows one project's sessions and source, and takes the other projects' session windows off the screen. It kills nothing and stops no process.
