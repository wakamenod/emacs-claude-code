---
title: Spaces and worktrees
description: One tab per project, a sidebar listing every project and session, and git worktrees a session can live in.
sidebar:
  order: 5
---

A **Space** is one project with a tab of the tab bar to itself. A git worktree is a Space of its own, drawn under the repository it came from.

This is the `spaces` value of [`ecc-layout`](/emacs-claude-code/reference/configuration/#ecc-layout). The default, `classic`, is unchanged: a transcript goes into a side window with a role — main, sub-1, sub-2 — and [`ecc-focus-project`](/emacs-claude-code/features/sessions/#focusing-one-project) deals those roles out again for one project.

```elisp
(setq ecc-layout 'spaces)
```

## What a Space changes

With `classic`, focusing a project deals the session windows out again from nothing. That is the right thing when the windows have roles, and the wrong thing when you have arranged them yourself.

With `spaces` the windows have no roles. The transcripts of a Space stand side by side: the first opens beside the source, to the right, and every one after it divides the rightmost of them. Nothing is ever stacked. From there they are ordinary windows, yours to split, move, enlarge and close. A tab **is** a window arrangement, so going to another Space and back brings the whole of it back the way you left it.

How many fit is `ecc-space-session-min-width`, the columns a transcript may not go under. When there is no room for another one, no narrower window is made: the session you worked in longest ago hands its window over, and goes on running without one. The sidebar and `ecc-toggle` bring it back.

A Space whose tab has to be made comes up with its sessions already on the screen: they are dealt out beside the source, most recently used first, until the row has no room for another column. The ones that do not fit go on running without a window.

**Going to a Space with nothing running starts a session there.** Always — there is no setting. A tab with a file in it and no way to say anything is a Space that looks broken, and going to a Space is asking to work there. To pick up the conversation that was there before, type `/resume` in the session that opens.

`ecc-space-goto` also reaches a project you have only recordings of — one worked in before, with nothing running and no tab. Those projects are deliberately not in the sidebar and are not numbered: putting them there would move the numbers the `1`-`9` keys take under your feet.

```
┌ *ecc-sidebar* ─┬ tab bar: [ecc] [herdr] [feat-x] ────────────────────┐
│ Spaces         │ ┌ source ─────────┬ session-A ────┬ session-B ────┐ │
│  1 ecc       ⚠ │ │                 │ (tab line)    │ (tab line)    │ │
│    main ↑2 ↓0  │ │                 │               │               │ │
│  2   feat-x  ▶ │ │                 │               │               │ │
│  3 herdr     · │ └─────────────────┴───────────────┴───────────────┘ │
│    master      │                                                     │
│    new         │   one Space = one tab = one window arrangement      │
│                │                                                     │
│ Agents         │                                                     │
│ ⚠ ecc   waiting│                                                     │
│ ▶ ecc-2 running│                                                     │
│ · herdr    idle│                                                     │
└────────────────┴─────────────────────────────────────────────────────┘
```

The tab line inside each session window is unchanged: it switches between the sessions of that project.

| Key | Command | What it does |
|---|---|---|
| `C-c c J` | `ecc-space-goto` | Go to a Space, by name — including a project you have only recordings of |
| `C-c c j` | `ecc-focus-project` | The same thing for the project of this buffer |
| `C-c c z` | `ecc-space-zoom` | Fill the tab with this window; the same key puts the windows back |
| `C-c c V` | `ecc-window-focus-source` | Show this Space's source in the main window |
| `C-c c ?` then `X` | `ecc-space-close` | Close this Space and stop what is running in it |
| — | `ecc-space-jump` | Go to the Nth Space, as numbered in the sidebar |

Going to a session takes you to its Space, whichever command asked: `C-c c n`
(`ecc-next-attention`), `C-c c v`, the sidebar's `RET`, the dashboard. A question
or a plan opens its own buffer, and that buffer opens next to the session it
belongs to — in its Space, with its transcript beside it. It takes the widest
window that holds no transcript, which in a Space is where the code is, and that
window goes back to what it held once the question is answered. Only where every
window is a transcript is one of them divided; none is ever taken away.

The windows of a tab are yours, so nothing rearranges them behind your back. That cuts both ways: a window you pointed at another project's file keeps that file, and going to the Space again does not undo it. `C-c c V` (`ecc-window-focus-source`) is the way back — it shows this Space's source in the main window, and asks which buffer with `C-u`. The one exception is a tab with nothing but transcripts left in it, which is nobody's arrangement: going to that Space opens a window for the code again, to the left of the transcripts.

Closing a Space does not touch the checkout of a worktree. Closing its tab by hand stops nothing: the sessions go on running with no window, and `C-c c w` (`ecc-toggle`) or the sidebar brings them back.

## The sidebar

`C-c c B` (`ecc-sidebar-focus`) opens the sidebar and puts point in it; the same key puts point back where it was. It works under `classic` too.

Under `classic` the sidebar draws the same two lists and answers the same keys; what changes is what going somewhere means. `RET` and `1`-`9` on a Space focus that project the way `ecc-focus-project` always has, and no tab is made -- turning the tab bar on because you pressed a number would be changing the layout behind your back. So the sidebar under `classic` is the dashboard that stays on the screen; `spaces` is that plus a different way of laying the session windows out.

The sidebar window is `no-other-window`, so `C-x o` never lands in it while you are working — `C-c c B` is the way in.

```
Spaces
 1 ecc                  ⚠
   main ↑2 ↓0
 2   feat-x             ▶
 3 herdr                ·
   master
   new

Agents
⚠ ecc            waiting ×2
▶ ecc-2              running
· herdr                 idle
```

The top half lists the Spaces: a number, the name, and a mark for what the Space is doing — the loudest of its sessions wins. Under a repository comes what git says: the branch, and how far it is from its upstream. A worktree is indented under the repository it came from and is named by its branch, which is what tells two checkouts of one repository apart.

The bottom half lists the sessions, each with its mark, its name and what it is waiting for. The marks, the colours and the blink are the tab line's, so a session says the same thing wherever it is drawn.

| Key | What it does |
|---|---|
| `RET` | Go to the Space or session on this line |
| `n`, `p` | Next, previous row |
| `TAB` | Fold a repository's worktrees away, or unfold them |
| `1`–`9` | Go to the Space with that number |
| `c` | Start a session in this Space |
| `W` | Make a worktree of this Space and start a session there |
| `x` | Close this Space |
| `X` | Remove this worktree's checkout |
| `k` | Stop this session |
| `a`, `d` | Allow or deny what this session is waiting on |
| `g` | Ask git again and redraw |
| `q` | Hide the sidebar |

`ecc-sidebar-width` is its width in columns, 28 by default. `ecc-sidebar-agents-sort` orders the bottom half: `spaces` (the default) keeps the sessions under their Space, `priority` puts what wants an answer first.

## Worktrees

A git worktree is a second checkout of one repository on a branch of its own. It is how two sessions work on one project without either seeing the other's edits.

These commands work under both layouts.

| Key | Command | What it does |
|---|---|---|
| `C-c c C` | `ecc-start-worktree` | Check a branch out beside the repository and start a session there |
| `C-c c ?` then `E` | `ecc-start-in-worktree` | Start a session in a worktree that already exists |
| `C-c c ?` then `M` | `ecc-remove-worktree` | Stop the sessions working in a checkout and undo it |

`ecc-start-worktree` asks for a branch, offering the branches that exist and filling nothing in. A branch that exists is checked out as it is; one that does not is created from `HEAD`.

A branch that is **already checked out somewhere** is gone to rather than refused: one branch lives in one worktree at a time, so asking for it can only mean the checkout that has it. You are asked before the session starts there. The checkout need not be named the way ecc would have named it — Claude Code's own worktrees turn a `/` into a `+` where ecc turns it into a `-`, and the branch is what is looked up, not the directory.

Where the checkout goes is [`ecc-worktree-directory`](/emacs-claude-code/reference/configuration/#ecc-worktree-directory), `.claude/worktrees` by default — a name relative to the repository, so a worktree of `feat/x` lands at `<repo>/.claude/worktrees/feat-x`. An absolute name is a directory every repository shares, and a checkout lands at `<directory>/<repository>/<branch-slug>`.

Stopping the **last** session working in a worktree offers to undo the checkout there and then -- from `ecc-kill`, the dashboard's `k`, the sidebar's `k`, or the tab's close button. Stopping one of two sessions working in the same checkout offers nothing: that is no reason to take the tree from the other. Buffers still visiting the checkout are counted in the question rather than closed.

**The branch is never deleted with the checkout on its own.** `ecc-remove-worktree` undoes a checkout; the work is on the branch. git refuses a checkout with changes that are not committed, and you are asked before it is forced.

Once the checkout is gone, **the branch is offered as a question of its own** — after `ecc-remove-worktree` and after the offer that follows the last session in a worktree. Yes runs `git branch -d`; a branch whose commits are on no other branch takes a second yes before `-D`. Nothing is asked about a detached checkout, which had no branch, or about a branch another worktree still holds, which git would refuse anyway.

## Handing work to a session in a worktree

Ask, inside a session, for something to be done in a worktree — "cut a worktree and do X there" — and the CLI left to itself runs `git worktree add` and carries on in the same conversation: one session, two checkouts.

With the [Emacs MCP server](/emacs-claude-code/start/installation/) on (`ecc-mcp-enabled`), the model is offered a tool instead, `start_worktree_session`. It names the branch and writes the brief; Emacs makes the checkout, opens it as a Space, starts a session there and sends it that brief. The new session is told which repository it is in, which branch it is on and which session sent it, because it cannot read the conversation it came from. The session that asked reports where the work went and does not do it as well.

**What the new session is told.** The brief is the model's account of the work, and Emacs adds what it watched the same conversation do: the files it touched, by the name the new checkout has for them; the plans it wrote; the path of the recording, to read only if the brief leaves a question open; and the changes that are uncommitted in the repository. That last one matters — the checkout is made from `HEAD`, so uncommitted work is not in it. Commit it first, or say so in the brief.

**The two other ways are turned back.** A model can reach a worktree through the CLI's own `EnterWorktree` or through `git worktree add` in Bash, and both leave one conversation working in two checkouts. When the session has the tool, Emacs refuses those requests with a sentence naming it, and nothing is put in front of you. Nothing is refused in a session without the tool — the MCP server off, or `start_worktree_session` in `ecc-mcp-excluded-tools` — and `ExitWorktree` is never touched. In an `auto` permission mode the CLI does not ask Emacs at all — it runs `git worktree add` and Emacs sees no request (measured against CLI 2.1.272) — so a draft of yours that says *worktree*, in English or Japanese, is sent with one line reminding the model of the tool. In that mode the line is the whole backstop.

A branch another worktree already holds is refused rather than joined — two sessions in one checkout is not what handing work over means — and the model is told to name another one. `M-x` has no command for this; from Lisp it is `ecc-worktree-delegate`.

Under `spaces`, a session started in a worktree opens a Space of its own, under the repository it came from.
