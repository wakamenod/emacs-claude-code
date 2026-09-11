---
title: How it works
description: The path from a line of stream-json to the text on screen, and the boundaries that keep it one path.
sidebar:
  order: 1
---

ecc is one path, walked in one direction: a line arrives from the CLI, becomes
an alist, updates a model, and the model announces the change to whoever is
drawing. Nothing calls back upwards by name.

```
claude -p --output-format stream-json
        │
        │  one JSON object per line, on a pipe
        ▼
  ecc-proc        starts the CLI, splits stdout into lines, writes JSON back
        │
        ▼
  ecc-protocol    one line in, an alist out
        │
        ▼
  ecc-dispatch    a table on type and subtype; updates the model
        │
        ▼
  ecc-model       the session, the Turn > Step > Tool tree, the pending queue
        │
        │  hooks: node added, turn finished, request added, …
        ▼
  ecc-render      draws it, with text properties and overlays
  ecc-chat        the major mode, the keymaps, the movement
```

## The process end

`ecc-proc` builds the command line and starts the CLI. The invariant part of it
is:

```
claude -p --input-format stream-json --output-format stream-json \
       --verbose --permission-prompt-tool stdio
```

with `:connection-type 'pipe`. stream-json needs all of it: `--verbose` to get
the full stream, and `--permission-prompt-tool stdio` so that a tool asking for
permission comes back on the same channel rather than opening a dialog
somewhere ecc cannot see. Everything else on the command line is conditional —
a session that was given a model passes `--model`, one that was given a
permission mode passes `--permission-mode`, and so on.

Parsed messages leave `ecc-proc` through `ecc-proc-message-function`, which
`ecc-dispatch` sets. That indirection is the rule the layering rests on: the
process layer never names the layer above it.

## JSON stops here

`ecc-protocol` and `ecc-proc` are the only modules allowed to touch JSON. (The
two that speak to a process of their own, `ecc-mcp` and `ecc-inline`, are the
exceptions that prove it.) Everywhere else works on Emacs data structures.

The serialisation conventions are worth knowing if you ever read that code:
arrays are vectors, `nil` serialises as `{}`, `null` is `:null` and false is
`:false`.

The message shapes are the ones recorded from a real CLI, and they are kept in
`test/fixtures` as jsonl. The whole test suite replays those fixtures, so
`make test` needs no network, no API key and no `claude` binary.

## Nothing is dropped

`ecc-dispatch` is a table on the type and subtype of a parsed message. A
message it does not know, and any error raised while handling one, ends up **in
the transcript as an `unknown` node** and in the session's log buffer. An error
is never swallowed: a stream that has changed under you shows up as something
odd on screen rather than as a silence.

Every session has a log buffer, `*ecc-log: <name>*`, holding the raw lines in
both directions with a timestamp — `<<` for what came in, `>>` for what went
out. `L` in a transcript opens it. When something looks wrong, that buffer is
the first place to look, and it is what a bug report should carry.

## The model knows nothing about the screen

`ecc-model` holds the session, the Turn > Step > Tool tree and the queue of
requests waiting for an answer. It knows nothing of JSON, of processes or of
how any of it is drawn. It stores what `ecc-dispatch` hands it and announces
every change through hooks: `ecc-node-added-hook`, `ecc-node-updated-hook`,
`ecc-turn-started-hook`, `ecc-turn-finished-hook`, `ecc-request-added-hook`,
`ecc-stream-delta-hook` and a dozen more.

Those hooks are the whole interface between the model and the rest of the
package. The renderer listens on them; so do the notifications, the mode line,
the dashboard and the file syncing. It is also where your own code goes if you
want to hang something off a session — they are ordinary hooks, called with the
session and the thing that changed.

## Drawing

`ecc-render` draws the model into the buffer. The transcript and the prompt
share one buffer, so the tree is made of text properties and overlays rather
than of a section library:

- `ecc-node` (the id), `ecc-depth` and `ecc-heading` mark what each piece of
  text is;
- folding is an overlay with `invisible` over a body;
- the transcript's single-letter keys arrive through a `keymap` text property,
  which is why the major mode's keymap stays free for typing in the prompt.

The layout, top to bottom: the button that pages a recording in, the finished
turns, a live region holding the current turn, the Files and Tasks summaries,
the state line, the divider, and the prompt region.

Two rules keep the cost flat:

- **Finished turns are never touched again.** A redraw deletes the live region
  and builds it anew, so the work is proportional to the current turn, not to
  the length of the conversation.
- **No redraw deletes past `ecc-render--prompt-start`.** Your draft survives
  whatever the session does while you are writing it.

Streamed text is not redrawn at all: each delta is appended at a marker kept at
the end of its node, thinned by `ecc-stream-throttle`.

Font lock is off in a session buffer. Faces are put on at insertion time, which
is what makes a long transcript cheap to scroll.

## Where a session lives

Two different directories, for two different questions.

**`~/.claude/sessions/<pid>.json`** — every running Claude Code writes a small
JSON file about itself here and deletes it when it stops. `ecc-registry` reads
that directory, which is how Emacs learns about sessions it did not start: one
in a terminal, in another Emacs, or running headless. It is also how
`ecc-history-resume` knows a session is still alive before it resumes it.
`claude agents --json` reports the same thing, but as a subprocess that costs a
fifth of a second and has to be polled; the files cost nothing and carry more.

**`~/.claude/projects/<cwd>/<session-id>.jsonl`** — the recording, one JSON
object per line, written by the CLI. `ecc-history` reads it back into the same
model a live session uses, which is why a past conversation opens in an
ordinary session buffer. It is read from the end: opening one costs the last
few turns, and a button at the top pages in the ones before that.

A recording is a **tree, not a list**. Editing a message, interrupting a turn
and resuming twice all grow branches. `ecc-history-abandoned` folds away the
branches hanging off the current line — but not a `/compact`, which starts a
new root and is never abandoned.

:::caution[There is no lock on a session]
Two processes resuming the same session id write into the same recording, and
the conversation quietly grows a second branch. This is why `ecc-tui-open` is a
hand-off and not a second window: the process Emacs runs is interrupted and
stopped before the terminal is given the session. And it is why
`ecc-history-resume` asks before resuming something that is still alive.
:::

## The layout of the source

If you want to read it, this is the order it is built in:

| File | What it is |
|---|---|
| `ecc.el` | The entry points — `ecc-start`, `ecc-resume`, `ecc-kill` |
| `ecc-core.el` | The customization group, the launch options, the log buffers. Depends on no other `ecc-` module |
| `ecc-protocol.el`, `ecc-proc.el` | The wire: one line in, an alist out, and the JSON sent back |
| `ecc-model.el` | The session, the tree, the queue, the hooks |
| `ecc-render.el`, `ecc-chat.el` | What is drawn, and the mode that holds the keymaps |
| `ecc-perm.el`, `ecc-review.el`, `ecc-plan.el`, `ecc-history.el`, `ecc-mcp.el`, `ecc-tui.el`, … | One feature per file |
| `ecc-transient.el` | The menu |

There is one `test/ecc-<module>-test.el` per module. New behaviour gets a test
of its own, and the fixtures are recorded from the real CLI rather than written
by hand.
