# The order of the scene of demo/scenes/review-pr-commits.el, and how
# long each step is held.  Read by demo/record.sh, which defines `e' (run
# a form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh review-pr-commits
#
# No CLI is started and GitHub is not asked: gh is a script, and the
# session's process is a cat, so the scene costs nothing.

say "feat/review-pr-commits: a pull request read a commit at a time"; sleep 5
e "(demo-frame)"; sleep 2

say "1. C-c c D, p, #42: then which commit -- the whole PR first, oldest first, no merge"; sleep 5
e "(demo-open-menu)"; sleep 3
e "(demo-type \"p\" '(\"42\") \"RET\")"; sleep 9
say "   RET: the whole pull request, as p reviewed it before"; sleep 3
e "(demo-type \"RET\")"; sleep 4
e "(demo-report-diff \"1 whole\")"; sleep 5

say "2. ] goes to its first commit; c puts a comment on a hunk"; sleep 4
e "(demo-diff-key \"]\")"; sleep 3
e "(demo-diff-key \"n\")"; sleep 2
e "(demo-diff-key \"c\" \"Name the cache directory in one place\")"; sleep 3
e "(demo-report-diff \"2 commit 1\")"; sleep 5

say "   ] to the second commit, a comment there too: the header line counts the other one"; sleep 5
e "(demo-diff-key \"]\")"; sleep 3
e "(demo-diff-key \"n\")"; sleep 2
e "(demo-diff-key \"c\" \"Strip only the trailing newline\")"; sleep 3
e "(demo-report-diff \"2 commit 2\")"; sleep 6

say "   ] once more: 2 unsent in 2 other commits"; sleep 3
e "(demo-diff-key \"]\")"; sleep 3
e "(demo-report-diff \"2 commit 3\")"; sleep 6

say "   [ [ back to the first commit: its comment is where it was left"; sleep 4
e "(demo-diff-key \"[\")"; sleep 3
e "(demo-diff-key \"[\")"; sleep 3
e "(demo-report-diff \"2 back to 1\")"; sleep 6

say "3. In ediff: C-c c D, -e, p, #42, and the third commit straight from the question"; sleep 5
e "(demo-open-menu)"; sleep 3
e "(demo-type \"-\" \"e\" \"p\" '(\"42\") \"RET\")"; sleep 6
e "(demo-type '(\"3/4\"))"; sleep 3
e "(demo-type \"RET\")"; sleep 6
e "(demo-report-ediff \"3 commit 3\")"; sleep 5

say "   c on a line of the right window, then ] -- the review is quit and the next opened"; sleep 5
e "(demo-ediff-key \"n\")"; sleep 2
e "(demo-ediff-key \"c\" \"Is mtime fine enough on every filesystem?\")"; sleep 3
e "(demo-report-ediff \"3 commented\")"; sleep 3
e "(demo-ediff-key \"]\")"; sleep 6
e "(demo-report-ediff \"3 commit 4\")"; sleep 6

say "   [ back: the comment comes back with its commit"; sleep 4
e "(demo-ediff-key \"[\")"; sleep 6
e "(demo-report-ediff \"3 back to 3\")"; sleep 6

say "4. C-u C-c C-a: every commit's comments as one prompt, grouped by commit"; sleep 5
e "(demo-ediff-key \"C-u C-c C-a\")"; sleep 4
e "(demo-report-message \"4 to confirm\")"; sleep 12
say "   C-c C-c sends it; the reviews whose comments went are closed"; sleep 4
e "(demo-message-key \"C-c C-c\")"; sleep 4
e "(demo-report-sent \"4 sent\")"; sleep 2
e "(demo-report-reviews \"4 after\")"; sleep 5

e "(demo-close)"; sleep 2
e "(demo-save-log \"/tmp/ecc-demo-review-pr-commits-log.txt\")"; sleep 2
say "That is feat/review-pr-commits."; sleep 4
