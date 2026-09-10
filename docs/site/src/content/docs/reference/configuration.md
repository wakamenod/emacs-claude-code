---
title: Configuration reference
description: The settings ecc offers, and how to reach the ones not listed here.
sidebar:
  order: 1
---

:::caution[Partial]
ecc has thirty `defcustom`s. A handful are listed below; the rest are still to
be written up. Until then, `M-x customize-group RET ecc` is the complete list,
with the docstring of each.
:::

## Reaching every setting

```
M-x customize-group RET ecc
```

A `defcustom` in ecc is reserved for something a user chooses: a taste, a
difference between machines, or a judgement about safety and cost. Everything
else is a plain `defvar`, which `setq` still reaches and a test can still bind
— so a variable missing from `customize` is not a variable you cannot change.

## Selected settings

| Variable | Default | What it decides |
|---|---|---|
| `ecc-executable` | `"claude"` | Name of, or path to, the Claude Code CLI |
| `ecc-chat-text-width` | `100` | Columns the transcript is drawn across; the surplus becomes right margin |
| `ecc-notify-level` | `'message` | `nil`, `'message`, `'pulse` or `'desktop` |
| `ecc-permission-mode` | `nil` | Initial `--permission-mode`; `nil` leaves the CLI default |
| `ecc-mcp-enabled` | `nil` | Register the loopback MCP server with each session |
| `ecc-mcp-enable-execute-code` | `nil` | Publish the tool that evaluates Elisp — a second, separate decision |

## Not a defcustom, but worth knowing

| Variable | Default | What it decides |
|---|---|---|
| `ecc-chat-return-sends` | `nil` | `nil`: `RET` inserts a newline and `C-c C-c` sends. `t`: `RET` sends, the way the terminal client does |
| `ecc-disabled-plugins` | `nil` | `"name@marketplace"` entries switched off for the sessions ecc starts |
