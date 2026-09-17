# The order of the scene of demo/scenes/session-cwd.el, and how long
# each step is held.  Read by demo/record.sh, which defines `e' (run a
# form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh session-cwd
#
# One real session, in an `auto' permission mode so that the model's
# `cd' runs without anybody answering for it.

say "0.3.0 -- a session stays in the directory it was started in"; sleep 6
e "(demo-frame)"; sleep 1
e "(demo-open-source)"; sleep 5

say "1. A session in the project"; sleep 4
e "(demo-start-session)"; sleep 12
e "(demo-show-prompt)"; sleep 3
e "(demo-report-where)"; sleep 10
e "(demo-report-header)"; sleep 8
e "(demo-report-spaces)"; sleep 7

say "2. The model runs a shell command that leaves the CLI in another directory"; sleep 7
e "(demo-run-a-cd)"; sleep 5
e "(demo-wait-for-idle 60)"; sleep 6
e "(demo-show-prompt)"; sleep 5

say "3. The CLI now reports /tmp as the session cwd.  The session has not moved"; sleep 7
e "(demo-report-where)"; sleep 11
e "(demo-report-header)"; sleep 9
e "(demo-report-spaces)"; sleep 9
say "Before this the Space, the tab line and the transcript's directory all followed that cd"; sleep 9

say "4. The one thing that does move it: /cd typed into the prompt"; sleep 6
e "(demo-type-cd \"elsewhere\")"; sleep 4
e "(demo-frame)"; sleep 3
e "(demo-send-the-prompt)"; sleep 6
e "(demo-report-message)"; sleep 9
e "(demo-report-where)"; sleep 11
e "(demo-report-spaces)"; sleep 8

say "5. And a directory that is not there is said and ignored"; sleep 6
e "(demo-type-cd \"nowhere-at-all\")"; sleep 4
e "(demo-send-the-prompt)"; sleep 6
e "(demo-report-message)"; sleep 10
e "(demo-report-where)"; sleep 10

e "(demo-save-log \"/tmp/ecc-demo-session-cwd-log.txt\")"; sleep 2
e "(demo-cleanup)"; sleep 5
say "That is the cwd fix: the CLI's cwd is read, and it is not where the session lives."; sleep 7
