---
title: Transient menu
description: The menu opened with C-c ?, and the commands in its Session group.
sidebar:
  order: 1
---

`C-c ?` opens the menu. It is a
[transient](https://magit.vc/manual/transient/), the kind of menu magit uses,
and it lists every command in ecc.

![The transient menu open under a session, showing its six groups: Session, Send, Review, Respond, View and Config](../../../assets/menu.png)

Each line is a key and the command it runs; `C-g` closes the menu. A line
starting with `-` is a switch, which applies to the command run after it.

Outside a session buffer the menu is `M-x ecc-menu`, or `?` in
[`ecc-global-map`](/emacs-claude-code/reference/key-bindings/#from-any-buffer).
A key means the same in both.

:::note[Which session the menu acts on]
The session of the current buffer, or else the only session of this project,
the only one on screen, or the most recently used. It asks only when none of
those settles it, and remembers the answer for that buffer.
:::

## Session

### `c` — Start

Starts a session in the project of the current buffer, named after that
directory. A second session in the same project asks for a name; `C-u c` asks
for the directory too.

### `r` — Resume

Lists the conversations that can be picked up again.

![The resume picker, listing five conversations, each with an icon for its state](../../../assets/resume.png)

| Icon | State |
|---|---|
| ▶ | A session this Emacs is running |
| ● | A session this Emacs holds whose process has stopped |
| ◉ | A conversation another process is running |
| ↺ | A conversation that is only a recording |

Then the name, when it was last worked in, and the directory or, for a
recording, its first prompt. The `-f` switch branches a new conversation from
the one picked instead of continuing it.

:::caution[Resuming a live session branches the conversation]
Two processes on one session id write into the same recording, and the CLI has
no lock against it. That is what ◉ marks; ecc asks before resuming one.
:::

### `k` — Kill

Stops the process and kills the session's buffers. The recording stays on
disk, so `r` still lists the conversation.

### `R` — Rename

Renames the session and its buffers. The name is what the tabs, the mode line
and the pickers show.

### `v` — Go to the prompt

Shows the session's window and puts point in the prompt region.

### `w` — Hide or restore windows

Hides the session windows of this project, or shows them again. `C-u w`
applies to every project. A hidden session goes on running.

### `S` — Switch this window to another session

A session window carries a tab per session. `S` changes which one the window
shows, in place.

![The session window changing from one session to another: the selected tab moves from greet to notes and the transcript is replaced](../../../assets/switch.gif)

In a session buffer, `C-c C-t` is the same command.

### `i` — Interrupt

Interrupts the running turn. What is already done is kept.

### `t` — Hand over to the terminal

Continues the conversation in [ghostel](https://github.com/dakra/ghostel),
which draws the CLI's own interface in an Emacs buffer.

![A session handed over: the CLI's own interface takes the window, with the conversation resumed](../../../assets/handover.gif)

The turn is interrupted and the process Emacs started is stopped before the
terminal resumes the conversation, because two processes would branch the
recording. The transcript follows the terminal while it has the session.

### `u` — Take it back

Reads what the terminal added, then resumes the session headless in Emacs. If
the terminal is still running the session stays with it, and comes back when
the terminal exits.

## Send

These are meant to be used from your own source buffers, not from the
transcript. Each sends to the session the menu resolves to and says in the echo
area which one it went to; while a turn is running the prompt is queued rather
than interrupting it.

### `s` `x` `g` `f` — Sending from a buffer

| Key | Sends |
|---|---|
| `s` | A line typed in the minibuffer, and nothing else |
| `x` | That line, and where you are: the file and the line |
| `g` | The region, quoted, or the whole buffer when nothing is marked |
| `f` | The file itself, as an `@path` reference the CLI reads |

![Sending the region: the marked code and the question arrive in the transcript, and the answer streams back](../../../assets/send-region.gif)

What `x` and `g` append is a block you can read before it goes:

````
---
Current context: hello.py L1-L3
```python
def greet(name):
    return "hello " + name
```
````

A prefix argument asks for an instruction to put before the code (`C-u g`), or,
for `s`, which session to send to. `f` offers to save the buffer first, because
the CLI reads the file from disk.

### `e` — Fix the error at point

Sends the diagnostics on the current line with the few lines of code around
them. flymake is asked first, then flycheck, then the help text of whatever
overlay is at point.

![The checker marks a line, the diagnostic is sent, and the fix comes back as an edit waiting to be allowed](../../../assets/fix-error.gif)

### `l` — Ask inline

Asks about the region, or the file, and puts the answer in an overlay above
point rather than in the transcript. `n` and `p` scroll it, `r` asks something
else, `q` takes it away.

![A question typed in the minibuffer, and the answer appearing in an overlay over the code](../../../assets/inline.gif)

The question goes to a session of its own: a fork of the project's session, or
a fresh light one. Which of the two is asked once and remembered for that
buffer.

### `W` — Rewrite the region

Rewrites the marked code as an instruction says. The answer is shown where the
code is, and nothing is written until it is accepted.

![The rewritten code shown above the original, then accepted with RET and written into the buffer](../../../assets/rewrite.gif)

It is one shot with no tools: the CLI is asked for the code and for nothing
else, and Emacs is what touches the buffer.
