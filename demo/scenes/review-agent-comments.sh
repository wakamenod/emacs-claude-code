# The order of the scene of demo/scenes/review-agent-comments.el, and how
# long each step is held.  Read by demo/record.sh, which defines `e' (run
# a form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh review-agent-comments
#
# One real session is started and nothing is sent to it: every tool is
# called the way the CLI would call it, so the scene costs nothing.

say "Phase 1 of the review comments: Claude comments on the review, over MCP"; sleep 5
e "(demo-frame)"; sleep 1
e "(demo-start-session)"; sleep 8
e "(demo-frame)"; sleep 2
e "(demo-claude-edits)"; sleep 4

say "1. The user is typing in the prompt.  Claude calls review_open"; sleep 5
e "(demo-type-in-prompt \"Once that is done, please also check \")"; sleep 3
e "(demo-report \"1 before\")"; sleep 5
e "(demo-tool \"review_open\")"; sleep 4
e "(demo-report \"1 after review_open\")"; sleep 7
e "(demo-keep-typing \"the tests of sub\")"; sleep 6

say "2. review_comment_apply: three comments, on two files, one on a removed line"; sleep 5
e "(demo-tool \"review_comment_apply\" '((comments . [((file . \"calc.py\") (line . 2) (text . \"One line is enough for a docstring this size.\")) ((file . \"calc.py\") (line . 6) (side . \"old\") (text . \"The one-line return was clearer; why the temporary?\")) ((file . \"greet.py\") (line . 5) (text . \"farewell has no caller yet.\"))])))"; sleep 4
e "(demo-report-comments)"; sleep 8
e "(demo-report \"2 after the comments\")"; sleep 6

say "3. review_navigate to the comment on greet.py -- the review scrolls, the prompt keeps the keyboard"; sleep 5
e "(demo-tool \"review_navigate\" '((file . \"greet.py\") (line . 5)))"; sleep 4
e "(demo-report \"3 after review_navigate\")"; sleep 7
e "(demo-keep-typing \" and of mul\")"; sleep 5

say "4. The user goes to the review: c on Claude's comment is a reply"; sleep 5
e "(demo-go-to-review-line \"-    return a - b\")"; sleep 3
e "(demo-key \"c\" \"It names the value for the debugger.\")"; sleep 5
e "(demo-report-comments)"; sleep 7
say "} and { move between the comments"; sleep 4
e "(demo-key \"}\")"; sleep 3
e "(demo-report \"4 after }\")"; sleep 5
e "(demo-key \"{\")"; sleep 3
e "(demo-report \"4 after {\")"; sleep 5
say "a hides Claude's comments, and shows them again"; sleep 4
e "(demo-key \"a\")"; sleep 4
e "(demo-report-comments)"; sleep 5
e "(demo-key \"a\")"; sleep 4
e "(demo-report-comments)"; sleep 5

say "5. calc.py changes on disk above the comments, and Claude opens the review again"; sleep 5
e "(demo-report \"5 before\")"; sleep 4
e "(demo-edit-above)"; sleep 3
e "(demo-tool \"review_open\")"; sleep 4
e "(demo-report \"5 after review_open\")"; sleep 7
e "(demo-report-comments)"; sleep 8

say "6. Back in the prompt.  A review of another range takes the same window"; sleep 5
e "(demo-type-in-prompt \"\")"; sleep 2
e "(demo-report \"6 before\")"; sleep 4
e "(demo-tool \"review_open\" '((range . \"HEAD\")))"; sleep 4
e "(demo-report \"6 after review_open HEAD\")"; sleep 7
say "q gives the window back: first the review it replaced, then the code it borrowed"; sleep 5
e "(demo-key \"q\")"; sleep 3
e "(demo-report \"6 after q\")"; sleep 5
e "(demo-key \"q\")"; sleep 3
e "(demo-report \"6 after q again\")"; sleep 6

say "7. The user is in the code now.  Claude opens the review: the session's window is divided"; sleep 6
e "(demo-go-to-source)"; sleep 3
e "(demo-report \"7 before\")"; sleep 4
e "(demo-tool \"review_open\")"; sleep 4
e "(demo-report \"7 after review_open\")"; sleep 7
say "q deletes the window that was made for it"; sleep 4
e "(demo-key \"q\")"; sleep 3
e "(demo-report \"7 after q\")"; sleep 6

e "(demo-cleanup)"; sleep 3
e "(demo-save-log \"/tmp/ecc-demo-review-agent-comments-log.txt\")"; sleep 2
say "That is Phase 1."; sleep 4
