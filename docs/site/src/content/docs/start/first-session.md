---
title: A first session
description: Start a session, send a prompt, allow a permission, review the changes, and finish.
sidebar:
  order: 2
---

One piece of work from start to end. This page assumes ecc is [installed](/emacs-claude-code/start/installation/) and `ecc-global-map` is on `C-c c`.

## Start a session

Open a file of the project and press `C-c c c`. The session opens beside the file, named after the project directory. Its directory cannot change once it has started, so start from a buffer of the right project.

The session buffer has the transcript at the top and the prompt region at the bottom. The transcript is read-only, so single keys there are commands: `n` and `p` move between headings, `TAB` folds. In the prompt region you type as usual.

## Send a prompt

Type in the prompt region and press `C-c C-c`; `RET` inserts a newline. The answer streams into the transcript. A prompt you send while Claude is working waits in a queue.

To include code, write `@region` or `@cursor` in the prompt, or send the region from the file with `C-c c ?` then `g`. See [Sending from your code](/emacs-claude-code/features/send/).

## Allow a permission

A new session starts in the `default` permission mode, unless `ecc-permission-mode` or your Claude Code settings say otherwise. There, before Claude edits a file or runs a command, the transcript shows the request with its diff or command, and the session's tab blinks until you answer.

Press `a` on the request to allow it once, or `d` to deny it. In the prompt region the same is `C-c C-a` and `C-c C-d`, and from any buffer `C-c c a` and `C-c c d`. [Permissions and plans](/emacs-claude-code/features/permissions/) covers the other answers, such as editing the proposal first.

## Review the changes

`C-c c D D` shows everything the session changed as one diff. Press `c` on a line to comment on it, and `C-c C-c` to send all the comments to Claude as one prompt. See [Reviewing changes](/emacs-claude-code/features/review/).

`F` in the transcript jumps to the Files section, which lists every file the session touched.

## Finish

`C-c c ?` then `k` stops the session and kills its buffer. The conversation stays on disk, and `C-c c r` resumes it later, in Emacs or in the terminal client.

Each project has a tab of its own, called a Space. [A day in a Space](/emacs-claude-code/usecases/spaces/) follows a piece of work through one.
