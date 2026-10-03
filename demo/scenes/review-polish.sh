# The order of the scene of demo/scenes/review-polish.el, and how long
# each step is held.  Read by demo/record.sh, which defines `e' (run a
# form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh review-polish
#
# One real session is started and nothing is sent to it.

say "Phase 5 of the review comments: b says its sides; ediff shows what changed in a line"; sleep 5
e "(demo-frame)"; sleep 1
e "(demo-start-session)"; sleep 8
e "(demo-frame)"; sleep 2

say "1. C-c c D, b: the base, the before side -- develop is 2 behind, so origin/develop is the default"; sleep 5
e "(demo-open-menu)"; sleep 3
e "(demo-branch)"; sleep 12
e "(demo-frame)"; sleep 2
e "(demo-report-review)"; sleep 4

say "2. n: the current difference marks the words that changed, and so does the one beside it"; sleep 5
e "(demo-key \"n\")"; sleep 3
e "(demo-report-faces)"; sleep 6

say "3. n again: the same, on the next pair"; sleep 4
e "(demo-key \"n\")"; sleep 3
e "(demo-report-faces)"; sleep 6
e "(demo-report-review)"; sleep 3

e "(demo-quit)"; sleep 3
e "(demo-save-log \"/tmp/ecc-demo-review-polish-log.txt\")"; sleep 2
say "That is Phase 5."; sleep 4
