# The order of the scene of demo/scenes/restore-back.el, and how long each
# step is held.  Read by demo/record.sh, which defines `e' (run a form in
# the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh restore-exit && demo/record.sh restore-back
#
# The second half of a restart: a fresh Emacs, ecc-restore, and one prompt
# that starts one restored session and no other.

say "feat/session-restore, part 2 -- a new Emacs, with nothing open"; sleep 4
e "(demo-frame)"; sleep 1
e "(demo-restore-show-source \"alpha\" \"greet.py\")"; sleep 4
e "(demo-restore-report-sessions)"; sleep 5
e "(demo-restore-report-file)"; sleep 6

say "1. M-x ecc-restore"; sleep 3
e "(demo-restore-run)"; sleep 5
e "(demo-frame)"; sleep 1
say "Both Spaces are back in tab order, each session read from its recording"; sleep 5
e "(demo-restore-report-sessions)"; sleep 8
say "Stopped, with no CLI under any of them: nothing started at restore"; sleep 5

say "2. The beta Space, as it was"; sleep 3
e "(demo-restore-goto-space \"beta\")"; sleep 6
e "(demo-restore-goto-space \"alpha\")"; sleep 4

say "3. A prompt typed into alpha-one starts alpha-one, and nothing else"; sleep 4
e "(demo-restore-type-and-send \"alpha-one\" \"What did you reply last time? Answer in one line.\")"; sleep 14
e "(demo-frame)"; sleep 1
e "(demo-restore-report-sessions)"; sleep 8

say "4. ecc-restore again: what is open already is left alone"; sleep 4
e "(demo-restore-run)"; sleep 5
e "(demo-restore-report-sessions)"; sleep 6

e "(demo-save-log \"/tmp/ecc-demo-restore-back-log.txt\")"; sleep 2
e "(demo-restore-cleanup)"; sleep 3
say "That is feat/session-restore."; sleep 4
