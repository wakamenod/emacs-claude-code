---
title: Key binding reference
description: Every key ecc binds, from any buffer, in a session and in the buffers a session opens.
sidebar:
  order: 3
---

`C-c ?` opens the menu from anywhere in a session, and `C-h m` in any of these
buffers lists its bindings as Emacs sees them.

## From any buffer

`ecc-global-map` is a prefix keymap; bind it wherever you like. The README
suggests `C-c c`:

```elisp
(use-package ecc
  :bind-keymap ("C-c c" . ecc-global-map))
```

Or, without `use-package`:

```elisp
(global-set-key (kbd "C-c c") ecc-global-map)
```

These work while you are editing anything at all, which is the point: a session
that stops for a permission does not make you go and find it first.

| Key | Command | Action |
|---|---|---|
| `a` | `ecc-answer-allow` | Allow the oldest waiting request |
| `d` | `ecc-answer-deny` | Deny the oldest waiting request, asking for a reason |
| `1`–`4` | `ecc-answer-option-N` | Answer the oldest question with option N |
| `n` | `ecc-next-attention` | Jump to the next request waiting, across sessions, in arrival order, wrapping around |
| `N` | `ecc-next-attention-in-project` | The same, restricted to sessions of the current project |
| `b` | `ecc-dashboard` | Show the sessions this Emacs runs |
| `D` | `ecc-review` | Open every change of the session as one diff |
| `h` | `ecc-history-open` | Open a recorded conversation |
| `?` | `ecc-menu` | Open the menu |

Every key here means in the menu what it means here, so one letter carries
one meaning wherever it is pressed. `?` is the exception, because it is what
opens that menu — and the only way to reach it from a buffer that is not a
session.

## In a session buffer

A session buffer holds two regions: the read-only transcript at the top and the
editable prompt at the bottom, separated by a divider. **They have different
keymaps.** `ecc-chat-mode-map` is the mode map and is what the prompt obeys;
the transcript carries `ecc-chat-transcript-map` as a text property, and a key
that map does not define falls through to the mode map.

### The prompt

Everything here is `RET`, `TAB` or a key under the mode prefix, so that a letter
stays a letter. The one exception is `/`, which inserts itself and then offers
the slash commands.

| Key | Command | Action |
|---|---|---|
| `RET` | `ecc-chat-return` | Insert a newline — or send, if `ecc-chat-return-sends` is `t` |
| `S-RET`, `C-j` | `ecc-chat-newline` | Insert a newline |
| `C-c C-c` | `ecc-prompt-send` | Send the prompt |
| `C-c C-k` | `ecc-prompt-clear` | Clear the prompt |
| `TAB` | `ecc-chat-tab` | Completion |
| `/` | `ecc-chat-slash` | Insert `/` and offer the slash commands |
| `C-k` | `ecc-chat-kill-line` | Kill the line without crossing into the transcript |
| `S-TAB` | `ecc-chat-cycle-permission-mode` | Cycle the permission mode |
| `C-c C-g` | `ecc-session-interrupt` | Interrupt the running turn |
| `C-c C-q` | `ecc-prompt-show-queue` | Show what is queued to be sent |
| `C-c C-r` | `ecc-prompt-resend-last` | Send the last prompt again |
| `C-c C-x` | `ecc-prompt-toggle-context` | Attach or detach the editor's context |
| `C-c C-i` | `ecc-prompt-insert-image` | Insert an image |
| `C-c C-s` | `ecc-hint-accept-suggestion` | Accept the suggestion the CLI offered |
| `M-p`, `C-<up>` | `ecc-prompt-history-previous` | Previous prompt from the history |
| `M-n`, `C-<down>` | `ecc-prompt-history-next` | Next prompt from the history |
| `C-c C-n` | `ecc-chat-next-turn` | Next turn |
| `C-c C-p` | `ecc-chat-previous-turn` | Previous turn |
| `C-c C-a` | `ecc-perm-allow` | Allow the tool permission |
| `C-c C-d` | `ecc-perm-deny` | Deny the tool permission |
| `C-c C-b` | `ecc-btw-show` | Show the side questions |
| `C-c C-t` | `ecc-switch-session` | Show another session in this window |
| `C-c C-e` | `ecc-session-export-markdown` | Export the conversation as Markdown |
| `C-c ?` | `ecc-menu` | Open the menu |

:::note[Why there is no `C-c <letter>` here]
Every key under the prefix is `C-c C-<letter>`. The Emacs Lisp manual
reserves `C-c <letter>` for users, and says it is the only space reserved
for them, so a mode that takes one blocks the only keys its user is
entitled to. A command that finds no `C-c C-<letter>` free goes to the menu
rather than taking one — which is why allowing everything waiting, the
dashboard and the diff review are reached through `C-c ?` or the global map
instead of a key of their own.
:::

### The transcript

Single letters, because nothing here is being typed into.

| Key | Command | Action |
|---|---|---|
| `TAB` | `ecc-chat-toggle` | Fold or unfold the node at point |
| `S-TAB` | `ecc-chat-cycle-permission-mode` | Cycle the permission mode |
| `RET` | `ecc-session-visit` | Visit what is at point — the file, the full result, the whole diff |
| `n` / `p` | `ecc-chat-next-heading` / `ecc-chat-previous-heading` | Next / previous heading |
| `M-n` / `M-p` | `ecc-chat-next-sibling` / `ecc-chat-previous-sibling` | Next / previous sibling at the same depth |
| `^` | `ecc-chat-up-heading` | Up to the parent heading |
| `]` / `[` | `ecc-chat-next-block` / `ecc-chat-previous-block` | Next / previous block |
| `1`–`4` | `ecc-chat-show-level-N` | Show the tree to depth N |
| `+` / `-` | `ecc-chat-expand-all` / `ecc-chat-collapse-all` | Expand / collapse everything |
| `SPC` / `DEL` | `scroll-up-command` / `scroll-down-command` | Scroll |
| `i` | `ecc-chat-goto-prompt` | Go to the prompt |
| `a` | `ecc-perm-allow` | Allow the waiting request |
| `d` | `ecc-session-review-or-deny` | Review the change, or deny |
| `f` | `ecc-chat-goto-files` | Go to the Files section |
| `P` | `ecc-chat-goto-plans` | Go to the Plan section |
| `T` | `ecc-session-timeline` | Pick a turn |
| `w` | `ecc-session-copy-at-point` | Copy what is at point |
| `g` | `ecc-session-refresh` | Draw it again |
| `L` | `ecc-session-show-log` | Show the raw protocol log |
| `t` | `ecc-tui-open` | Hand the session over to the terminal |
| `R` | `ecc-session-resume` | Resume the session |
| `C-c C-k` | `ecc-session-interrupt` | Interrupt the running turn |
| `q` | `quit-window` | Bury the buffer |
| `?` | `ecc-menu` | Open the menu |

### On a node waiting for an answer

A node that is waiting carries a keymap of its own, which inherits the
transcript map above. These keys are live only with point inside that node.

A node adds keys the transcript leaves free; it does not give an existing one
a new meaning. Point is what selects these maps, and point is easy to
misjudge, so a letter that meant one thing a line earlier would fire the wrong
command with no warning. `d` is the exception, and only because the two agree:
`ecc-session-review-or-deny` sends it to `ecc-perm-deny` as soon as point is
on a request.

| Key | Command | Action |
|---|---|---|
| `RET` | `ecc-session-visit` | Visit what is proposed |
| `a` | `ecc-perm-allow` | Allow it, once |
| `d` | `ecc-perm-deny` | Deny it |
| `A` | `ecc-perm-allow-always` | Allow it, and every one like it from now on |
| `u` | `ecc-perm-approve-turn` | Allow everything until the turn ends |
| `r` | `ecc-perm-add-pattern` | Allow by a rule — a pattern you give, saved to the project settings |
| `c` | `ecc-review-comment-request` | Comment on what is proposed |
| `e` | `ecc-review-edit-proposal` | Edit the proposal before allowing it |

### On a file in the Files section

| Key | Command | Action |
|---|---|---|
| `RET` | `ecc-session-visit` | Visit the file |
| `d` | `ecc-session-review-file` | Review this file's changes |

`TAB` folds the row, as it does everywhere else in the transcript, and `SPC`
scrolls.

## The buffers a session opens

### Diff review (`ecc-review-mode`)

Every change of the session as one `diff-mode` buffer. Comments are collected
hunk by hunk and sent as a single prompt. The buffer is read-only, so a letter
is free to be a command; these keys come before `diff-mode`'s own, which use
only `k`, `K`, `n`, `N`, `o`, `p` and `P`.

| Key | Command | Action |
|---|---|---|
| `c` | `ecc-review-comment` | Comment on the hunk at point |
| `l` | `ecc-review-list-comments` | List the comments so far |
| `d` | `ecc-review-remove-comment` | Remove the comment at point |
| `e` | `ecc-review-edit-proposal` | Edit the proposal |
| `C-c C-c` | `ecc-review-send` | Send every comment as one prompt |
| `C-c C-k` | `ecc-review-quit` | Quit without sending |
| `g` | `ecc-review-refresh` | Read the changes again |
| `q` | `quit-window` | Bury the buffer |

The prompt is shown for confirmation before it goes: `C-c C-c` sends it,
`C-c C-k` cancels. The same two keys apply or cancel an edited proposal.

### Plan review (`ecc-plan-mode`)

The plan from an ExitPlanMode request, in a writable buffer. The plan is
edited here, so a letter has to stay a letter and every command sits under
`C-c C-`.

| Key | Command | Action |
|---|---|---|
| `C-c C-c` | `ecc-plan-approve` | Approve the plan |
| `C-c C-k` | `ecc-plan-deny` | Deny it |
| `C-c C-a` | `ecc-plan-comment` | Add a note on the line at point |
| `C-c C-r` | `ecc-plan-remove-comment` | Remove that note |
| `C-c C-d` | `ecc-plan-show-diff` | Show what you changed in the plan |
| `C-c C-p` | `ecc-plan-set-mode` | Choose the permission mode to approve into |
| `C-c C-n` | `ecc-plan-next-change` | Next change |

Feedback reaches the model three ways: a comment on a line, an edit to the plan
text itself, or a plain denial with a reason.

### Answering a question (`ecc-question-mode`)

The buffer an AskUserQuestion is answered in.

| Key | Command | Action |
|---|---|---|
| `1`, `2`, … | `ecc-question-choose` | Choose the option of that number |
| `SPC`, `RET` | `ecc-question-toggle-at-point` | Toggle the option at point |
| `o` | `ecc-question-other` | Write an answer of your own |
| `n`, `TAB` / `p`, `S-TAB` | `ecc-question-next` / `ecc-question-previous` | Next / previous option |
| `u` | `ecc-question-clear` | Clear the selection |
| `C-c C-c` | `ecc-question-submit` | Submit |
| `C-c C-k` | `ecc-question-cancel` | Cancel |

### Dashboard (`ecc-dashboard-mode`)

| Key | Command | Action |
|---|---|---|
| `RET` | `ecc-dashboard-visit` | Go to that session |
| `+` | `ecc-dashboard-new` | Start a session |
| `k` | `ecc-dashboard-stop` | Stop it |
| `D` | `ecc-dashboard-delete` | Delete it |
| `r` | `ecc-dashboard-rename` | Rename it |
| `R` | `ecc-dashboard-resume` | Resume it |
| `a` / `d` | `ecc-dashboard-allow` / `ecc-dashboard-deny` | Allow / deny its waiting request |
| `C` | `ecc-capabilities-show` | What that session can do |
| `U` | `ecc-usage` | Usage |
| `g` | `ecc-dashboard-refresh` | Refresh |

### Capabilities (`ecc-capabilities-mode`)

The skills, agents, commands, MCP servers and plugins a session has.

| Key | Command | Action |
|---|---|---|
| `RET` | `ecc-capabilities-visit` | Visit what is at point |
| `TAB` | `ecc-capabilities-toggle` | Fold or unfold |
| `g` | `ecc-capabilities-refresh` | Refresh |

### Usage (`ecc-usage-mode`)

| Key | Command | Action |
|---|---|---|
| `g` | `ecc-usage-refresh` | Ask again |
| `b` | `ecc-usage-toggle-behaviors` | Show or hide what happens at each limit |
| `q` | `ecc-usage-hide` | Take it away |

### Side questions (`ecc-btw-mode`)

| Key | Command | Action |
|---|---|---|
| `a` | `ecc-btw-ask-again` | Ask something else |
| `c` | `ecc-btw-copy` | Copy the answer |
| `k` | `ecc-btw-cancel` | Cancel the question in flight |
| `x` | `ecc-btw-clear` | Clear what is shown |
| `g` | `ecc-btw-refresh` | Refresh |
| `q` | `ecc-btw-hide` | Hide it |

## In your own source buffer

These two are not in a session buffer at all: they are what you reach for from
the code itself. Each puts a keymap over the region it is working on, in force
only until you accept or dismiss the answer.

### An inline answer (`ecc-inline-prompt`)

| Key | Command | Action |
|---|---|---|
| `n` / `p` | `ecc-inline-scroll-down` / `ecc-inline-scroll-up` | Scroll the answer |
| `r` | `ecc-inline-prompt` | Ask something else |
| `q` | `ecc-inline-quit` | Take it away |

### A rewrite waiting to be accepted (`ecc-rewrite`)

Nothing is written to the buffer until you accept it.

| Key | Command | Action |
|---|---|---|
| `RET`, `y` | `ecc-rewrite-accept` | Accept the rewrite |
| `d` | `ecc-rewrite-diff` | See it as a diff first |
| `m` | `ecc-rewrite-merge` | Merge it by hand |
| `n` / `p` | `ecc-inline-scroll-down` / `ecc-inline-scroll-up` | Scroll |
| `q` | `ecc-rewrite-cancel` | Cancel, changing nothing |
