---
title: Review and plan mode
description: Review proposed changes, inspect unified diffs across a session, and interact with plan mode.
sidebar:
  order: 4
---

Review changes as a single diff, comment on hunks that need work, and send all comments in a single prompt. The same buffer reviews what a session changed, the working tree it modified, or a single proposal before it is applied.

`D` and `G` are the same review with a different base:

- `D` — against **where the session started**, so work committed during the session is still shown.
- `G` — against **the last commit (`HEAD`)**, so only uncommitted changes are shown.

Neither cares how a file was changed: an edit, a shell command and a script all show alike.

## Reviewing session changes

Press `D` in the transient menu, type `C-c c D`, or run `M-x ecc-review`. A prefix argument (`C-u D`) prompts for specific files.

![Every change of the session as one diff: a comment attached to a hunk, and the prompt it becomes shown before it goes](../../../assets/review.gif)

When the session starts, ecc records what the working tree held — a Git tree object written through a throwaway index, so nothing is stashed and neither the real index nor your files are touched. The review compares the tree as it stands now against that baseline. Work you had in progress before the session started is therefore left out, and a change is shown whether the CLI made it with an edit tool, a shell command or a script.

Because the base is a moment rather than a commit, changes the session committed along the way are still shown; `G` would have lost them. Resuming a session keeps its baseline.

Two caveats worth knowing. The base is a time, not an author, so another session working in the same directory shows up here too — separate Git worktrees keep them apart. And a file larger than `ecc-review-max-bytes` (200,000 by default) is named rather than printed, which is what usually happens to a lock file a package manager rewrote.

Outside a Git repository there is no tree to compare against, so files are diffed against what the CLI reported them holding before the session's first change — the only place the old behaviour remains.

| Key | Action |
|---|---|
| `c` | Comment on the line at point, or on the whole hunk from its `@@` line (again to edit it) |
| `{` / `}` | Previous / next comment |
| `a` | Show or hide Claude's comments |
| `l` | Jump to a comment |
| `d` | Remove a comment on this line, yours or Claude's |
| `e` | Edit the proposed content (reviewing one proposal) |
| `C-c C-c` | Send your comments as a prompt (`C-u C-c C-c` to edit it first) |
| `C-c C-k` | Drop the review and its comments |
| `g` | Read the diff again (see [Following the files](#following-the-files)) |
| `q` | Bury the buffer |

The buffer uses read-only `diff-mode`: `n` and `p` move between hunks, `N` and `P` between files, and `RET` jumps to the source.

Each comment belongs to the line you made it on. On a removed line (`-`), it is about the old side. On an added line (`+`) or a context line, it is about the new side. On the `@@` line, it is about the whole hunk. The comment appears under its line as `▎ #3 text`, its hunk gets a bold header, and the header line counts the comments. Every comment has a number, and no two comments in a buffer share one.

`g` reads the diff again and keeps every comment and your place in it. A window of the review in another tab starts again from the top. Each comment goes back to the line that still says what its line said, between the same neighbouring lines, even when a change higher up in the file has moved that line. It follows the line for up to `ecc-review-note-max-shift` (100) lines. If the line is gone, ecc keeps the comment, marks it `[outdated]`, and shows it above the first hunk of its file. The comment is still sent, with the hunk as it was.

## Following the files

An open review reads the diff again when the files may have changed: when a tool of its session finishes, when a turn ends, and when you save a file of its repository in Emacs. A shell command or a script counts as much as an edit, and so does another session working in the same repository. A tool that only reads, such as Read or Grep, does not count. Your comments and your place are kept, as with `g`.

The review waits half a second, longer while you are typing, and reads several changes in one go. If the diff has not changed, the buffer is left as it is. A review on the screen reads the diff at once. A review out of sight waits until you show it again. The review never takes the focus, never moves a window, and leaves a prompt you are typing alone. When every change has gone, for example because it was committed, the review stays open and says so. `g` on such a review still reports that there is nothing to show. If the diff cannot be read, for example because the directory is gone, the header line says why and the review waits until you press `g`. The review of a single proposal is never read again.

Only the diff buffer follows the files. A review in ediff (`ecc-review-style` set to `'ediff`) does not, yet.

To turn this off and read the diff only with `g`:

```elisp
(setq ecc-review-auto-refresh nil)
```

## Sending comments

`C-c C-c` collects your comments into a single prompt and sends it, closing the review. The comments are the prompt, so there is usually nothing to add; `C-u C-c C-c` opens it in a buffer of its own first:

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

A line comment has its line in the heading, as in `## hello.py  L3 (new)`, and still carries the whole hunk. If the line has gone, the heading ends with `(outdated)`. A reply to Claude starts with `In reply to Claude's #4:` and quotes the comment it answers.

There, `C-c C-c` sends the prompt as it stands, while `C-c C-k` returns to the diff.

## Reviewing the working tree

Where `ecc-review` starts from the moment the session began, `ecc-review-worktree` starts from the last commit. Press `G` in the menu, type `C-c c G`, or run `M-x ecc-review-worktree`.

This diffs the project's entire repository against `HEAD` — every uncommitted change, staged or unstaged, plus the untracked files (those `.gitignore` excludes are left out; a binary file, or one larger than `ecc-review-max-bytes`, is named rather than printed). A repository with no commits yet is compared against the empty tree, so the first code written in a project can be reviewed before it is committed.

`C-u G` prompts for what to diff against, then for the files to include:

- A revision such as `HEAD~1` compares it with the working tree, untracked files included.
- A range such as `main...HEAD`, `HEAD~1..HEAD` or `HEAD^!` compares commits, without untracked files.
- Nothing compares the index with the working tree: the unstaged changes.
- `--staged` (or `--cached`) compares `HEAD` with the index: the staged changes alone. The buffer name says `staged changes`.

For the files, choose any number with completion; leave it empty for all of them. `g` and [following the files](#following-the-files) keep the choice. Whether a range involves the working tree is decided by `git rev-parse`, not by reading the text. A range that starts with `-` is refused, so no git option gets in.

The project is determined by the current buffer, and comments go to that project's session. If none exists, ecc offers to start one, which is the usual entry point. Commenting and sending work as described above, and the two reviews use separate buffers.

Hunks are as small as the change itself, since a comment includes the entire hunk it annotates. Setting `(setq ecc-review-context-lines 3)` widens them: the value is passed to git as `-U` when ecc runs it, so no `git config` is read or written. Proposals retain three lines of context either way via `ecc-review-proposal-context-lines`.

## Comments from Claude

With the [Emacs MCP server](/emacs-claude-code/start/installation/) on (`ecc-mcp-enabled`), the review works both ways. Claude can open the review, comment on its lines, and scroll it to the place it is talking about. Ask in plain words, for example "walk me through these changes in the review" or "review the diff and leave comments."

Claude's comments appear as `▎ #4 Claude: text`, in a face of their own, `ecc-review-agent-comment-face`. Press `c` on a line that has only a comment from Claude to reply to it. Your reply appears indented under it. `a` hides Claude's comments and shows them again, and the header line keeps counting them while they are hidden. `C-c C-c` sends only your comments, since Claude already knows what it wrote.

| Tool | What Claude does with it |
|---|---|
| `review_open` | Opens the session's changes, the working tree against a range, or the staged changes (`staged`), optionally for some files only (`paths`), or reads the review again |
| `review_hunks` | Lists the files and the numbered hunks, optionally with their text |
| `review_comment` | Puts a comment on a line (`side` `new` or `old`), on a hunk, or under another comment (`reply_to`) |
| `review_comment_apply` | Puts several comments at once, and puts none when one of them is wrong |
| `review_navigate` | Scrolls the review to a line, a hunk, a comment, or the next or previous comment |
| `review_list_comments` | Reads the comments, the user's with the hunk they are on |
| `review_remove_comment` | Removes one comment, including one of yours it has dealt with |
| `review_clear_comments` | Removes Claude's comments, yours too only when asked |

Claude cannot write or change your comments, but it can remove them. Each tool works on the review of the session that calls it, so two sessions never touch each other's reviews.

The tools never take the keyboard. A review that Claude opens or moves appears beside the session without being selected. No session window is hidden, so a prompt you are typing stays where it is. The review never takes the window you are in, and never switches to another tab or Space. It goes into the window of another review of the same session first, then into a free window, and last into half of the session's window. `q` deletes a window made for it. If you wrote a `display-buffer-alist` rule for review buffers, the review follows it, as long as the rule leaves your window and tab alone. If the session is not on the screen, or no other window is free, nothing comes forward. The review waits in its buffer, already at the place Claude chose.

These tools only put text into a buffer and move a window. They write no files, so Emacs allows them without asking, and the transcript records each call as `auto-allowed`. To be asked as with any other tool, set `ecc-review-agent-auto-allow` to `nil`. Claude always uses the diff buffer, even when `ecc-review-style` is `'ediff`. It cannot read a review you have open in ediff yet. The tools tell Claude that you are reviewing there, and your comments reach it when you send them.

## Opening the review in ediff

`ecc-review-style` controls how `D` and `G` show changes. The default, `'diff`, uses the single `diff-mode` buffer described above. Setting it to `'ediff` shows the files side by side instead:

```elisp
(setq ecc-review-style 'ediff)
```

All files in the review open in a single ediff session instead of one session per file. The original contents are concatenated into the left buffer, and the new contents into the right buffer. A separator line like `═══ path ═══` marks each file, preceded by a blank line so files do not run together. Because all changes are in one session, `n` and `p` move through every difference across the entire review, crossing directly from one file into the next. Any file that git considers binary, or that is larger than `ecc-review-max-bytes`, appears only as a separator line, such as `═══ photo.png (binary, not shown) ═══`, and contains no differences.

The two buffers appear side by side. `ecc` sets `ediff-split-window-function` only in the review control buffer, so all other ediff sessions keep your configured window layout.

Both buffers are read-only, so ediff's `a` and `b` copy commands do nothing here. You read the changes, add comments, and send them. Claude then updates the files on disk using the prompt generated from your comments.

| Key | Action |
|---|---|
| `c` | Comment on the current difference (press again to edit it) |
| `l` | Jump to a comment |
| `d` | Remove the comment on the current difference |
| `C-c C-c` | Send the comments as a prompt (`C-u C-c C-c` to edit it first) |
| `C-c C-k` | Drop the review and its comments |
| `q` | Quit the review |
| `?` | Show the full help (press again to hide it) |

Comments work much as they do in the diff buffer, except that a comment belongs to a whole difference rather than to one line. They include the file name and line numbers, and the prompt sent to the session has the same form. Claude's comments appear only in the diff buffer. Sending comments, pressing `C-c C-k`, or pressing `q` restores the window configuration you had before opening the review. There is no `g` command here. To refresh the review, quit and open it again.

## Reviewing proposals before approval

![The text of a proposed Write, changed in a buffer and then allowed with the change](../../../assets/proposal.gif)

While a tool permission request is pending in the transcript, pressing `c` on the request node reviews that change, and `e` opens its proposed content (see [Prompt and transcript](/emacs-claude-code/features/prompt/#on-a-pending-request-node)).

Comments here are sent as the **reason for the denial**, allowing Claude to propose again rather than being corrected after the write.

`e` opens the proposal in the target file's major mode. `C-c C-c` allows the change using your text instead of Claude's and sends a diff of what you altered; `C-c C-k` leaves the request pending.

## Plan mode

Exiting plan mode sends the plan as a request. ecc opens it in an editable buffer beside the session.

![A plan opened in its own buffer, the permission mode chosen, and the plan approved](../../../assets/plan.gif)

Feedback can take three forms: a line comment (`C-c C-a`, removed with `C-c C-r`), an inline `@claude: …` marker, or an edit to the plan itself (`C-c C-d` diffs it).

With any feedback present, `C-c C-c` returns the plan with that feedback and requests a revision. Without feedback, it approves and prompts for a permission mode: `C-c C-p` chooses one; otherwise, `ecc-plan-default-mode` (`"acceptEdits"`) is used.

| Key | Action |
|---|---|
| `C-c C-c` | Approve, or send any feedback |
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

Hidden windows are not saved. `C-c c V` (`ecc-space-reset-windows`) lays the whole tab out again, and `C-c c v` brings back one session at a time. The remaining options are in the [configuration reference](/emacs-claude-code/reference/configuration/).
