---
title: Your first session
description: Start a session, send a prompt, answer a permission request and read the answer back.
sidebar:
  order: 3
---

This walks through one turn from beginning to end. It assumes ecc is
[installed](/emacs-claude-code/start/installation/) and the `claude` CLI works
in a terminal.

## Start it

Open a file in the project you want to work in, and:

```
M-x ecc-start
```

The session takes the project of the current buffer as its directory, and the
name of that directory as its name. Starting a second session in the same
project asks for a name to tell it from the first. A prefix argument —
`C-u M-x ecc-start` — asks for both the directory and the name.

A session buffer appears with the point already in the prompt region.

## What you are looking at

```
  transcript          read-only, single-letter keys
  ────────────        the divider
  prompt region       what you type; the major mode's keys
  ────────────
  default             the footer: the permission mode in force
```

The **transcript** is read-only text. Because nothing is being typed into it,
single letters are commands there: `n` and `p` walk the headings, `TAB` folds
one, `RET` visits whatever is at point.

The **prompt region** binds only `RET`, `TAB` and keys under `C-c`, so every
letter stays a letter while you write. The placeholder in an empty region is
ghost text, not content: you do not have to delete it.

The **footer** says which permission mode the session is in. `S-TAB` cycles it,
from either region.

## Send something

Type into the prompt region and press `C-c C-c`.

`RET` inserts a newline; the prompt is meant to be written in, edited and
re-read before it goes. If you would rather have the terminal client's
behaviour, set `ecc-chat-return-sends` to `t` and `RET` sends, with `S-RET`
left as the newline.

While you write:

- `/` offers the slash commands the session actually reports having — its
  skills and plugin commands, not a fixed list.
- `@` starts a reference. `@path/to/file` is passed through to the CLI;
  `@region`, `@cursor` and `@diagnostics` are the ones Emacs answers itself,
  expanding into a quote block of the buffer you last worked in before they are
  sent.
- `M-p` and `M-n` walk the prompt history, which is shared by every session.
- `C-c C-q` shows what is queued. Sending while a turn is running does not
  interrupt it: the prompt waits its turn.

The reply is drawn as it arrives. `C-c C-g` interrupts a turn that is going the
wrong way.

## Answer a permission request

Sooner or later the turn stops and asks to use a tool. That is the moment the
client exists for.

**Permission prompts default to deny.** Nothing happens until you say so.

From the prompt region, without moving:

| Key | What it does |
|---|---|
| `C-c C-a` | Allow it |
| `C-c C-d` | Deny it, with a reason you give |

Both act on the request at point, falling back to the oldest one waiting.

With point on the request in the transcript, single letters go further:

| Key | What it does |
|---|---|
| `a` / `d` | Allow once / deny |
| `A` | Allow this and every one like it from now on |
| `u` | Allow everything until the turn ends |
| `r` | Allow by a rule you write, saved to the project settings |
| `e` | Edit what is proposed before allowing it |
| `c` | Comment on it |
| `RET` | Visit what is proposed — the file, the diff, the whole result |

For an Edit or a Write, `RET` shows the change as a diff before you decide.
When you allow it, the buffer visiting that file is reverted for you; a buffer
with unsaved changes is left alone and you are warned rather than overwritten.

### From another buffer entirely

You do not have to be in the session. With `ecc-global-map` bound as the
[installation page suggests](/emacs-claude-code/start/installation/#the-first-configuration),
`C-c c a` allows and `C-c c d` denies the oldest request waiting in any
session, from wherever you happen to be editing. `C-c c n` jumps to the next
session that is waiting, and `C-c c b` opens the dashboard of all of them.

## Read the answer back

The transcript is a tree: a turn holds steps, a step holds the tools it ran.

- `TAB` folds the node at point; `1`–`4` show the tree to that depth, and `+`
  and `-` open or close all of it.
- `n` and `p` move by heading, `M-n` and `M-p` by sibling, `^` to the parent.
- `f` goes to the Files section — every file the session touched — and `d` on a
  row there reviews that file's changes.
- `w` copies what is at point. `isearch` and `occur` work on the whole
  transcript, because it is only text.
- `i` puts you back in the prompt.

When the turn has made several changes, `C-c ?` then `D` (or `C-c c D` from
anywhere) opens **all** of them as one diff: walk the hunks, attach a comment
where something is wrong, and send every comment as a single prompt.

## Finish, or carry on later

`C-c ?` opens the menu, which reaches everything and shows the key for it.

- `k` stops the session and forgets it.
- `h` opens a past conversation from the CLI's own recordings, in an ordinary
  session buffer.
- `r` resumes one.

:::caution[Resuming a live session forks it]
A second process running `--resume` on a session that is still alive forks the
conversation, and the CLI has no lock to stop it. Stop the session before
resuming it. `ecc-history-resume` asks first.
:::

## Where to go next

- [How it works](/emacs-claude-code/explanation/how-it-works/) — what happens
  between the CLI and the buffer.
- [Key binding reference](/emacs-claude-code/reference/key-bindings/) — every
  key, in every buffer ecc opens.
- [Command reference](/emacs-claude-code/reference/commands/) — including the
  commands meant for your source buffers rather than the transcript.
