---
title: Review and plan mode
description: Review proposed changes, inspect unified diffs across a session, and interact with plan mode.
sidebar:
  order: 4
---

Review changes as a single diff, comment on hunks that need work, and send all comments in a single prompt. The same buffer reviews what a session changed, the working tree it modified, or a single proposal before it is applied.

`D` and `G` are the same review with a different base:

- `D` — against **where the session started**, so work committed during the session is still shown.
- `G` — against **the last commit (`HEAD`)**, so only what is uncommitted.

Neither cares how a file was changed: an edit, a shell command and a script all show alike.

## Reviewing session changes

Press `D` in the transient menu, type `C-c c D`, or run `M-x ecc-review`. A prefix argument (`C-u D`) prompts for specific files.

![Every change of the session as one diff: a comment attached to a hunk, and the prompt it becomes shown before it goes](../../../assets/review.gif)

When the session starts, ecc records what the working tree held — a Git tree object written through a throwaway index, so nothing is stashed and neither the real index nor your files are touched. The review compares the tree as it stands now against that baseline. Work you had in progress before the session started is therefore left out, and a change is shown whether the CLI made it with an edit tool, a shell command or a script.

Because the base is a moment rather than a commit, changes the session committed along the way are still shown; `G` would have lost them. Resuming a session keeps its baseline — that restarts the CLI, not the work, and the conversation carries on — so nothing the session had already done drops out of its own review. A session read back from a recording in a fresh Emacs has no baseline to keep and takes its first one then.

Two caveats worth knowing. The base is a time, not an author, so another session working in the same directory shows up here too — separate Git worktrees keep them apart. And a file larger than `ecc-review-max-bytes` (200,000 by default) is named rather than printed, which is what usually happens to a lock file a package manager rewrote.

Outside a Git repository there is no tree to compare against, so files are diffed against what the CLI reported them holding before the session's first change — the only place the old behaviour remains.

| Key | Action |
|---|---|
| `c` | Comment on the hunk at point (again to edit it) |
| `l` | Jump to a comment |
| `d` | Remove the comment on this hunk |
| `e` | Edit the proposed content (reviewing one proposal) |
| `C-c C-c` | Send the comments as a prompt |
| `C-c C-k` | Drop the review and its comments |
| `g` | Read the diff again |
| `q` | Bury the buffer |

The buffer uses read-only `diff-mode`, so `n`, `p`, and `RET` move between hunks and jump to source. A commented hunk displays a bold header, the comment below it, and the count in the header line.

`C-c C-c` collects the comments into a single prompt to confirm:

````
## hello.py  L1-L6
```diff
 def greet(name):
     """Say hi."""
-    return "hi " + name
+    return "hello " + name
```
Comment: the docstring still says hi
````

Edit it if you like; `C-c C-c` sends the prompt, while `C-c C-k` returns to the diff.

## Reviewing the working tree

Where `ecc-review` starts from the moment the session began, this starts from the last commit. Press `G` in the menu, type `C-c c G`, or run `M-x ecc-review-worktree`.

This diffs the project's entire repository against `HEAD` — every uncommitted change, staged or unstaged, plus the untracked files (those `.gitignore` excludes are left out; a binary file, or one larger than `ecc-review-max-bytes`, is named rather than printed). A repository with no commit yet is compared against the empty tree, so the first code written in a project can be reviewed before it is committed. `C-u G` prompts for what to diff against: a revision, a range such as `main...HEAD`, or nothing for unstaged changes.

The project is determined by the current buffer, and comments go to that project's session. If none exists, ecc offers to start one, which is the usual entry point. Commenting and sending work as described above, and the two reviews use separate buffers.

Hunks are as small as the change itself, since a comment includes the entire hunk it annotates. Setting `(setq ecc-review-context-lines 3)` widens them: the value is passed to git as `-U` when ecc runs it, so no `git config` is read or written. Proposals retain three lines of context either way via `ecc-review-proposal-context-lines`.

## Reviewing proposals before approval

![The text of a proposed Write, changed in a buffer and then allowed with the change](../../../assets/proposal.gif)

While a tool permission request is pending in the transcript, pressing `c` on the request node reviews that change, and `e` opens its proposed content (see [Prompt and transcript](/emacs-claude-code/features/prompt/#on-a-pending-request-node)).

Comments here are sent as the **reason for the deny**, allowing Claude to propose again rather than being corrected after the write.

`e` opens the proposal in the target file's major mode. `C-c C-c` allows the change using your text instead of Claude's and sends a diff of what you altered; `C-c C-k` leaves the request pending.

## Plan mode

Exiting plan mode sends the plan as a request. ecc opens it in an editable buffer beside the session.

![A plan opened in its own buffer, the permission mode chosen, and the plan approved](../../../assets/plan.gif)

Feedback can take three forms: a line comment (`C-c C-a`, removed with `C-c C-r`), an inline `@claude: …` marker, or an edit to the plan itself (`C-c C-d` diffs it).

With any feedback present, `C-c C-c` returns the plan with it and requests a revision. Without feedback, it approves and prompts for a permission mode: `C-c C-p` chooses one; otherwise, `ecc-plan-default-mode` (`"acceptEdits"`) is used.

| Key | Action |
|---|---|
| `C-c C-c` | Approve, or send the feedback there is |
| `C-c C-k` | Reject with a reason, feedback included |
| `C-c C-a` / `C-c C-r` | Add or remove a comment on this line |
| `C-c C-d` | Diff your edits against the plan as proposed |
| `C-c C-p` | Choose the permission mode to approve with |
| `C-c C-n` | Next line changed since the previous plan |

A new plan marks changed lines in the margin and shows `+N −N` in the header line.

## The Files section

![The Files section: a file unfolded to its diff, then reviewed on its own](../../../assets/files.gif)

The bottom of the transcript lists the files touched during the session: the path, operations performed (`R×n` reads, `E×n` edits, `W×n` writes), and lines changed (`+n −n`). `TAB` expands a file's cumulative diff, `RET` visits it, and `d` reviews it on its own.

Pressing `f` in the transcript (or `F` in the menu) jumps there. Setting `ecc-render-summary-position` to `'top` places the section at the top instead.

## The Timeline

`T` in the transcript lists turns by their prompts and jumps to the selected one. `C-c C-n` and `C-c C-p` step through them.

![The turn picker, listing the turns of the session by their prompts](../../../assets/timeline.png)

## Window placement for reviews

Reviews require screen space, which two variables control:

| Variable | Description |
|---|---|
| `ecc-window-hide-on-review` | `'project` hides the sessions of this project, `'all` every session, `nil` none |
| `ecc-window-review-focus` | `'review` focuses the review, `'session` keeps point in the transcript, `nil` leaves focus alone |

`ecc-toggle` restores this project's session windows, and `ecc-toggle-all` restores every project's. The remaining options are in the [configuration reference](/emacs-claude-code/reference/configuration/).
