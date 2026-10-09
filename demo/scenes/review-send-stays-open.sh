# The order of the scene of demo/scenes/review-send-stays-open.el, and how
# long each step is held.  Read by demo/record.sh, which defines `e' (run
# a form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh review-send-stays-open
#
# One real session is started and nothing is sent to it: the prompts of
# C-c C-c are caught and logged, and Claude's replies are made through
# the MCP tool the CLI would call, so the scene costs nothing.

say "C-c C-c sends the comments and keeps the review open"; sleep 5
e "(demo-frame)"; sleep 1
e "(demo-catch-prompts)"; sleep 1
e "(demo-start-session)"; sleep 8
e "(demo-frame)"; sleep 2
e "(demo-claude-edits)"; sleep 4
e "(demo-tool \"review_open\")"; sleep 5

say "1. Two comments of the user's, then C-c C-c"; sleep 5
e "(demo-go-to-review-line \"+    \\\"\\\"\\\"Add two numbers.\\\"\\\"\\\"\")"; sleep 3
e "(demo-key \"c\" \"One line is enough for a docstring this size.\")"; sleep 4
e "(demo-go-to-review-line \"+def farewell(name):\")"; sleep 3
e "(demo-key \"c\" \"Nothing calls farewell yet.\")"; sleep 4
e "(demo-report \"1 before C-c C-c\")"; sleep 5
e "(demo-key \"C-c C-c\")"; sleep 4
e "(demo-last-prompt)"; sleep 5
e "(demo-report \"1 after C-c C-c\")"; sleep 8

say "2. Claude answers each comment in the review, with reply_to"; sleep 5
e "(demo-tool \"review_comment\" '((reply_to . 1) (text . \"Agreed; I will put it on one line.\")))"; sleep 4
e "(demo-tool \"review_comment\" '((reply_to . 2) (text . \"It is for the CLI in the next commit; shall I leave it out until then?\")))"; sleep 4
e "(demo-report \"2 after Claude's replies\")"; sleep 8

say "3. A new comment, and C-c C-c sends that one alone"; sleep 5
e "(demo-go-to-review-line \"+    result = a - b\")"; sleep 3
e "(demo-key \"c\" \"The one-line return was clearer.\")"; sleep 4
e "(demo-report \"3 before C-c C-c\")"; sleep 5
e "(demo-key \"C-c C-c\")"; sleep 4
e "(demo-last-prompt)"; sleep 5
e "(demo-report \"3 after C-c C-c\")"; sleep 7

say "4. C-c C-c with nothing new says so"; sleep 4
e "(demo-key \"C-c C-c\")"; sleep 5
e "(demo-report \"4 after C-c C-c\")"; sleep 5

say "5. C-u C-c C-c: read the prompt over, send it, and come back to the review"; sleep 5
e "(demo-go-to-review-line \"+    return f\\\"hello {name}!\\\"\")"; sleep 3
e "(demo-key \"c\" \"Keep the exclamation mark out of the library.\")"; sleep 4
e "(demo-key \"C-c C-c\" nil '(4))"; sleep 6
e "(demo-message-key \"C-c C-c\")"; sleep 4
e "(demo-last-prompt)"; sleep 5
e "(demo-report \"5 after sending from the message buffer\")"; sleep 7

say "C-c C-k drops the review, as before"; sleep 4
e "(demo-key \"C-c C-k\")"; sleep 3
e "(demo-report \"6 after C-c C-k\")"; sleep 4

e "(demo-save-log \"/tmp/ecc-demo-review-send-stays-open-log.txt\")"; sleep 2
e "(demo-cleanup)"; sleep 3
say "That is C-c C-c keeping the review."; sleep 4
