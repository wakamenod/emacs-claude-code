# The order of the scene of demo/scenes/review-agent-ediff.el, and how
# long each step is held.  Read by demo/record.sh, which defines `e' (run
# a form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh review-agent-ediff
#
# One real session is started and nothing is sent to it: the tools are
# called the way the CLI would call them, and a finished tool is the hook
# the dispatcher runs, so the scene costs nothing.

say "Phase 3 of the review comments: Claude in the ediff review"; sleep 5
e "(demo-frame)"; sleep 1
e "(demo-start-session)"; sleep 8
e "(demo-frame)"; sleep 2
e "(demo-claude-edits)"; sleep 3

say "1. D opens the review in ediff: the left as it was, the right as it is"; sleep 4
e "(demo-open-review)"; sleep 4
e "(demo-frame)"; sleep 2
e "(demo-place-panel)"; sleep 1
e "(demo-frame)"; sleep 3
e "(demo-tool \"review_hunks\")"; sleep 6

say "2. Claude comments on a line taken out (left) and a line put in (right)"; sleep 5
e "(demo-tool \"review_comment\" '((file . \"calc.py\") (line . 6) (side . \"old\") (text . \"This was the whole of sub before.\")))"; sleep 4
e "(demo-tool \"review_comment\" '((file . \"calc.py\") (line . 7) (text . \"Why the temporary?\")))"; sleep 4
e "(demo-report-comments)"; sleep 6

say "3. Claude moves the view to its comment; the keyboard stays where it is"; sleep 5
e "(demo-report \"3 before\")"; sleep 3
e "(demo-tool \"review_navigate\" '((comment_id . 2)))"; sleep 4
e "(demo-report \"3 after\")"; sleep 6

say "4. The user answers with c.  Claude has two comments there, so c asks which; RET takes the latest"; sleep 6
e "(demo-key \"c\" \"\\rSo it can be logged later.\")"; sleep 5
e "(demo-report-comments)"; sleep 6

say "5. A shell command adds three lines at the top of calc.py.  Nobody presses !"; sleep 5
e "(demo-shell-edit-above)"; sleep 1
e "(demo-tool-finished \"three lines added at the top of calc.py\")"; sleep 5
e "(demo-report \"5 after the tool\")"; sleep 6
e "(demo-report-comments)"; sleep 6

say "6. Claude reads what the user wrote"; sleep 4
e "(demo-tool \"review_list_comments\" '((author . \"user\")))"; sleep 6

e "(demo-save-log \"/tmp/ecc-demo-review-agent-ediff-log.txt\")"; sleep 2
e "(demo-cleanup)"; sleep 3
e "(demo-save-log \"/tmp/ecc-demo-review-agent-ediff-log.txt\")"; sleep 2
say "That is Phase 3: the ediff review, both ways."; sleep 4
