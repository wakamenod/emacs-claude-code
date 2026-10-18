# The order of the scene of demo/scenes/history-button-click.el, and how
# long each step is held.  Read by demo/record.sh, which defines `e' (run
# a form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh history-button-click
#
# The recording is read one turn to a page, so it opens with one turn
# and the button; each click reads one more.  The second click is made
# with another window selected, which is the case a click has to find
# the session from the window clicked.

say "refactor/history-button-keymap -- the Load older messages button, clicked"; sleep 3
e "(demo-frame)"; sleep 2
e "(demo-report)"; sleep 4

say "1. mouse-1 on the button, the session window selected"; sleep 3
e "(demo-select-session-window)"; sleep 2
e "(demo-click)"; sleep 3
e "(demo-report)"; sleep 4

say "2. mouse-1 on the button, another window selected"; sleep 3
e "(demo-select-other-window)"; sleep 3
e "(demo-click)"; sleep 3
e "(demo-report)"; sleep 4

e "(demo-save-log \"/tmp/ecc-demo-history-button-click-log.txt\")"; sleep 2
say "That is the whole of refactor/history-button-keymap."; sleep 3
