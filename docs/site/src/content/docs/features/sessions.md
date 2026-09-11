---
title: Session management
description: Starting, resuming, switching between and handing over the sessions this Emacs runs.
sidebar:
  order: 2
---

A session is one `claude` process, the buffer its conversation is drawn in, and the
name the two go by. Emacs runs as many at once as you start. The first session of a
project is named after the project directory; the second asks for a name.

Killing a session buffer stops the CLI and forgets the session. The recording on disk
stays, so the conversation can still be picked up again.

## Picking a conversation up again

`r` on the [menu](/emacs-claude-code/features/menu/#r--resume), or `M-x ecc-resume-menu`,
lists what can be picked up again: the sessions of this Emacs, then the conversations
recorded under the current project, most recently worked in first.

![The resume picker, listing five conversations, each with an icon for its state](../../../assets/resume.png)

| Icon | State |
|---|---|
| ▶ | A session this Emacs is running |
| ● | A session this Emacs holds whose process has stopped |
| ◉ | A conversation another process is running |
| ↺ | A conversation that is only a recording |

Then the name, when it was last worked in, and the directory or, for a recording, its
first prompt. The `-f` switch branches a new conversation from the one picked instead of
continuing it.

:::caution[Resuming a live conversation forks it]
Two processes on one session id write into the same recording, and the CLI has no lock
against it. That is what ◉ marks; ecc asks before resuming one.
:::

The recording is the CLI's own, under
`~/.claude/projects/<directory>/<session-id>.jsonl`, so a conversation held in the
terminal is on the list too. It is a tree rather than a list: editing a message,
interrupting a turn and resuming twice each grow a branch. Only the branches hanging off
the line being read are folded away — `/compact` starts a new root, and is kept.

`h` (`ecc-history-open`) opens a recording in an ordinary session buffer without starting
anything. It reads like a live one, and `r` from there resumes it.

A session whose CLI stops without being asked to offers to resume itself. The offer is
made rather than acted on: an exit nobody asked for is worth a look first. An Emacs that
wants neither the question nor the offer takes `ecc--offer-resume` off
`ecc-session-exited-hook`.

## The dashboard

`b` on the menu, `C-c c b`, or `M-x ecc-dashboard`.

![The dashboard listing four sessions: one waiting for an answer, one running, one idle and one that has exited](../../../assets/dashboard.png)

It lists the sessions **this Emacs runs**, and only those. The list is read from the
model rather than from disk, so it is current as it is drawn and there is nothing to
poll. A session another process runs cannot be answered or steered from here, and a
conversation that is only a recording is not running at all; both are reached through
`r` and `h` above.

| Column | What it says |
|---|---|
| Name | The session name, as the tabs and the mode line use it |
| State | What it is doing, and whether it wants an answer |
| Project | The last component of its directory; the whole path is in the tooltip |
| Model | The model the CLI reported |
| Last prompt | What was asked in the most recent turn |
| Updated | When it last answered |
| Cost | What the conversation has cost so far |

The sessions waiting for an answer come first, then the rest by when they were last
active. A row doing nothing has its detail dimmed, and a working row turns a spinner in
its State cell. The gutter carries `!` for a session waiting on you and `▶` for one that
is on the screen.

The header line sums the list up: how many are waiting, running and idle, what they have
cost together, and the rate limit they are closest to. Nobody is asked for that limit —
it is the highest of what the CLI has already told these sessions.

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

`k` stops a session and leaves its recording, so `r` still finds the conversation. `D`
deletes that recording, and asks for a whole `yes` first. What `a` and `d` send is on
[Prompt and transcript](/emacs-claude-code/features/prompt/).

## The tab line

Every session is a tab in the tab line of a session window, whichever session that
window is showing.

![A session window whose tab line carries four tabs, each coloured by what its session is doing](../../../assets/tabs.png)

The tabs are `tab-line-mode` itself — the look, the scrolling and the click are its —
and only what a tab says and its colour are ecc's.

| Mark | State | Colour |
|---|---|---|
| `⚠` | Waiting for an answer | The colour a waiting request is drawn in, blinking |
| `▶` | Working | Green |
| `✗` | The process has stopped | Red |
| none | Nothing to do | Dimmed |

The tab of the session the window is showing is bold and underlined. A working session
the window is **not** showing takes a quieter green than one it is, so that brightness
means the tab in front of you rather than a busy session somewhere else.

A tab waiting for an answer blinks, in step with the blinking line of the request it
stands for. `ecc-tab-blink` turns that off.

The tabs are in the order the sessions were started, not the order they were last used,
so they stay where they are while you work. `mouse-1` shows that session in the window
the tab was clicked in; `S` on the menu and `C-c C-t` in a session are the same choice
from the keyboard. See
[Switch this window to another session](/emacs-claude-code/features/menu/#s--switch-this-window-to-another-session).

The `x` on a tab **stops the session**, which is not the cheap, undoable thing closing a
tab is elsewhere in Emacs, so it asks first. `ecc-tab-close-confirm` is what asks.

Setting `tab-bar-tab-name-function` to `ecc-tab-bar-tab-name` and `ecc-tab-bar-state` to
`t` marks the tab bar with the same `⚠` and `▶`, so a tab holding a session that wants
something says so while you are in another one.

## Knowing which session wants something

A session can stop for a permission while you are reading code somewhere else. Three
things say so.

- **The mode line of every buffer** carries `⚠ecc:N` while requests are waiting, N being
  how many there are across every session. `mouse-1` on it opens the dashboard.
- **An announcement** when a turn finishes, a request arrives, or a session stops on its
  own. `ecc-notify-level` decides how loud: `message` writes a line in the echo area,
  `pulse` flashes the transcript as well, `desktop` also asks the desktop to show a
  notification, and nil says nothing. `ecc-notify-events` picks which of the three events
  are announced, `ecc-notify-suppress-when-focused` holds a desktop notification back
  while Emacs has the focus, and `ecc-notify-sound` names a sound for it.
- **The tabs**, above.

`n` and `N` go to the next request waiting — across every session, or only the sessions
of this project — in the order the requests arrived, wrapping around. Both work from any
buffer through [`ecc-global-map`](/emacs-claude-code/reference/key-bindings/#from-any-buffer),
as do `a`, `d` and `1`–`4`, which answer without going to the session at all.

The mode line count, the announcements and the tab line are turned on by every session,
and there is no setting to leave one of them off: each is what makes a session visible,
and a session that started without them looked broken.

Every setting named here is on the
[configuration reference](/emacs-claude-code/reference/configuration/), and answering a
request is on [Prompt and transcript](/emacs-claude-code/features/prompt/).
