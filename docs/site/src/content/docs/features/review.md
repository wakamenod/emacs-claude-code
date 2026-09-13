---
title: Review and plan mode
description: Review proposed changes, inspect unified diffs across a session, and interact with plan mode.
sidebar:
  order: 4
---

Review all modifications made during a session as a unified diff, attach comments to specific hunks, and submit your feedback in a single prompt. The same diff buffer can also inspect individual file proposals before approval, and review plans created in plan mode.

## Reviewing session changes

Press `D` in the transient menu, `C-c c D`, or run `M-x ecc-review`. A prefix argument (`C-u D`) prompts for specific files.

![Every change of the session as one diff: a comment attached to a hunk, and the prompt it becomes shown before it goes](../../../assets/review.gif)

Files tracked by Git are diffed using `git diff` — **including any uncommitted local changes**. Untracked files or files outside a Git repository are diffed against their state prior to the session's first modification.

| Key | Action |
|---|---|
| `c` | Comment on hunk at point |
| `l` | Jump to a previously added comment |
| `d` | Remove comment on this hunk |
| `e` | Edit proposed file content (when reviewing a single proposal) |
| `C-c C-c` | Send comments as prompt |
| `C-c C-k` | Cancel review and discard comments |
| `g` | Refresh diff |
| `q` | Bury review buffer |

The buffer uses read-only `diff-mode`, so standard navigation keys (`n`, `p`, `RET`) move between hunks and jump to source files.

Comments are attached directly to hunks: the hunk header is highlighted in bold, the comment appears immediately below it, and the header line displays the total comment count. Pressing `c` on an already commented hunk lets you edit your previous comment.

Pressing `C-c C-c` compiles all comments into a single prompt buffer for final review:

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

You can edit this prompt before submitting: press `C-c C-c` to send, or `C-c C-k` to return to the diff without sending.

## Reviewing proposals before approval

![The text of a proposed Write, changed in a buffer and then allowed with the change](../../../assets/proposal.gif)

When a tool permission request is pending in the transcript, `c` opens the review buffer for that specific modification, while `e` opens the proposed file content for direct editing. Both keys are available directly on the request node (see [Prompt and transcript](/emacs-claude-code/features/prompt/#on-a-pending-request-node)).

Comments submitted here are sent as the **reason for rejection**, prompting Claude to generate an updated proposal rather than correcting mistakes after writing.

`e` opens the proposed buffer in the target file's major mode. `C-c C-c` approves the change using your edited buffer instead of Claude's proposal; `C-c C-k` leaves the request pending. If you modify the text, ecc automatically sends a diff showing what was applied.

## Plan mode

When exiting plan mode, the CLI submits a request containing the full plan. ecc opens this plan in an editable buffer alongside the active session.

![A plan opened in its own buffer, the permission mode chosen, and the plan approved](../../../assets/plan.gif)

There are three ways to provide feedback on a plan:

| Feedback method | How to use |
|---|---|
| Line comment | Press `C-c C-a` to add a comment (`C-c C-r` to remove) |
| Inline marker | Write `@claude: …` on any line |
| Direct edit | Edit the plan text directly; press `C-c C-d` to diff changes |

If any feedback is present, `C-c C-c` returns the plan with your comments and edits instead of approving it, requesting an updated plan. If no feedback is entered, `C-c C-c` approves the plan and requests a permission mode switch: press `C-c C-p` to choose a mode, otherwise defaulting to `ecc-plan-default-mode` (`"acceptEdits"`).

| Key | Action |
|---|---|
| `C-c C-c` | Approve plan, or send feedback if edits/comments exist |
| `C-c C-k` | Reject plan with a reason, including any feedback |
| `C-c C-a` / `C-c C-r` | Add or remove comment on current line |
| `C-c C-d` | Diff your edits against the proposed plan |
| `C-c C-p` | Select permission mode for approval |
| `C-c C-n` | Jump to next line modified since previous plan |

When an updated plan arrives, modified lines are highlighted in the margin, and the header line displays `+N −N` change statistics.

## The Files section

![The Files section: a file unfolded to its diff, then reviewed on its own](../../../assets/files.gif)

A summary of all files touched during the session appears at the bottom of the transcript, displaying the file path, operations performed (`R×n` reads, `E×n` edits, `W×n` writes), and net lines changed (`+n −n`). Press `TAB` to expand the cumulative diff for a file, `RET` to visit the file, and `d` to review that file individually in diff-mode.

Press `f` in the transcript (or `F` in the menu) to jump to this section. Set `ecc-render-summary-position` to `'top` to place the section at the top instead.

## The Timeline

Press `T` in the transcript to display a prompt history picker and jump directly to any turn. `C-c C-n` and `C-c C-p` move forward and backward turn by turn.

![The turn picker, listing the turns of the session by their prompts](../../../assets/timeline.png)

## Window placement for reviews

Reviewing diffs or plans requires screen space. Two variables control window behavior during review:

| Variable | Description |
|---|---|
| `ecc-window-hide-on-review` | `'project` hides sessions of the current project, `'all` hides all sessions, and `nil` keeps windows intact |
| `ecc-window-review-focus` | `'review` focuses the review buffer, `'session` retains point in the transcript, and `nil` preserves current focus |

`ecc-toggle` restores hidden session windows for the current project, and `ecc-toggle-all` restores them for all projects. Additional settings are documented in the [configuration reference](/emacs-claude-code/reference/configuration/).
