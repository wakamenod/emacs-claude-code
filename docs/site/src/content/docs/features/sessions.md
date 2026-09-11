---
title: Session management
description: Starting, resuming, switching between and handing over the sessions this Emacs runs.
sidebar:
  order: 2
---

A session is one `claude` process, the buffer it is drawn in, and the name both go by.
The first session of a project is named after its directory; the second asks for a name.
Killing a session buffer stops the CLI, and the recording stays on disk.

## Picking a conversation up again

`r` on the [menu](/emacs-claude-code/features/menu/#r--resume), or `M-x ecc-resume-menu`:
the sessions of this Emacs first, then the conversations recorded under this project,
most recently worked in first.

![The resume picker, listing five conversations, each with an icon for its state](../../../assets/resume.png)

| Icon | State |
|---|---|
| ▶ | A session this Emacs is running |
| ● | A session this Emacs holds whose process has stopped |
| ◉ | A conversation another process is running |
| ↺ | A conversation that is only a recording |

Then the name, when it was last worked in, and the directory or, for a recording, its
first prompt. `-f` branches a new conversation instead of continuing the one picked.

:::caution[Resuming a live conversation forks it]
Two processes on one session id write into the same recording, and the CLI has no lock
against it. That is what ◉ marks; ecc asks before resuming one.
:::

The recordings are the CLI's own, under `~/.claude/projects`, so conversations held in
the terminal are listed too. Each is a tree: editing, interrupting and resuming grow
branches, and only the branches off the line being read are folded away — `/compact`
starts a new root and is kept.

`h` opens a recording without starting anything, and `r` from there resumes it. A session
whose CLI stops unasked offers to resume itself; the offer is made rather than acted on.

## The dashboard

`b` on the menu, `C-c c b`, or `M-x ecc-dashboard`.

![The dashboard listing four sessions: one waiting for an answer, one running, one idle and one that has exited](../../../assets/dashboard.png)

The sessions this Emacs runs, and only those. It is read from the model, so there is
nothing to poll; a session another process runs, or one that is only a recording, is
reached through `r` and `h` instead.

| Column | What it says |
|---|---|
| Name | The session name, as the tabs and the mode line use it |
| State | What it is doing, and whether it wants an answer |
| Project | The last component of its directory; the whole path is in the tooltip |
| Model | The model the CLI reported |
| Last prompt | What was asked in the most recent turn |
| Updated | When it last answered |
| Cost | What the conversation has cost so far |

Waiting sessions come first, then the rest by when they last answered. The gutter marks
`!` for one waiting on you and `▶` for one on the screen, and an idle row is dimmed. The
header line counts the states, adds the costs up and draws the rate limit the sessions
are closest to — from what the CLI has already told them, not by asking.

| Key | Action |
|---|---|
| `RET` | Go to that session |
| `+` | Start a session |
| `k` | Stop the session and forget it |
| `D` | Delete its recording from disk |
| `r` | Rename it |
| `R` | Resume it |
| `a` / `d` | Allow or deny the oldest request it is waiting on |
| `C` | What that session can do |
| `U` | Usage |
| `g` | Draw it again |

`k` leaves the recording, so `r` still finds the conversation; `D` is what deletes it.
What `a` and `d` send is on
[Prompt and transcript](/emacs-claude-code/features/prompt/).

## The tab line

Every session is a tab in the tab line of a session window.

![A session window whose tab line carries four tabs, each coloured by what its session is doing](../../../assets/tabs.png)

| Mark | State | Colour |
|---|---|---|
| `⚠` | Waiting for an answer | The colour a waiting request is drawn in, blinking |
| `▶` | Working | Green |
| `✗` | The process has stopped | Red |
| none | Nothing to do | Dimmed |

The tab the window is showing is bold and underlined, and a working session it is *not*
showing takes a quieter green. `ecc-tab-blink` turns the blinking off.

Tabs stand in the order the sessions were started, so they do not move about while you
work. `mouse-1` shows that session in the window the tab was clicked in, as `S` does from
the keyboard. The `x` stops the session, and asks first.

`ecc-tab-bar-state` marks the tab bar with the same `⚠` and `▶`, once
`tab-bar-tab-name-function` is `ecc-tab-bar-tab-name`.

Under the tabs, the header line says what the session is doing on the left and, on the
right, how much of its context window is left before the CLI compacts it. It goes amber
and then red as it runs out.

## Knowing which session wants something

- `⚠ecc:N` in every mode line, N being how many requests wait across every session.
  `mouse-1` on it opens the dashboard.
- An announcement when a turn finishes, a request arrives or a session stops on its own.
  `ecc-notify-level` is `message`, `pulse`, `desktop` or nil, and `ecc-notify-events`
  picks which of the three events are announced.
- The tabs, above.

`n` and `N` go to the next request waiting, across every session or only this project's.
Both work from any buffer through `ecc-global-map`, as do `a`, `d` and `1`–`4`.

All three are turned on by every session and there is no setting to leave one off: a
session that started without them looked broken.

Every setting named here is on the
[configuration reference](/emacs-claude-code/reference/configuration/).
