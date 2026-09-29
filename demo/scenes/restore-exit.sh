# The order of the scene of demo/scenes/restore-exit.el, and how long each
# step is held.  Read by demo/record.sh, which defines `e' (run a form in
# the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh restore-exit && demo/record.sh restore-back
#
# The first half of a restart: three real sessions in two Spaces, the
# state file following them, and Emacs quitting at the end.  Two short
# prompts are sent so that the recordings have a turn to read back.

say "feat/session-restore, part 1 -- what is open is saved as it changes"; sleep 4
e "(demo-frame)"; sleep 1
e "(demo-restore-show-source \"alpha\" \"greet.py\")"; sleep 4
e "(demo-restore-report-file)"; sleep 5

say "1. A session in alpha: its Space opens, and the state file follows"; sleep 4
e "(demo-restore-start \"alpha\" \"alpha-one\")"; sleep 7
e "(demo-restore-send \"alpha-one\" \"Reply with exactly: alpha-one ready\")"; sleep 10
e "(demo-frame)"; sleep 1
e "(demo-restore-report-file)"; sleep 6

say "2. A second session in alpha, and one in beta -- two Spaces, three sessions"; sleep 4
e "(demo-restore-start \"alpha\" \"alpha-two\")"; sleep 7
e "(demo-restore-send \"alpha-two\" \"Reply with exactly: alpha-two ready\")"; sleep 10
e "(demo-restore-start \"beta\" \"beta\")"; sleep 7
e "(demo-restore-send \"beta\" \"Reply with exactly: beta ready\")"; sleep 10
e "(demo-frame)"; sleep 1
e "(demo-restore-report-sessions)"; sleep 6
e "(demo-restore-report-file)"; sleep 7

say "3. A session killed on purpose leaves the file: what comes back is what was open"; sleep 4
e "(demo-restore-start \"beta\" \"throwaway\")"; sleep 6
e "(demo-restore-report-file)"; sleep 5
e "(demo-restore-kill \"throwaway\")"; sleep 3
e "(demo-restore-report-file)"; sleep 6

say "4. Quit Emacs.  The file is written once more, before the sessions go down with it"; sleep 5
e "(demo-save-log \"/tmp/ecc-demo-restore-exit-log.txt\")"; sleep 1
e "(demo-restore-exit)"; sleep 4
