# The order of the scene of demo/scenes/resume-fix.el, and how long each
# step is held.  Read by demo/record.sh, which defines `e' (run a form
# in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh resume-fix
#
# Two real sessions, one after the other: the same conversation resumed
# with the fix taken out and then with it in.  The exit of the CLI that
# went is handed over by hand rather than waited for, so the scene shows
# every time what happened five times in ten.

say "0.3.0 -- the exit of a CLI that has been replaced closes nothing"; sleep 6
e "(demo-frame)"; sleep 1
e "(demo-open-source)"; sleep 5

say "First, the bug as it was: the fix is taken out of this Emacs"; sleep 5
e "(demo-use-the-old-code)"; sleep 5

say "1. A session, and something for it to remember"; sleep 4
e "(demo-start-session)"; sleep 10
e "(demo-show-transcript)"; sleep 3
e "(demo-remember)"; sleep 16
e "(demo-show-transcript)"; sleep 3
e "(demo-report-session)"; sleep 9

say "2. /resume: the CLI is stopped and started again on the same conversation"; sleep 6
e "(demo-resume-and-ask)"; sleep 8
e "(demo-show-transcript)"; sleep 4

say "3. And now the sentinel of the CLI that went arrives -- late, as Emacs runs it"; sleep 7
e "(demo-late-exit)"; sleep 8
e "(demo-report-session)"; sleep 10
e "(demo-report-asked)"; sleep 9
say "The session is exited, its process is gone, the turn it was given was thrown away -- and ecc offers to resume a CLI that never went"; sleep 9
e "(demo-wait-for-the-answer 20)"; sleep 8
e "(demo-show-transcript)"; sleep 5
say "A prompt with nothing under it, in a session whose CLI is in fact still running"; sleep 8

say "4. The same thing with the fix in place"; sleep 5
e "(demo-forget-the-session)"; sleep 4
e "(demo-use-the-new-code)"; sleep 5
e "(demo-start-session)"; sleep 10
e "(demo-remember)"; sleep 16
e "(demo-show-transcript)"; sleep 3
e "(demo-report-session)"; sleep 8

e "(demo-resume-and-ask)"; sleep 8
e "(demo-late-exit)"; sleep 8
e "(demo-report-session)"; sleep 9
e "(demo-report-asked)"; sleep 9
say "The exit belonged to a process the session had already replaced, so it was left alone -- and nothing was asked"; sleep 9
e "(demo-wait-for-the-answer 25)"; sleep 8
e "(demo-show-transcript)"; sleep 6
e "(demo-report-session)"; sleep 9
say "The answer is in the transcript, the session is idle and its CLI is the one that is running"; sleep 8

e "(demo-save-log \"/tmp/ecc-demo-resume-fix-log.txt\")"; sleep 2
e "(demo-cleanup)"; sleep 5
say "That is fix(proc): an exit that is not the session's own closes nothing."; sleep 6
