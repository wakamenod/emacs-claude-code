# The order of the scene of demo/scenes/review-baseline.el, and how long
# each step is held.  Read by demo/record.sh, which defines `e' (run a
# form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh review-baseline
#
# Two real sessions are started.  The comments at the end are really
# sent, which is the change being shown: C-c C-c sends now.

say "0.3.0 -- the review is git against git: D since the session started, G since the last commit"; sleep 6
e "(demo-frame)"; sleep 1
e "(demo-open-source)"; sleep 5

say "1. A session in the project.  What the tree holds now is its baseline"; sleep 5
e "(demo-start-session)"; sleep 8
e "(demo-report-baseline)"; sleep 7

say "2. The work -- done by a script, not by an Edit or a Write.  The old review saw none of this"; sleep 7
e "(demo-do-the-work)"; sleep 7
e "(demo-commit-some-of-it)"; sleep 8

say "3. D -- ecc-review.  Everything that changed since the session started"; sleep 5
e "(demo-open-review)"; sleep 5
e "(demo-frame)"; sleep 2
e "(demo-report-review)"; sleep 9
say "greet.py was rewritten by a script, NOTES.md was never a tool call, README.md was committed -- all three are here"; sleep 9

say "4. G -- ecc-review-worktree.  The same moment, against HEAD"; sleep 5
e "(demo-open-worktree-review)"; sleep 5
e "(demo-frame)"; sleep 2
e "(demo-report-worktree-review)"; sleep 10
say "That is the one difference between them: D keeps what the session committed, G does not"; sleep 8

say "5. The comments.  c on a hunk, twice"; sleep 5
e "(demo-open-review)"; sleep 3
e "(demo-goto-first-hunk)"; sleep 2
e "(demo-key \"c\" \"an f-string is right, but keep the docstring\")"; sleep 6
e "(demo-report-comments)"; sleep 5
e "(demo-key \"n\")"; sleep 2
e "(demo-key \"c\" \"NOTES.md should say who wrote it\")"; sleep 6
e "(demo-report-comments)"; sleep 5

say "6. l lists them, d takes one off"; sleep 4
e "(demo-key \"l\" \"\")"; sleep 6
e "(demo-key \"d\")"; sleep 3
e "(demo-report-comments)"; sleep 6
e "(demo-key \"c\" \"and name the script in it\")"; sleep 6

say "7. The header line says which key does which"; sleep 4
e "(demo-report-header)"; sleep 9

say "8. C-u C-c C-c still opens the prompt to add something to"; sleep 5
e "(demo-key \"C-c C-c\" nil (quote (4)))"; sleep 5
e "(demo-frame)"; sleep 2
say "C-c C-k there goes back to the review without sending"; sleep 5
e "(demo-cancel-message)"; sleep 5

say "9. C-c C-c on its own SENDS now -- no second buffer, no second C-c C-c"; sleep 6
e "(demo-key \"C-c C-c\")"; sleep 6
e "(demo-show-session)"; sleep 8
e "(demo-frame)"; sleep 2
say "The comments are the prompt: each one carries its hunk and the sentence written about it"; sleep 8

say "10. And a repository with no commit at all, where G used to stop at exit 128"; sleep 7
e "(demo-build-unborn)"; sleep 6
e "(demo-start-unborn-session)"; sleep 8
e "(demo-open-unborn-review)"; sleep 5
e "(demo-frame)"; sleep 2
e "(demo-report-unborn-review)"; sleep 9
say "The file added and the file git never saw, both of them -- the whole of a project's first code"; sleep 8

e "(demo-cleanup)"; sleep 5
say "That is the whole of the review's new baseline."; sleep 6
