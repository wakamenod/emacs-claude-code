---
title: What ecc is
description: An Emacs client that runs the Claude Code CLI headless and draws the conversation as ordinary buffer text.
sidebar:
  order: 1
---

ecc runs `claude` headless, talks to it over pipes in its stream-json protocol,
and draws the conversation into an ordinary Emacs buffer. There is no terminal
emulator anywhere in it.

That one decision is what the rest of the package follows from, so it is worth
being plain about what it buys and what it costs.

## The transcript is text

What the renderer puts in the buffer is text with faces on it. Nothing is a
widget and nothing is an image of a conversation, so everything Emacs already
does to text works here without ecc having to offer it:

- `isearch` and `occur` over the whole conversation;
- narrowing to a turn;
- copying a code block out with `M-w`, and getting exactly what the model wrote;
- `ecc-session-export-markdown` when you want the whole thing as a file.

The structure is carried by text properties rather than by a section library:
each heading line knows which node it belongs to and how deep it is, folding is
an overlay with `invisible` over the body, and the transcript's single-letter
keys arrive through a `keymap` property on that text. Font lock is off in a
session buffer — faces are applied as the text is inserted, so a long
conversation costs nothing to keep on screen.

## One buffer, two regions

A session buffer holds the transcript at the top and, under a divider, the
prompt region you type in. Under the prompt comes a footer saying which
permission mode the session is running.

The two regions answer to **different keymaps**, which is the thing to know
before anything else. The transcript is read-only and single letters act on it
(`n`, `p`, `TAB`, `a`, `d`). The prompt region has no keymap property, so the
major mode applies, and that binds only `RET`, `TAB` and keys under `C-c` —
every letter stays a letter while you are typing.

Redraws never reach past the prompt region, so a draft survives whatever the
session does while you are writing it. Finished turns are never touched again
either: a redraw rebuilds the current turn only, which is why the cost does not
grow with the length of the conversation.

## What it does not do

- **No terminal UI.** ecc does not reimplement the CLI's terminal interface.
  When you want it, `ecc-tui-open` hands the live session over to the real
  terminal client and `ecc-tui-return` takes it back. It is a change of hands,
  not a second window: the CLI has no lock, and two processes on one session
  quietly grow a second branch in the recording.
- **Claude Code only.** ecc speaks this CLI's protocol directly. It is not a
  general front end for language models, and the shapes it parses are the ones
  recorded from a real CLI into `test/fixtures`.
- **Small renderers.** Markdown, tables and diffs are drawn by ecc's own
  parsers rather than by `markdown-mode` or an external `diff`. They are
  deliberately modest, and they work the same in batch tests and on a machine
  with no `diff` installed.
- **No guessing.** Permission requests, usage figures and past conversations
  are what the CLI reports, not what ecc infers. A message ecc does not
  recognise is not dropped: it lands in the transcript as an `unknown` node and
  in the session's log buffer.

## Safe by default

- Permission prompts **default to deny**. Nothing runs because you pressed a
  key in a hurry.
- The loopback MCP server, which lets Claude ask Emacs what only Emacs knows,
  is **off** until you turn it on.
- Evaluating Elisp through that server needs a **second** opt-in of its own.
- Resuming a session that is still alive asks first, because doing it forks the
  conversation.

## Where to go next

- [Installation](/emacs-claude-code/start/installation/) — get it into your Emacs.
- [Your first session](/emacs-claude-code/start/first-session/) — start one and
  work through a turn.
- [How it works](/emacs-claude-code/explanation/how-it-works/) — the path from a
  line of JSON to the text on screen.
- [Command reference](/emacs-claude-code/reference/commands/) — everything ecc
  can be asked to do.
