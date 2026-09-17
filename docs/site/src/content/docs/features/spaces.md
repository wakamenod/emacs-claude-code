---
title: Spaces and worktrees
description: One tab per project, a sidebar listing every project and session, and git worktrees a session can live in.
sidebar:
  order: 5
---

A **Space** is a project with its own tab in the tab bar. A git worktree is its own Space, shown under the repository it came from.

[`ecc-use-spaces`](/emacs-claude-code/reference/configuration/#ecc-use-spaces) enables this behavior and is on by default. If you turn it off, you get the older arrangement, the only one before this: a transcript goes into a side window with a role — main, sub-1, sub-2 — and [`ecc-focus-project`](/emacs-claude-code/features/sessions/#focusing-one-project) reassigns those roles for one project. There are no tabs, no sidebar, and no worktree commands.

```elisp
(setq ecc-use-spaces nil)
```

## What a Space changes

With `classic`, focusing a project recreates the session windows from scratch. That makes sense when windows have roles, but not when you have arranged them yourself.

With `spaces`, windows have no roles. Transcripts in a Space sit side by side: the first opens to the right of the source, and each subsequent one splits the rightmost window. Nothing is ever stacked. From there, they are ordinary windows that you can split, move, enlarge, and close. A tab **is** a window configuration, so switching to another Space and back restores everything the way you left it.

`ecc-space-session-min-width` sets the minimum width in columns for a transcript, determining how many can fit. When there is no room for another window, no narrower window is created: the session you worked in longest ago gives up its window and continues running without one. You can bring it back from the sidebar or with `C-c c V`.

When a Space's tab is created, it opens with its sessions already on screen: they are placed beside the source, most recently used first, until the row has no room for another column. Any sessions that do not fit continue running without a window.

**Going to a Space with nothing running starts a session there.** A tab with only a file and no active session looks broken, and switching to a Space means you want to work there. To resume a previous conversation, type `/resume` in the session that opens.

This is controlled by [`ecc-space-always-session`](/emacs-claude-code/reference/configuration/#ecc-space-always-session), which is on by default and defines how a Space behaves. When enabled, a Space always holds a session: opening one starts a session, and a Space **closes itself when its last session is killed**, taking you to the Space beside it. A session whose process has exited is not gone—it keeps its place so `/resume` has somewhere to return to. Killing the session buffer closes the Space, not the CLI process exiting. When disabled, a Space is for reading as well as working: opening one starts nothing and shows the source, and the Space remains until you also kill the project's last buffer.

**Opening a worktree opens the repository it came from behind it.** A worktree needs its repository on screen to be displayed under it, so opening a worktree also opens the repository as its own Space, with a session if `ecc-space-always-session` is enabled. You remain focused on the worktree. A repository that already has a Space is left where it is.

**A session you kill takes its window with it.** The window is deleted and the transcripts beside it expand to fill the space, rather than leaving the window open with whatever was in it before — usually `*scratch*`. The last window of a tab cannot be deleted and shows the project's source instead.

`ecc-space-goto` also reaches a project that only has recordings — one you worked in before, with nothing running and no tab. Those projects are deliberately not in the sidebar and are not numbered: putting them there would shift the numbers assigned to the `1`-`9` keys.

```
┌ *ecc-sidebar* ─────┬ tab bar: [ecc] [herdr] [feat-x] ────────────────────┐
│ Spaces             │ ┌ source ─────────┬ session-A ────┬ session-B ────┐ │
│ ⚠ [1] ecc        ▾ │ │                 │ (tab line)    │ (tab line)    │ │
│    main ↑2 ↓0      │ │                 │               │               │ │
│   └─ ▶ [2] feat-x  │ │                 │               │               │ │
│ · [3] herdr        │ └─────────────────┴───────────────┴───────────────┘ │
│    master          │                                                     │
│                    │   one Space = one tab = one window arrangement      │
│                    │                                                     │
│ Sessions           │                                                     │
│ ⚠ ecc   waiting    │                                                     │
│ ▶ ecc-2 running    │                                                     │
│ · herdr    idle    │                                                     │
└────────────────────┴─────────────────────────────────────────────────────┘
```

The tab line inside each session window is unchanged: it switches between that project's sessions.

| Key | Command | What it does |
|---|---|---|
| `C-c c j` | `ecc-space-goto` | Go to a Space by name, including a project that only has recordings |
| `C-c c z` | `ecc-space-zoom` | Fill the tab with this window; press the same key to restore the windows |
| `C-c c V` | `ecc-space-reset-windows` | Reset this Space to the layout of a new tab: the source on the left, transcripts beside it |
| `C-c c ?` then `X` | `ecc-space-close` | Close this Space and stop everything running in it — including its worktrees, if it is a repository — then offer to remove the closed worktrees |
| — | `ecc-space-jump` | Go to the Nth Space, as numbered in the sidebar |

Going to a session takes you to its Space, regardless of which command you use: `C-c c n` (`ecc-next-attention`), `C-c c v`, the sidebar's `RET`, or the dashboard. A question or a plan opens its own buffer next to the session it belongs to — in its Space, with its transcript beside it. It takes the widest window that does not contain a transcript, which in a Space is where the code is. Once the question is answered, that window returns to what it held before. If every window contains a transcript, one of them is divided instead; no window is ever removed.

A tab's windows are yours, so nothing rearranges them automatically. This also means that if you pointed a window at another project's file, it keeps that file, and returning to the Space does not undo it. Use `C-c c V` (`ecc-space-reset-windows`) to restore the layout. It arranges the tab using the rules for a new tab: the source on the left, and transcripts beside it ordered by most recent use, stopping when the row is full. It leaves the sidebar where it is, at its current width, and restores it if you had hidden it. The only exception is a tab left with only transcripts: going to that Space automatically opens a window for the code again.

Closing a repository's Space also closes the worktrees shown under it. They form one group on the screen and close together, after a single question naming everything that will stop. Closing a worktree on its own leaves the repository open. A repository that was opened only to hold a worktree closes when its last worktree is closed.

Once the group is closed, the worktrees in it are **offered for removal in one question** that names them. Their Spaces are gone and nothing is left running in them, which is when you are likely ready to remove the directories. Answering no leaves them where they are. Closing a tab manually does not stop anything: sessions keep running without a window, and the sidebar or `C-c c V` brings them back.

### The bar itself is yours

A Space is a tab, and a tab is a named window arrangement in the frame. `tab-bar-mode` only draws the strip above it, and nothing here turns that mode on: `tab-bar-new-tab` turns it on when `tab-bar-show` is `t` (the default), and leaves it off if you set `tab-bar-show` to `nil`.

```elisp
(setq tab-bar-show nil)   ; Spaces with no strip at the top of the frame
```

When the bar is hidden, Spaces work the same way: tabs are created, named, switched, and closed exactly as before. The sidebar lists them, showing more detail about each Space than the tab bar can hold.

## The sidebar

`C-c c b` (`ecc-sidebar-focus`) opens the sidebar and moves point to it. Pressing the same key returns point to where it was. It works under `classic` too.

Under `classic`, the sidebar displays the same two lists and responds to the same keys; only navigation behaves differently. Pressing `RET` or `1`-`9` on a Space focuses that project the way `ecc-focus-project` always has, without creating a tab. Turning on the tab bar because you pressed a number would change your layout unexpectedly. Under `classic`, the sidebar is a dashboard that stays on screen; `spaces` is that dashboard plus a different layout for session windows.

The sidebar window has `no-other-window` set, so `C-x o` never switches to it while you are working. Use `C-c c b` to switch to it.

```
Spaces
⚠ [1] ecc                 ▾
   main ↑2 ↓0
  └─ ▶ [2] feat-x
· [3] herdr
   master

Sessions
⚠ ecc            waiting ×2
▶ ecc-2              running
· herdr                 idle
```

The top half lists the Spaces. Each row shows a status mark based on its highest-priority session, the number used by `1`-`9`, and the Space name. Below each repository is its git status: the branch, and how far it is from its upstream. Worktrees appear on a tree line under their parent repository and are named after their branch, distinguishing worktrees from the same repository.

A repository with worktrees displays `▾` at the right end of its row, or `▸` when folded. Pressing `TAB` or clicking the arrow toggles it. A folded repository also reflects its worktrees, so its status mark still shows when one of them is waiting for an answer.

The bottom half lists the sessions, each with its mark, name, and what it is waiting for. The marks, colours, and blink match the tab line, so a session shows the same status wherever it appears.

| Key | What it does |
|---|---|
| `RET` | Go to the Space or session on this line |
| `n`, `p` | Next, previous row |
| `TAB` | Fold or unfold a repository's worktrees |
| `1`–`9` | Go to the Space with that number |
| `c` | Start a session in this Space |
| `W` | Create a worktree from this Space and start a session there |
| `x` | Close this Space |
| `X` | Remove this worktree's directory |
| `k` | Stop this session |
| `a`, `d` | Allow or deny what this session is waiting on |
| `g` | Refresh git status and redraw |
| `q` | Hide the sidebar |

`ecc-sidebar-width` sets the sidebar width in columns (28 by default). `ecc-sidebar-sessions-sort` orders the bottom half: `spaces` (the default) keeps sessions under their Space, while `priority` puts sessions waiting for an answer first.

## Worktrees

A git worktree is a second working tree for a repository on its own branch. It lets two sessions work on the same project without seeing each other's edits.

These commands work under both layouts.

| Key | Command | What it does |
|---|---|---|
| `C-c c ?` then `W c` | `ecc-start-worktree` | Check out a branch beside the repository and start a session there |
| `C-c c ?` then `W o` | `ecc-start-in-worktree` | Start a session in an existing worktree |
| `C-c c ?` then `W k` | `ecc-remove-worktree` | Stop the sessions running in a worktree and remove it |

These three commands live under `W` in the menu rather than on their own keys. They manage worktrees rather than work inside them, and are used once a week rather than once an hour like the Spaces keys.

`ecc-start-worktree` prompts for a branch, offering existing branches with nothing filled in. An existing branch is checked out as it is; a new branch is created from `HEAD`.

A branch that is **already checked out somewhere** is switched to rather than refused: a branch can only be in one worktree at a time, so asking for it can only mean the worktree that has it. You are asked for confirmation before the session starts there. The worktree does not have to be named the way ecc would name it. Claude Code's own worktrees replace `/` with `+` where ecc uses `-`, and ecc looks up the branch, not the directory.

Worktrees are placed in [`ecc-worktree-directory`](/emacs-claude-code/reference/configuration/#ecc-worktree-directory), which defaults to `.claude/worktrees`. A relative path is relative to the repository, so a worktree for `feat/x` lands at `<repo>/.claude/worktrees/feat-x`. An absolute path is shared across all repositories, and a worktree lands at `<directory>/<repository>/<branch-slug>`.

When the **last** session working in a worktree ends, ecc offers to remove the worktree immediately — however it ended: `ecc-kill`, the dashboard's `k`, the sidebar's `k`, the tab's close button, or without any action from you. The question appears a moment after the session ends, because a session can exit from inside its own process, where you cannot be prompted. Stopping one of two sessions working in the same worktree does not offer to remove it, since the other session is still using it. Buffers still visiting the worktree are counted in the question rather than closed.

**No branch is ever deleted.** `ecc-remove-worktree` removes a directory. The work remains on the branch, and the branch stays. Because removing a worktree cannot lose committed changes, the question is safe to ask on its own. To delete a branch, run `git branch -d` whenever you want.

**A worktree that git does not find clean requires a second yes.** git refuses to remove a worktree with uncommitted changes or untracked files. That refusal is presented as its own question, naming the directory, before anything is forced.

## Handing work to a session in a worktree

If you ask inside a session for work to be done in a worktree — "cut a worktree and do X there" — the CLI on its own runs `git worktree add` and continues in the same conversation. This leaves one session working in two worktrees.

With the [Emacs MCP server](/emacs-claude-code/start/installation/) enabled (`ecc-mcp-enabled`), the model is offered the `start_worktree_session` tool instead. The model names the branch and writes a brief. Emacs then creates the worktree, opens it as a Space, starts a session there, and sends it that brief. Because the new session cannot read the conversation it came from, it is told which repository it is in, which branch it is on, and which session sent it. The session that requested the work reports where it went and does not do the work itself.

**What the new session is told.** The brief is the model's summary of the work. Emacs adds context it tracked from that conversation: the files it touched, using their paths in the new worktree; the plans it wrote; the path of the recording, to read only if the brief leaves questions open; and any uncommitted changes in the repository. That last detail matters: the worktree is created from `HEAD`, so uncommitted work is not in it. Commit it first, or mention it in the brief.

**The two other ways are turned back.** A model can also access a worktree through the CLI's own `EnterWorktree` or through `git worktree add` in Bash. Both methods leave one conversation working in two worktrees. When the session has the tool, Emacs refuses those requests with a sentence naming the tool, and you are not prompted. In a session without the tool — with the MCP server off, or `start_worktree_session` in `ecc-mcp-excluded-tools` — Emacs refuses nothing, and it never touches `ExitWorktree`. In an `auto` permission mode, the CLI does not ask Emacs at all: it runs `git worktree add` directly, and Emacs sees no request (measured against CLI 2.1.272). If your prompt draft includes *worktree* in English or Japanese, ecc therefore sends it with a one-line reminder about the tool. In that mode, this line is the only safeguard. Although this line is sent, you did not write it, so the transcript does not place it in your prompt section. Instead, it is shown under the prompt as a folded heading ("1 line Emacs added") that opens like any other.

If another worktree already holds the branch, Emacs refuses the request instead of joining it, since running two sessions in one worktree is not what handing work over means. The model is told to name another branch. There is no `M-x` command for this; from Lisp, use `ecc-worktree-delegate`.

Under `spaces`, a session started in a worktree opens its own Space under the repository it came from.
