---
title: Transient menu
description: One menu that reaches every command ecc has, opened with a single key.
sidebar:
  order: 1
---

`C-c ?` in a session opens the menu. It is a
[transient](https://magit.vc/manual/transient/) — the same kind of menu magit
is driven by — and it reaches every command in the package.

![The transient menu open under a session, its six groups: Session, Send, Review, Respond, View and Config](../../../assets/menu.png)

Each line is a key and what it does. Press the key and the command runs; press
`C-g` and the menu goes away. A line beginning with `-` is a switch instead: it
is turned on first and stays on the screen, and the command run after it sees
it.

The menu can also be opened from a buffer that is not a session — `M-x
ecc-menu`, or `?` in [`ecc-global-map`](/emacs-claude-code/reference/key-bindings/#from-any-buffer).
That matters for the Send group, whose commands are meant to be used from your
own source files. A key means the same thing in the menu as it does in the
global map.

:::note[Which session does it act on?]
The menu does not ask, unless it has to. It takes the session of the current
buffer; failing that the one this buffer last talked to, the only session of
this project, the only one on screen, or the most recently used. Only when
none of those settles it are you asked, and the answer is remembered for that
buffer.
:::

## Session

Ten commands: starting a conversation, picking one up again, and moving the
window around.

### `c` — Start

Starts a session in the project of the current buffer, named after that
directory. A second session in the same project asks for a name to tell it
from the first.

`C-u c` asks for both the directory and the name.

`ecc-start` is autoloaded, so `M-x ecc-start` works before ecc has been loaded.

### `r` — Resume

Opens a submenu with the list of everything there is to pick up again.

![The resume picker: five conversations, each with an icon for its state](../../../assets/resume.png)

The icon at the head of each line is the point of the list — it says what the
conversation *is* before you read its name:

| Icon | What it is |
|---|---|
| ▶ | A session this Emacs is running right now |
| ● | A session this Emacs holds whose process has stopped |
| ◉ | A conversation another process is running — a terminal, another Emacs |
| ↺ | A conversation that is only a recording |

After the name come when it was last worked in and, for a recording, the
prompt it opened with. The sessions of this Emacs come first, then the
recordings of this project, most recently used first; when the project has
none, every recording is offered.

The `-f` switch in the submenu forks: instead of carrying the conversation on,
it branches a new one from it.

:::caution[Resuming a live session forks it]
Two processes resuming the same session id write into the same recording, and
the conversation quietly grows a second branch — the CLI has no lock to stop
it. That is what the ◉ icon is warning about. Resuming one asks first.
:::

### `k` — Kill

Stops the session and forgets it: the process is stopped, the session leaves
the model, and its buffers are killed. The recording stays on disk, so `r`
still finds the conversation afterwards.

### `R` — Rename

Renames the session and its buffers with it. The name is what the tab line,
the mode line and every picker show, so this is how two sessions in one
project stop being "the other one".

### `v` — Go to the prompt

Brings the session's window back and puts the point in the prompt region,
ready to type. It is the way back from wherever you have wandered to.

### `w` — Hide or restore windows

Hides the session windows of this project, or brings the hidden ones back if
they are already hidden. `C-u w` does it for every project rather than this
one.

The transcript is not closed, only put away: the session goes on running and
answering while it is out of sight.

### `S` — Switch this window to another session

Shows another session in this window — the same choice clicking its tab would
make, for when the tabs are not to hand.

![Switching the window from one session to another and back](../../../assets/switch.gif)

The window that changes is the one you are in when it is one of ecc's;
otherwise it is the main session window, so running this from your source code
changes the transcript you were looking at.

### `i` — Interrupt

Interrupts the turn that is running. What has already been done stays done;
the model stops where it is and the session goes back to waiting for you.

### `t` — Hand over to the terminal

Carries the conversation on in the real terminal client, which can do things
this one cannot.

It is a change of hands, not a second window: the turn in flight is
interrupted and the process Emacs runs is stopped *before* the terminal
resumes the same conversation. That order is the whole point — two processes
on one session would fork the recording. The transcript in Emacs follows along
while the terminal has it.

### `u` — Take it back

Takes the session back from the terminal and runs it headless in Emacs again.
Whatever the terminal added is read first, so the transcript misses nothing.

A terminal that is still running keeps the session: taking it back then would
branch the conversation, so the hand-off is left alone and the session returns
on its own once the terminal is really gone.
