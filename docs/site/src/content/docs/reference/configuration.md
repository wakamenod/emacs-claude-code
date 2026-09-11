---
title: Configuration reference
description: Every setting ecc offers, grouped by what it decides.
sidebar:
  order: 2
---

Every `defcustom` in ecc is listed here, with its default and what it decides.
All of them are in the `ecc` customization group:

```
M-x customize-group RET ecc
```

## What is a setting, and what is not

A `defcustom` in ecc is reserved for something a user chooses: a taste, a
difference between machines (font, screen, `PATH`), or a judgement about safety
and cost. There are thirty of them, and they are all below.

Everything else is a plain `defvar`: a stand-in the CLI overwrites, a sentence
sent to the model, a table of the CLI's own quirks, an internal constant. Those
are still reachable with `setq` and still bindable in a test — a variable
missing from `customize` is not a variable you cannot change. A few of the
useful ones are listed at the [end of this page](#useful-variables-that-are-not-settings).

## The CLI and the session

| Variable | Default | What it decides |
|---|---|---|
| `ecc-executable` | `"claude"` | Name of, or path to, the Claude Code CLI executable |
| `ecc-permission-mode` | `nil` | Initial mode passed with `--permission-mode`. `nil` leaves the CLI default in place; the rest are `"default"`, `"acceptEdits"`, `"plan"`, `"auto"` and `"bypassPermissions"` |
| `ecc-plan-default-mode` | `"acceptEdits"` | Permission mode switched to when a plan is approved without choosing one. `nil` approves without asking for a change, which the CLI answers by leaving plan mode for the default mode |
| `ecc-prompt-suggestions-enabled` | `nil` | Non-nil passes `--prompt-suggestions` |
| `ecc-command-wrapper-function` | `nil` | Function that rewrites the CLI command line before it is run. Called with the command list and the project root, and must return the command list to run. `nil` runs the command unchanged |

There is deliberately **no setting that names a model**. The model comes from
your Claude Code settings for a new session, and from the last real assistant
message of its recording for a resumed one. Passing `--model` would override
that for good, undoing every `/model` made since. Use `ecc-set-model` to change
the model of a running session instead.

There is likewise no budget setting: cost belongs in the Claude Code settings.

## The transcript

| Variable | Default | What it decides |
|---|---|---|
| `ecc-chat-text-width` | `100` | Most columns the text is drawn across, or `nil` for the whole window. The surplus is put in the right margin rather than taken off the window, so whatever else the window holds is unaffected |
| `ecc-chat-line-spacing` | `0.15` | Extra room under every line, read as `line-spacing` reads it: a float is a fraction of the line height. `nil` for none |
| `ecc-render-result-max-lines` | `12` | Lines of a tool result shown. The whole result is always available with `RET` |
| `ecc-render-diff-max-lines` | `40` | Lines of a diff shown inside a tool or permission section. The whole diff is always available with `RET` |
| `ecc-diff-context-lines` | `3` | Lines of context shown around a change in the transcript |
| `ecc-review-context-lines` | `3` | Lines of context around a change in a diff the review makes itself |
| `ecc-stream-throttle` | `0.05` | Seconds to gather streaming deltas before drawing them. Zero draws every delta as it arrives |
| `ecc-render-debounce` | `0.1` | Seconds to gather changes before redrawing the live region |

## The header line and the mode line

| Variable | Default | What it decides |
|---|---|---|
| `ecc-hint-context-indicator` | `t` | Non-nil shows the context left in the header line of a session |
| `ecc-prompt-suggestion-display` | `t` | Non-nil shows the suggestion the CLI offers in the prompt region. Suggestions only arrive when the session was started with `--prompt-suggestions`, which `ecc-prompt-suggestions-enabled` controls |
| `ecc-mode-line-format` | `nil` | How a session describes itself in the mode line. `nil` shows nothing |

`ecc-mode-line-format` is `nil` by default because the mode line is narrow, the
same numbers are already in the header line, and a session that repeated them
in both was unreadable. If you want it anyway, it takes a format string:

| Spec | Meaning |
|---|---|
| `%n` | The session name |
| `%m` | The model |
| `%p` | The permission mode |
| `%l` | The context left, as a percentage |
| `%t` | The tokens in the context |
| `%c` | The cost so far |
| `%r` | The rate limit utilization |
| `%s` | The state |

## Notifications

| Variable | Default | What it decides |
|---|---|---|
| `ecc-notify-level` | `'message` | How much noise an event makes. `message` writes one line in the echo area, `pulse` flashes the transcript as well, `desktop` also asks the desktop to show a notification, and `nil` says nothing at all |
| `ecc-notify-events` | `'(turn-finished request exited)` | Which events are announced: a turn that finished, a request that needs an answer, a session that stopped on its own |
| `ecc-notify-suppress-when-focused` | `t` | Non-nil holds desktop notifications back while Emacs has the focus |
| `ecc-notify-sound` | `nil` | Name of the sound a desktop notification plays, or `nil` for silence. On macOS this is a system sound name such as `"Glass"` |
| `ecc-notify-function` | `#'ecc-notify-default` | Function called with SESSION, EVENT and TEXT. Replacing it takes over notification completely |

## Windows

| Variable | Default | What it decides |
|---|---|---|
| `ecc-window-large-frame-min-height` | `80` | Height, in lines, a frame needs before it gets a third session window. Below it the sessions share two windows and the tab line reaches the rest |
| `ecc-window-sub-height` | `0.33` | Height of the third session window, as a fraction or a line count. It is taken from the main area of the frame — the source code, usually — rather than from the side the other two are on |

The default of `ecc-window-large-frame-min-height` tells a laptop from a large
display: a 14-inch screen holds around 58 lines and a 16-inch one around 67,
while the display this was measured on holds 114.

## Buffers shown to one side

| Variable | Default | What it decides |
|---|---|---|
| `ecc-btw-display` | `'window` | Where the answer to a `/btw` side question is shown |
| `ecc-usage-display` | `'window` | Where `ecc-usage` shows what it found |

Both take `window` or `posframe`. `posframe` floats the buffer over the frame,
which needs the [posframe](https://github.com/tumashu/posframe) package and a
graphical frame; without either, a window is used and the buffer is the same one.

## The MCP server

ecc can run an MCP server on the loopback interface and register it with each
session, which lets Claude ask Emacs what only Emacs knows: xref, imenu,
tree-sitter, project and diagnostics.

| Variable | Default | What it decides |
|---|---|---|
| `ecc-mcp-enabled` | `nil` | Non-nil registers the server with every session started. The server starts the first time a session needs it, and is stopped by `ecc-mcp-stop` |
| `ecc-mcp-enable-execute-code` | `nil` | Non-nil publishes the tool that evaluates arbitrary Elisp |
| `ecc-mcp-excluded-tools` | `nil` | Names of tools that are not published, whatever else registered them. A tool that turns out to take long enough to be felt belongs here |

:::caution[Two separate decisions]
`ecc-mcp-enable-execute-code` is deliberately not implied by `ecc-mcp-enabled`.
Anything the model writes through that tool would run with the rights of this
Emacs, so turning the server on and letting it evaluate Elisp are asked
separately.
:::

## Logging

| Variable | Default | What it decides |
|---|---|---|
| `ecc-log-max-lines` | `5000` | Maximum number of lines kept in a session log buffer. `nil` keeps every line |
| `ecc-debug` | `nil` | Non-nil logs internal diagnostics in addition to raw protocol lines |

`ecc-show-log` opens the raw protocol log of the session the current buffer
talks to. A failed dispatch is never swallowed: it is left in the log and in an
`unknown` node in the transcript.

## Useful variables that are not settings

These are `defvar`s, so they are absent from `customize` — `setq` them.

| Variable | Default | What it decides |
|---|---|---|
| `ecc-chat-return-sends` | `nil` | `nil`: `RET` inserts a newline and `C-c C-c` sends. `t`: `RET` sends, the way the terminal client does |
| `ecc-disabled-plugins` | `nil` | `"name@marketplace"` entries switched off for the sessions ecc starts. Per session, so your own interactive sessions are unaffected |
