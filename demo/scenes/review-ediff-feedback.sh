# The order of the scene of demo/scenes/review-ediff-feedback.el, and how
# long each step is held.  Read by demo/record.sh, which defines `e' (run
# a form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh review-ediff-feedback
#
# No CLI is started: the session's process is a cat, and every message
# Claude would send is handed to ecc-dispatch, so the scene costs nothing.

say "feat/review-ediff-feedback: keys-only header lines, the file at point, a coloured reply pane"; sleep 5
e "(demo-frame)"; sleep 1
e "(demo-open-session)"; sleep 1

say "1. Stacked: both header lines are the same line of keys, fitted to the width"; sleep 4
e "(demo-open-ediff)"; sleep 4
e "(demo-report \"1 open\")"; sleep 5

say "   s shows the files pane: narrower windows drop keys from the end, ? all keys stays"; sleep 5
e "(demo-type 'B \"s\")"; sleep 4
e "(demo-report \"1 files pane\")"; sleep 5
e "(demo-type 'B \"s\")"; sleep 3

say "2. Each mode line says the file at its cursor; the lower one adds where the review is"; sleep 5
e "(demo-report \"2 before n\")"; sleep 2
e "(demo-type 'B \"n\")"; sleep 3
e "(demo-report \"2 after n\")"; sleep 4
e "(demo-type 'B \"n\")"; sleep 3
e "(demo-report \"2 after n again\")"; sleep 4
e "(demo-type 'B \"p\")"; sleep 3
e "(demo-report \"2 after p\")"; sleep 4

say "   C-n out of the file: both mode lines follow the cursor"; sleep 4
e "(demo-type 'B \"C-n C-n C-n C-n C-n C-n C-n C-n C-n C-n\")"; sleep 4
e "(demo-report \"2 after C-n x10\")"; sleep 4

say "   v scrolls both windows"; sleep 3
e "(demo-type 'B \"v\")"; sleep 3
e "(demo-report \"2 after v\")"; sleep 4

say "   / cache: the hidden count is on the lower mode line"; sleep 4
e "(demo-type 'B \"/\" \"cache\")"; sleep 4
e "(demo-report \"2 after / cache\")"; sleep 5
e "(demo-type 'B \"/\" \"\")"; sleep 3

say "3. | side by side: the keys are cut in two again, the mode lines unchanged"; sleep 5
e "(demo-type 'B \"|\")"; sleep 4
e "(demo-report \"3 side by side\")"; sleep 6
e "(demo-type 'B \"|\")"; sleep 3
e "(demo-report \"3 stacked again\")"; sleep 3

say "4. The reply pane, coloured as the transcript: the prompt, a tool line, the reply"; sleep 5
e "(demo-ask)"; sleep 3
e "(demo-stream)"; sleep 4
e "(demo-report-pane \"4 streaming\")"; sleep 8
e "(demo-stream-end)"; sleep 2
e "(demo-report-pane \"4 finished\")"; sleep 8

e "(demo-close)"; sleep 2
e "(demo-save-log \"/tmp/ecc-demo-review-ediff-feedback-log.txt\")"; sleep 2
say "That is feat/review-ediff-feedback."; sleep 4
