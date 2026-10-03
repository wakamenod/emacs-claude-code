---
title: Configuration
description: Every customize setting of ecc, grouped by area.
sidebar:
  order: 3
---

This page lists every `defcustom` of ecc. They are all in the `ecc` group:

```
M-x customize-group RET ecc
```

The feature pages also name a few variables that are not in customize; set those with `setq`.

## The CLI and the session

| Variable | Default | Description |
|---|---|---|
| `ecc-executable` | `"claude"` | The Claude Code CLI: a name on `PATH` or a path |
| `ecc-permission-mode` | `nil` | The mode a session starts in (`--permission-mode`): `"default"`, `"acceptEdits"`, `"plan"`, `"auto"` or `"bypassPermissions"`. `nil` keeps the CLI's default |
| `ecc-plan-default-mode` | `"acceptEdits"` | The mode an approved plan switches to when you choose none. `nil` asks for no change, and the CLI goes back to its default mode |
| `ecc-prompt-suggestions-enabled` | `nil` | Non-nil passes `--prompt-suggestions`, so the CLI suggests a next prompt |
| `ecc-command-wrapper-function` | `nil` | A function that receives `(command-list project-root)` and returns the command to run instead |
| `ecc-disabled-plugins` | `nil` | Plugins (`"name@marketplace"`) to turn off in the sessions ecc starts. The terminal client keeps them |

There is no setting for the model or for a budget: both belong to your Claude Code settings. A resumed session keeps the model of its last turn. To change the model of a running session, use `m` in the menu or `/model`.

## The transcript

| Variable | Default | Description |
|---|---|---|
| `ecc-chat-return-sends` | `nil` | `t` makes `RET` send, as in the terminal client; `C-c C-c` always sends |
| `ecc-chat-text-width` | `100` | Width of the text in columns; `nil` uses the whole window |
| `ecc-chat-line-spacing` | `0.15` | Extra space below each line, as in `line-spacing`; `nil` adds none |
| `ecc-render-result-max-lines` | `12` | Lines shown of a tool result; `RET` shows all of it |
| `ecc-render-inhibit-inline-diff` | `nil` | `t` shows the calls that change a file folded; `TAB` opens them |
| `ecc-render-diff-max-lines` | `40` | Lines shown of a diff in a tool call or a request; `RET` shows all of it |
| `ecc-diff-context-lines` | `3` | Context lines around a change in the transcript |
| `ecc-stream-throttle` | `0.05` | Seconds to gather streamed text before drawing it; `0` draws each piece |
| `ecc-render-debounce` | `0.1` | Seconds to wait before redrawing the part of the transcript that is changing |
| `ecc-show-hook-events` | `nil` | Non-nil shows each hook that fires, with its exit code and output. The hooks run either way. Read when a session starts |
| `ecc-image-inline` | `t` | `nil` shows only the line naming each image or video |

## Header line and mode line

| Variable | Default | Description |
|---|---|---|
| `ecc-hint-context-indicator` | `t` | Show the context window left in the header line |
| `ecc-prompt-suggestion-display` | `t` | Show the CLI's suggestion in the empty prompt region (needs `ecc-prompt-suggestions-enabled`) |
| `ecc-mode-line-format` | `nil` | A format for the session in the mode line; `nil` shows none |

`ecc-mode-line-format` takes these specifiers:

| Spec | Meaning |
|---|---|
| `%n` | Session name |
| `%m` | Model |
| `%p` | Permission mode |
| `%l` | Context window left, as a percentage |
| `%t` | Tokens in the context window |
| `%c` | Cost so far |
| `%r` | Rate limit used |
| `%s` | Session state |

## Notifications

| Variable | Default | Description |
|---|---|---|
| `ecc-notify-level` | `'message` | `'message` in the echo area, `'pulse` also flashes the transcript, `'desktop` a desktop notification, `nil` none |
| `ecc-notify-events` | `'(turn-finished request exited)` | What notifies: a finished turn, a request, a process that exited |
| `ecc-notify-suppress-when-focused` | `t` | No desktop notification while Emacs has the focus |
| `ecc-notify-sound` | `nil` | A system sound for desktop notifications, such as `"Glass"` on macOS |
| `ecc-notify-function` | `#'ecc-notify-default` | A function of `(SESSION EVENT TEXT)` that replaces the notification |

## Reviews

| Variable | Default | Description |
|---|---|---|
| `ecc-review-style` | `'diff` | `'diff` opens a review as one `diff-mode` buffer, `'ediff` [in ediff](/emacs-claude-code/features/review-ediff/) |
| `ecc-review-menu-count-session-changes` | `t` | Show beside `D` in the review menu how many files the session changed. `nil` if it makes the menu slow to open |
| `ecc-review-auto-refresh` | `t` | Read an open review again when its files may have changed; `nil` reads it only with `g` |
| `ecc-review-files-width` | `32` | Width of the list of files beside a review |
| `ecc-review-ediff-layout` | `'stacked` | `'stacked` or `'side-by-side`: how an ediff review opens |
| `ecc-review-talk-reply-width` | `75` | Width of the reply pane right of a stacked ediff review |
| `ecc-review-talk-reply-height` | `12` | Height of the reply pane under a side-by-side ediff review; `nil` shows no pane |
| `ecc-review-talk-reply-place` | `'auto` | `'frame` puts the reply pane in a frame of its own |

## Windows

| Variable | Default | Description |
|---|---|---|
| `ecc-use-spaces` | `t` | A tab for each project. `nil` uses the [older layout](/emacs-claude-code/features/spaces/#without-spaces) |
| `ecc-space-always-session` | `t` | Opening a Space with nothing running starts a session, and closing its last session closes the Space |
| `ecc-space-session-min-width` | `80` | The narrowest a transcript is made before a new session reuses a window instead |
| `ecc-sidebar-width` | `28` | Width of the sidebar |
| `ecc-window-large-frame-min-height` | `80` | With Spaces off: frame height in lines needed for a third session window |
| `ecc-window-sub-height` | `0.33` | With Spaces off: height of the third session window |

## Side buffers and popups

| Variable | Default | Description |
|---|---|---|
| `ecc-btw-display` | `'window` | Where `/btw` answers appear |
| `ecc-usage-display` | `'window` | Where the usage report appears |

Both take `'window` or `'posframe`, a popup over the frame. `'posframe` needs the [posframe](https://github.com/tumashu/posframe) package and a graphical frame; without them, ecc uses a window.

## The MCP server

ecc can run an MCP server on the loopback interface and register it with each session. Claude then reads Emacs's `xref`, `imenu`, tree-sitter, project and diagnostics, [works in the review](/emacs-claude-code/features/review-claude/), and [hands work to a worktree](/emacs-claude-code/features/spaces/#handing-work-to-a-session-in-a-worktree).

| Variable | Default | Description |
|---|---|---|
| `ecc-mcp-enabled` | `nil` | Register the server with every session. It starts on first use; `M-x ecc-mcp-stop` stops it |
| `ecc-mcp-enable-execute-code` | `nil` | Offer the tool that lets Claude evaluate any Elisp |
| `ecc-mcp-excluded-tools` | `nil` | Tool names to leave out, such as tools that are slow |

:::caution[Two separate opt-ins]
`ecc-mcp-enabled` does not turn on `ecc-mcp-enable-execute-code`. Code run through that tool has all your permissions in Emacs.
:::

## Logging

| Variable | Default | Description |
|---|---|---|
| `ecc-log-max-lines` | `5000` | Lines kept in a session's log buffer; `nil` keeps all |
| `ecc-debug` | `nil` | Also log ecc's internal traces |

`M-x ecc-show-log` (`L` in the menu) shows the session's protocol log. A message ecc fails to handle stays in the log and shows as an `unknown` node in the transcript.
