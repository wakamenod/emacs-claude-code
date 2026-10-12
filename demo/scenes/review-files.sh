# The order of the scene of demo/scenes/review-files.el, and how long
# each step is held.  Read by demo/record.sh, which defines `e' (run a
# form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh review-files
#
# One real session is started and nothing is sent to it.

say "Phase 6 of the review comments: s lists the files, / filters them"; sleep 5
e "(demo-frame)"; sleep 1
e "(demo-start-session)"; sleep 8
e "(demo-frame)"; sleep 2
e "(demo-report-windows \"the session\")"; sleep 2

say "1. The ediff review: two lines of help in the control panel"; sleep 4
e "(demo-open-ediff)"; sleep 4
e "(demo-claude-comment)"; sleep 1
e "(demo-report-help)"; sleep 5

say "2. s: the files, in a side window at the left edge of the review's frame"; sleep 4
e "(demo-key \"s\")"; sleep 3
e "(demo-report-windows \"ediff, s\")"; sleep 1
e "(demo-report-pane \"ediff, s\")"; sleep 5

say "3. n: the mark follows the difference into the next file"; sleep 4
e "(demo-key \"n\")"; sleep 2
e "(demo-key \"n\")"; sleep 2
e "(demo-key \"n\")"; sleep 2
e "(demo-report-difference \"n n n\")"; sleep 1
e "(demo-report-pane \"n n n\")"; sleep 4

say "4. |: ediff lays its windows out again, and the pane stays"; sleep 4
e "(demo-key \"|\")"; sleep 3
e "(demo-report-windows \"after |\")"; sleep 4
e "(demo-key \"|\")"; sleep 2

say "5. / lib: the pane narrows as it is typed; README.md stays for Claude's comment"; sleep 5
e "(demo-type-filter \"lib\")"; sleep 7
e "(demo-report-difference \"after RET\")"; sleep 1
e "(demo-report-pane \"after RET\")"; sleep 1
e "(demo-report-help)"; sleep 5

say "6. n and p step over the files the filter hides"; sleep 4
e "(demo-key \"p\")"; sleep 2
e "(demo-report-difference \"p\")"; sleep 3
e "(demo-key \"n\")"; sleep 2
e "(demo-report-difference \"n\")"; sleep 3
e "(demo-key \"n\")"; sleep 2
e "(demo-report-difference \"n\")"; sleep 3
e "(demo-key \"n\")"; sleep 2
e "(demo-report-difference \"n\")"; sleep 3
say "   j 3: difference 3 is in a hidden file, so j goes to the first one kept after it"; sleep 4
e "(demo-run-key-in (demo-review) \"j\" nil 3)"; sleep 2
e "(demo-report-difference \"j 3\")"; sleep 3
e "(demo-clear-filter)"; sleep 2
e "(demo-report-difference \"filter cleared\")"; sleep 3

say "7. q: the review goes, and the pane with it"; sleep 4
e "(demo-quit-ediff)"; sleep 3
e "(demo-report-windows \"after q\")"; sleep 3

say "8. The diff review: the pane comes up again, between the session and the diff"; sleep 5
e "(demo-open-diff)"; sleep 4
e "(demo-report-windows \"diff review\")"; sleep 1
e "(demo-report-pane \"diff review\")"; sleep 5
e "(demo-type-filter \"app\")"; sleep 6
e "(demo-report-pane \"diff, after RET\")"; sleep 4
e "(demo-key \"s\")"; sleep 2
e "(demo-report-windows \"diff, s again\")"; sleep 4

e "(demo-quit)"; sleep 3
e "(demo-save-log \"/tmp/ecc-demo-review-files-log.txt\")"; sleep 2
say "That is Phase 6."; sleep 4
