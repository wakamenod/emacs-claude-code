---
title: A day in a Space
description: Going to a project, working in it, handing the implementation to a worktree, and closing both.
sidebar:
  order: 1
---

One way through a piece of work with [Spaces](/emacs-claude-code/features/spaces/): pick the project, talk it over, hand the implementation to a worktree of its own, and put both away when it is done.

## Go to the project

`C-c c j` (`ecc-space-goto`) asks which Space to go to. The list is not only what is open: every project you have ever started a session in is offered, because ecc reads the CLI's recordings. A project you worked in last month, with nothing running and no tab, is one `RET` away.

Picking one adds it to the sidebar and starts a session there.

![Choosing a project from the list: a tab of its own appears, the sidebar takes a row for it, and a session opens beside its source](../../../assets/usecase-goto.gif)

## Talk it over

The session opens beside the project's source, and you work as usual: ask, read, answer. Sooner or later the conversation turns into an implementation, and that is the moment to get it out of this window.

Ask for a worktree — "cut a worktree and do it there" — and, with the [Emacs MCP server](/emacs-claude-code/start/installation/) on (`ecc-mcp-enabled`), Claude calls `start_worktree_session`. Emacs makes the worktree, opens it as a Space of its own under the repository, starts a session in it and hands that session the brief. The conversation you were in reports where the work went and carries on.

![The worktree as a Space of its own: its tab beside the repository's, its row under the repository in the sidebar, and its session running in it](../../../assets/usecase-worktree.png)

## Put it away

When the implementation is done, kill the worktree session's buffer. Its Space holds nothing else, so the Space closes and takes you back to the Space beside it, and ecc asks whether to remove the worktree's directory as well. The branch stays either way.
