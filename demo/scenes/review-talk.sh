# The order of the scene of demo/scenes/review-talk.el, and how long
# each step is held.  Read by demo/record.sh, which defines `e' (run a
# form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh review-talk
#
# No CLI is started: the session's process is a cat, and every message
# Claude would send is handed to ecc-dispatch, so the scene costs nothing.

say "Phase 7 of the review comments: talk to Claude without leaving the review"; sleep 5
e "(demo-frame)"; sleep 1
e "(demo-open-session)"; sleep 3
e "(demo-frame)"; sleep 1

say "1. The ediff review takes the frame; the reply pane sits at the bottom"; sleep 4
e "(demo-open-ediff)"; sleep 4
e "(demo-report-windows \"ediff open\")"; sleep 1
e "(demo-report-pane \"ediff open\")"; sleep 1
e "(demo-report-help)"; sleep 5

say "2. T asks the session for a tour; Claude navigates and explains, in the pane"; sleep 4
e "(demo-key \"T\")"; sleep 2
e "(demo-report-sent \"after T\")"; sleep 1
e "(demo-tour-1)"; sleep 10
e "(demo-report-pane \"tour, first stop\")"; sleep 1
e "(demo-report-review \"tour, first stop\")"; sleep 3

say "   ... and leaves a comment on the line that needs attention"; sleep 3
e "(demo-tour-1-comment)"; sleep 4
e "(demo-report-pane \"comment\")"; sleep 1
e "(demo-report-review \"comment\")"; sleep 1
e "(demo-report-windows \"the keyboard stays in the control panel\")"; sleep 4

say "3. t: the next stop.  The pane is replaced each turn"; sleep 4
e "(demo-key \"t\")"; sleep 2
e "(demo-tour-2)"; sleep 9
e "(demo-result)"; sleep 1
e "(demo-report-sent \"after t\")"; sleep 1
e "(demo-report-pane \"next stop\")"; sleep 1
e "(demo-report-review \"next stop\")"; sleep 4

say "4. M: a message of your own, read in the minibuffer"; sleep 4
e "(demo-key \"M\" \"Why keep the old cache entries?\")"; sleep 5
e "(demo-report-sent \"after M\")"; sleep 1
e "(demo-answer-message)"; sleep 9
e "(demo-report-pane \"answer to M\")"; sleep 3

say "5. Claude asks to run a command: shown whole in the pane, y answers it"; sleep 4
e "(demo-ask-tests)"; sleep 4
e "(demo-report-pane \"permission asked\")"; sleep 1
e "(demo-report-sent \"permission asked\")"; sleep 4
e "(demo-answer ?y)"; sleep 5
e "(demo-report-sent \"after y\")"; sleep 1
e "(demo-after-allow)"; sleep 6
e "(demo-result)"; sleep 1
e "(demo-report-pane \"after y\")"; sleep 1
e "(demo-report-windows \"after y\")"; sleep 4

say "6. |: ediff lays its windows out again, and the pane stays"; sleep 4
e "(demo-key \"|\")"; sleep 3
e "(demo-report-windows \"after |\")"; sleep 4
e "(demo-key \"|\")"; sleep 2

say "7. q: the review goes, and the pane with it"; sleep 4
e "(demo-quit)"; sleep 3
e "(demo-report-windows \"after q\")"; sleep 3

e "(demo-save-log \"/tmp/ecc-demo-review-talk-log.txt\")"; sleep 2
say "That is Phase 7."; sleep 4
