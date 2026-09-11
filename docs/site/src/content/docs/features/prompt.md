---
title: Prompt and transcript
description: What the two regions of a session buffer can do.
sidebar:
  order: 3
---

A session buffer holds the transcript at the top and, under a divider, the prompt you
type in; under that comes a footer. The transcript is read-only text carrying a keymap of
its own as a text property, so single letters act on it. The prompt has no such property
and obeys the mode map, which binds only `RET`, `TAB`, movement keys and keys under
`C-c C-`, so a letter stays a letter.

## The prompt region

### Writing and sending

| Key | Action |
|---|---|
| `RET` | A newline — or send, when `ecc-chat-return-sends` is on |
| `S-RET`, `C-j` | A newline |
| `C-c C-c` | Send |
| `C-c C-k` | Empty the region |
| `C-k` | Kill the visual line, stopping at the end of the region |
| `C-a` / `C-e` | The ends of the visual line |
| `TAB` | Complete a slash command or an `@` reference |
| `/` | Insert a slash, and offer the commands when it opens the prompt |

### Saying it again

| Key | Action |
|---|---|
| `M-p` / `M-n`, `C-<up>` / `C-<down>` | The previous or next prompt from the history |
| `C-c C-r` | Send the last prompt again |
| `C-c C-s` | Accept the prompt the CLI suggested |

The history is one list shared by every session, so a prompt typed in one is there in
the next.

### Under the prefix

| Key | Action |
|---|---|
| `C-c C-q` | Show what is queued |
| `C-c C-g` | Interrupt the running turn |
| `C-c C-x` | Attach or detach the editor's context |
| `C-c C-i` | Insert an image |
| `C-c C-a` / `C-c C-d` | Allow or deny the request waiting |
| `C-c C-n` / `C-c C-p` | Next or previous turn |
| `C-c C-b` | Show the side questions |
| `C-c C-t` | Show another session in this window |
| `C-c C-e` | Export the conversation as Markdown |
| `S-TAB` | Cycle the permission mode |
| `C-c ?` | Open the menu |

`C-c C-a` and `C-c C-d` answer without leaving the prompt: the request at point if there
is one, else the oldest of this session, else the oldest anywhere.

### `@` references

`@` in a prompt names something for Claude to read. `TAB` completes them — the three
below, and the files of the project.

| Reference | What is sent |
|---|---|
| `@region` | The region, quoted |
| `@cursor` | The line the cursor is on, with its neighbours |
| `@diagnostics` | The diagnostics of that file |
| `@path:10-40` | Those lines of that file |
| `@path` | Left as it is, for the CLI to resolve |

Emacs expands the first four before sending: the reference is replaced by a short label
and what it stands for is appended as one quoted block under a rule, two references to
the same thing sharing one block. The echo area names what was attached, and says when a
`@region` had no region to send and went as it stands.

The region, the cursor and the diagnostics are read from the buffer you last worked in,
which is not the session buffer you are typing in.

### Slash commands

![The slash command list open over a session, each command with the description the CLI gave it](../../../assets/slash.png)

A `/` that opens the prompt offers the list; `TAB` completes one wherever it stands. The
description beside each is the CLI's own.

`/model`, `/effort`, `/permissions`, `/config` and `/btw` are asked for their argument
first, because the CLI answers them bare with a usage message. Commands only the terminal
client can run are left out of the list, and still sent if you type one out.

`/btw` never reaches the conversation: it is caught in Emacs and asked beside the turn
that is running, which is what `C-c C-b` shows.

### While a turn runs

A prompt sent while Claude is working is queued rather than interrupting it, and the echo
area says at what position. `C-c C-q` lists the queue. A turn somebody started from
Remote Control queues it the same way, and says which it was.

### Images and the editor context

An image pasted, dropped on the buffer or inserted with `C-c C-i` is written under
`ecc-image-dir` and referenced by its path, so the CLI reads it from disk.
`ecc-image-cleanup` decides whether a session's images go with it.

`C-c C-x` turns the editor's context on or off for this buffer: with it on, what you are
looking at goes with every prompt.

### The footer

Under the region stand a rule, the permission mode on the left and the model on the
right. `S-TAB` walks through `default`, `acceptEdits`, `plan` and `auto` —
`bypassPermissions` is left out, since a key pressed by mistake should not turn it on;
`ecc-set-permission-mode` still reaches it. An empty region shows a placeholder, which is
drawn over the buffer rather than written into it.

## The transcript

![The transcript folding: everything collapsed, then opened a level at a time, then one node folded and unfolded with TAB](../../../assets/fold.gif)

It is ordinary read-only buffer text, so `isearch`, `occur`, narrowing and `M-w` work on
it as they do anywhere else.

### Folding

| Key | Action |
|---|---|
| `TAB` | Fold or unfold the node at point |
| `1`–`4` | Show the tree to that depth |
| `+` / `-` | Expand or collapse everything |

### Moving

| Key | Action |
|---|---|
| `n` / `p` | Next or previous heading |
| `M-n` / `M-p` | Next or previous sibling at the same depth |
| `^` | Up to the parent heading |
| `]` / `[` | Next or previous block |
| `T` | Pick a turn by its prompt |
| `f` / `P` | The Files section, the Plan section |
| `SPC` / `DEL` | Scroll |
| `i` | Go to the prompt |

### Acting on what is at point

| Key | Action |
|---|---|
| `RET` | Visit it — the file, the agent transcript, the whole result |
| `w` | Copy the code block at point, or the whole reply |
| `a` | Allow the request waiting |
| `d` | Deny the request at point, or open the diff when not on one |
| `g` | Draw it again |
| `L` | The raw protocol log |
| `t` / `R` | Hand over to the terminal, resume |
| `C-c C-k` | Interrupt the running turn |
| `S-TAB` | Cycle the permission mode |
| `q` | Bury the buffer |
| `?` | Open the menu |

### On a node waiting for an answer

A node that is waiting carries a keymap of its own, in force with point inside it.

| Key | Action |
|---|---|
| `RET` | Visit what is proposed |
| `a` / `d` | Allow it once, deny it |
| `A` | Allow it, and every one like it from now on |
| `u` | Allow everything until the turn ends |
| `r` | Allow by a rule — a pattern you give, saved to the project settings |
| `c` / `e` | Comment on the proposal, or edit it before allowing it |

These are keys the transcript leaves free; none of them gives an existing key a new
meaning. Point is what selects the map, and point is easy to misjudge, so a letter that
meant one thing a line earlier would fire the wrong command with no warning. `c` and `e`
are on [Review](/emacs-claude-code/features/review/).

### On a file in the Files section

`RET` visits the file and `d` reviews its changes. `TAB` still folds and `SPC` still
scrolls.

Everything reached from outside this buffer is on the
[menu](/emacs-claude-code/features/menu/).
