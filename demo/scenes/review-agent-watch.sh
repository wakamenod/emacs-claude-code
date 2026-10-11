# The order of the scene of demo/scenes/review-agent-watch.el, and how
# long each step is held.  Read by demo/record.sh, which defines `e' (run
# a form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh review-agent-watch
#
# One real session is started and nothing is sent to it: review_open is
# called the way the CLI would call it, and a finished tool is the hook
# the dispatcher runs, so the scene costs nothing.

say "Phase 2 of the review comments: the review follows the files"; sleep 5
e "(demo-frame)"; sleep 1
e "(demo-start-session)"; sleep 8
e "(demo-frame)"; sleep 2
e "(demo-claude-edits)"; sleep 3

say "1. Claude opens the review.  The user comments on a line, and goes back to the prompt"; sleep 5
e "(demo-type-in-prompt \"\")"; sleep 2
e "(demo-tool \"review_open\")"; sleep 4
e "(demo-go-to-review-line \"+    result = a - b\")"; sleep 3
e "(demo-key \"c\" \"Why the temporary?\")"; sleep 4
e "(demo-report-comments)"; sleep 4
e "(demo-type-in-prompt \"Once that is done, \")"; sleep 3
e "(demo-report \"1 before\")"; sleep 5

say "2. A shell command adds three lines at the top of calc.py.  Nobody presses g"; sleep 5
e "(demo-shell-edit-above)"; sleep 1
e "(demo-tool-finished \"three lines added at the top of calc.py\")"; sleep 4
e "(demo-report \"2 after the tool\")"; sleep 6
e "(demo-report-comments)"; sleep 5
e "(demo-keep-typing \"please check the tests\")"; sleep 5

say "3. greet.py is saved in Emacs: the review follows that too"; sleep 5
e "(demo-save-greet)"; sleep 4
e "(demo-report \"3 after the save\")"; sleep 6
e "(demo-report-top)"; sleep 5

say "4. The review goes out of sight, and the files change again"; sleep 5
e "(demo-hide-review)"; sleep 3
e "(demo-shell-edit-below)"; sleep 1
e "(demo-tool-finished \"div added at the end of calc.py\")"; sleep 4
e "(demo-report \"4 hidden, after the tool\")"; sleep 6
say "Shown again, it reads the diff then"; sleep 4
e "(demo-show-review)"; sleep 4
e "(demo-report \"4 shown again\")"; sleep 6
e "(demo-report-comments)"; sleep 5

e "(demo-save-log \"/tmp/ecc-demo-review-agent-watch-log.txt\")"; sleep 2

say "5. Every change is undone: the review stays open and says so"; sleep 5
e "(demo-revert-all)"; sleep 1
e "(demo-tool-finished \"git checkout -- .\")"; sleep 4
e "(demo-report \"5 after the checkout\")"; sleep 5
e "(demo-report-top)"; sleep 6
e "(demo-report-comments)"; sleep 5

e "(demo-cleanup)"; sleep 3
e "(demo-save-log \"/tmp/ecc-demo-review-agent-watch-log.txt\")"; sleep 2
say "That is Phase 2's watch."; sleep 4
