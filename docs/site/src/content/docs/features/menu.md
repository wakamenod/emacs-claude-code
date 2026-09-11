---
title: Transient menu
description: The menu opened with C-c ?, and the commands in its Session group.
sidebar:
  order: 1
---

`C-c ?` opens the menu in a session buffer. It is a
[transient](https://magit.vc/manual/transient/), the kind of menu magit uses,
and it lists every command in ecc.

![The transient menu open under a session, showing its six groups: Session, Send, Review, Respond, View and Config](../../../assets/menu.png)

Each line shows a key and the command it runs. Pressing the key runs the
command and closes the menu; `C-g` closes it without running anything. A line
that starts with `-` is a switch: it is toggled on, stays on screen, and
applies to the command run after it.

From a buffer that is not a session, the menu is `M-x ecc-menu`, or `?` in
[`ecc-global-map`](/emacs-claude-code/reference/key-bindings/#from-any-buffer).
The Send group is meant to be used that way, from a source file. A key means
the same in the menu as it does in the global map.

:::note[Which session the menu acts on]
The session of the current buffer. Failing that, in order: the session this
buffer last talked to, the only session of this project, the only session on
screen, the most recently used session. If none of those applies, the menu
asks, and remembers the answer for that buffer.
:::

## Session

Ten commands: starting a conversation, picking one up again, and moving the
window.

### `c` — Start

Starts a session in the project of the current buffer, named after that
directory. Starting a second session in the same project asks for a name.

`C-u c` asks for the directory and the name.

`ecc-start` is autoloaded, so `M-x ecc-start` works before ecc is loaded.

### `r` — Resume

Opens a submenu listing the conversations that can be picked up again.

![The resume picker, listing five conversations, each with an icon for its state](../../../assets/resume.png)

Each line begins with an icon for the state of the conversation:

| Icon | State |
|---|---|
| ▶ | A session this Emacs is running |
| ● | A session this Emacs holds whose process has stopped |
| ◉ | A conversation another process is running — a terminal, another Emacs |
| ↺ | A conversation that is only a recording |

After the icon come the name, when it was last worked in, and the working
directory or, for a recording, the prompt it opened with. The sessions of this
Emacs are listed first, then the recordings of the current project, most
recently used first. When the project has no recordings, every recording is
listed.

The `-f` switch forks: a new conversation branches from the one picked instead
of continuing it.

:::caution[Resuming a live session branches the conversation]
Two processes resuming the same session id write into the same recording, and
the conversation grows a second branch. The CLI has no lock against this. The
◉ icon marks the conversations it applies to, and ecc asks before resuming
one.
:::

### `k` — Kill

Stops the process, removes the session from the model, and kills its buffers.
The recording is left on disk, so `r` still lists the conversation.

### `R` — Rename

Renames the session and its buffers. The name is what the tab line, the mode
line and the session pickers show.

### `v` — Go to the prompt

Shows the session's window and moves point to the prompt region.

### `w` — Hide or restore windows

Hides the session windows of the current project, or shows them again if they
are already hidden. `C-u w` applies to every project. A hidden session goes on
running.

### `S` — Switch this window to another session

Shows another session in the current window. It is the same choice as clicking
that session's tab.

![A window being switched from one session to another](../../../assets/switch.gif)

The window it changes is the current one when that belongs to ecc, and the
main session window otherwise.

### `i` — Interrupt

Interrupts the running turn. What has already been done is kept.

### `t` — Hand over to the terminal

Continues the conversation in the terminal client.

The running turn is interrupted and the process Emacs started is stopped
before the terminal resumes the conversation, because two processes on one
session would branch the recording. While the terminal has the session, the
transcript in Emacs follows it.

### `u` — Take it back

Reads what the terminal added, then resumes the session headless in Emacs.

If the terminal is still running, the session stays with it: resuming it now
would branch the conversation. The hand-off is left in place, and the session
comes back when the terminal exits.
