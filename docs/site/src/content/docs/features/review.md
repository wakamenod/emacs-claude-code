---
title: Review
description: Seeing a change before it is allowed, and reviewing every change of a session at once.
sidebar:
  order: 4
---

Let Claude change things, then read every change as one diff, comment on the hunks that
need work, and send the comments as one prompt. The same buffer reviews a single proposal
before it is applied, and a plan is read and sent back the same way.

## Reviewing what changed

`D` on the menu, `C-c c D`, or `M-x ecc-review`. A prefix argument asks which files.

![Every change of the session as one diff: a comment attached to a hunk, and the prompt it becomes shown before it goes](../../../assets/review.gif)

A file git tracks is diffed with `git diff` — **so your own uncommitted changes to that
file are in it too**. A file outside a repository, or not yet added to one, is diffed
against what it was before the session's first change.

| Key | Action |
|---|---|
| `c` | Comment on the hunk at point |
| `l` | Pick one of the comments and go to its hunk |
| `d` | Remove the comment on this hunk |
| `e` | Edit the proposal (in the review of one) |
| `C-c C-c` | Send the comments |
| `C-c C-k` | Close the review, dropping the comments |
| `g` | Read the changes again |
| `q` | Bury the buffer |

The buffer is a read-only `diff-mode`, so `n`, `p` and `RET` move by hunk and visit the
source as they do in any diff.

A comment is attached to its hunk: the header of that hunk goes bold, the comment stands
under it, and the header line counts them. `c` on a commented hunk offers what you wrote
before.

`C-c C-c` collects them into one prompt, a block per comment:

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

It is shown in a buffer first and can be edited there: `C-c C-c` sends it, `C-c C-k` goes
back to the diff.

## Reviewing a proposal before it is applied

![The text of a proposed Write, changed in a buffer and then allowed with the change](../../../assets/proposal.gif)

On a request waiting in the transcript, `c` opens the same buffer for that one change and
asks for the comment; `e` opens the text it proposes. Both are keys of the node — see
[Prompt and transcript](/emacs-claude-code/features/prompt/#on-a-node-waiting-for-an-answer).

A comment here goes back as the **reason of the deny**, so Claude proposes again rather
than being told after the change is made.

`e` opens the proposed text in the file's own major mode. `C-c C-c` allows the request
with your text in place of Claude's, `C-c C-k` leaves it waiting. When you changed
something, the next message carries a diff saying what was applied instead.

## Plan mode

The CLI asks to leave plan mode with a request carrying the whole plan. ecc opens it in a
buffer you can edit, by itself while the session is on screen.

![A plan opened in its own buffer, the permission mode chosen, and the plan approved](../../../assets/plan.gif)

There are three ways to say what should change, and approving looks for all three:

| Feedback | How |
|---|---|
| A comment on a line | `C-c C-a`; `C-c C-r` takes it off |
| A marker in the text | write `@claude: …` on a line |
| An edit of the plan | type in the buffer; `C-c C-d` shows what you changed |

With any of them, `C-c C-c` sends the plan back instead of approving it — one message
with a section per kind of feedback — and asks for the plan again. With none of them it
approves, and asks the CLI to switch permission mode: `C-c C-p` chooses which,
`ecc-plan-default-mode` (`acceptEdits`) is what it is otherwise.

| Key | Action |
|---|---|
| `C-c C-c` | Approve, or send the feedback the buffer holds |
| `C-c C-k` | Send it back with a reason, carrying the rest of the feedback |
| `C-c C-a` / `C-c C-r` | Add or remove a comment on this line |
| `C-c C-d` | Show what you changed in the plan |
| `C-c C-p` | Choose the permission mode to approve into |
| `C-c C-n` | Next line that changed since the previous plan |

A plan shown again marks in the margin the lines that are new since the last one, and the
header line says `+N −N`.

## The Files section

![The Files section: a file unfolded to its diff, then reviewed on its own](../../../assets/files.gif)

Every file the session touched stands at the end of the transcript: the path, what was
done to it (`R×n E×n W×n`) and the lines changed (`+n −n`). `TAB` unfolds the merged diff
of every change to that file, `RET` visits the file, and `d` reviews that file alone.

`f` in the transcript, or `F` on the menu, goes there.
`ecc-render-summary-position` puts the section at the top instead.

## The Timeline

`T` lists the turns of the session by the prompt each started with, and moves to the one
picked. `C-c C-n` and `C-c C-p` step turn by turn.

![The turn picker, listing the turns of the session by their prompts](../../../assets/timeline.png)

## Where the review opens

A diff or a plan needs room, and the session windows are what there is to take it from.
Two variables decide what happens:

| Variable | What it does |
|---|---|
| `ecc-window-hide-on-review` | `project` hides the sessions of the project being reviewed, `all` hides every session, nil leaves the windows alone |
| `ecc-window-review-focus` | `review` selects the review, `session` leaves point in the transcript, nil leaves it where it was |

`ecc-toggle` brings back what was hidden. The rest of the settings are on the
[configuration reference](/emacs-claude-code/reference/configuration/).
