# The order of the scene of demo/scenes/review-menu.el, and how long each
# step is held.  Read by demo/record.sh, which defines `e' (run a form in
# the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh review-menu
#
# Two real sessions are started and nothing is sent to either.

say "Phase 4 of the review comments: C-c c D asks what to compare"; sleep 5
e "(demo-frame)"; sleep 1
e "(demo-start-sessions)"; sleep 10
e "(demo-frame)"; sleep 2
e "(demo-work)"; sleep 3
e "(demo-report-commits)"; sleep 3

say "1. C-c c D: each comparison with the number of files it shows"; sleep 4
e "(demo-open-menu)"; sleep 4
e "(demo-report-menu \"1 opened\")"; sleep 8

say "2. S sends the comments to the other session"; sleep 4
e "(demo-switch-session)"; sleep 5
e "(demo-report-menu \"2 after S\")"; sleep 6

say "3. b RET RET: this branch, with its working tree, against develop"; sleep 4
e "(demo-branch)"; sleep 6
e "(demo-report-review \"3 b RET RET\")"; sleep 8

say "4. C-c c D again: b is marked, and the cursor starts on it"; sleep 4
e "(demo-open-menu)"; sleep 4
e "(demo-report-menu \"4 reopened\")"; sleep 7

say "5. c on one commit, add util: that commit alone"; sleep 4
e "(demo-one-commit)"; sleep 7
e "(demo-report-review \"5 c X RET\")"; sleep 8

e "(demo-close-menu)"; sleep 1
e "(demo-cleanup)"; sleep 3
e "(demo-save-log \"/tmp/ecc-demo-review-menu-log.txt\")"; sleep 2
say "That is Phase 4."; sleep 4
