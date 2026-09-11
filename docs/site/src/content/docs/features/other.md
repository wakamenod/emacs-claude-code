---
title: Other features
description: "The rest: what a session can do, what the plan has been spent on, and the smaller things."
sidebar:
  order: 5
---

## Capabilities

`y` on the menu, or `C` in the dashboard. What the session can actually do, as the CLI
reported it in `system/init`: skills, agents, slash commands, MCP servers and plugins,
each grouped by where it comes from — the project, your global settings, a plugin, or the
CLI itself.

![The capabilities buffer, its groups folded and unfolded](../../../assets/capabilities.gif)

`TAB` folds a group, `RET` visits what is at point, and `g` reads it again. Before the
first turn there is nothing to show, and the buffer says so.

## Usage

`U` on the menu, `C-c c U`, or `M-x ecc-usage`: how much of the Claude Code plan has been
used.

![The usage report floating over the frame: the rate limit windows, what this session cost, and what has been spending the limits](../../../assets/usage.png)

The numbers are the CLI's own — the same ones the web client shows under Settings →
Usage — so nothing here is estimated. With no session running, one is started for the
question alone and stopped again; no prompt is sent, so asking costs nothing.

| Key | Action |
|---|---|
| `g` | Ask again |
| `b` | Show or hide what has been spending the limits |
| `q` | Take it away |

`ecc-usage-display` floats the report over the frame, as above, or puts it in a window.
What has been spending the limits is a scan of the sessions on **this machine**, so it
says nothing about another device or claude.ai.

## The smaller things

| What | How |
|---|---|
| The transcript of a subagent | `RET` on an agent in the transcript opens the conversation it had, on its own |
| The conversation as Markdown | `C-c C-e` in a session writes it out |
| The raw protocol log | `L` — every line in and out, stamped; what a bug report should carry |
| Remote Control | `o`, `O` and `K` on the [menu](/emacs-claude-code/features/menu/#o-o-k--remote-control) |

Every setting is on the
[configuration reference](/emacs-claude-code/reference/configuration/).
