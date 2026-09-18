# The order of the scene of demo/scenes/task-notification.el, and how
# long each step is held.  Read by demo/record.sh, which defines `e' (run
# a form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh task-notification
#
# A step is written in the seconds it should last: the camera is running
# the whole time, and a caption nobody can finish reading is the usual
# thing to get wrong.

say "fix/task-notification-prompt -- a CLI task notification is not a prompt"; sleep 4
e "(demo-frame)"; sleep 1

say "0. A real recording of this machine, cut off just after the notice the CLI injected"; sleep 5
e "(demo-show-the-notice)"; sleep 6
e "(demo-show-the-line)"; sleep 7

say "1. Before: the notice is read as a prompt and opens a turn of its own"; sleep 4
e "(demo-open-before)"; sleep 4
e "(demo-frame)"; sleep 1
e "(demo-goto-notice-before)"; sleep 5
say "That is the bug as it was reported: the transcript comes back with a user mark on it"; sleep 6
e "(demo-report-turns-before)"; sleep 6

say "And the same text is what the resume list and the dashboard call the last prompt"; sleep 5
e "(demo-report-resume-line-before)"; sleep 7

say "2. After: the same recording, read with this branch"; sleep 4
e "(demo-open-after)"; sleep 4
e "(demo-frame)"; sleep 1
e "(demo-goto-notice-after)"; sleep 5
e "(demo-report-turns-after)"; sleep 6
e "(demo-report-note)"; sleep 7

say "3. TAB opens the fold: the notice itself is kept, not hidden"; sleep 4
e "(demo-unfold-note)"; sleep 7
e "(demo-goto-notice-after)"; sleep 4

say "4. And the last prompt is the one somebody typed again"; sleep 4
e "(demo-report-resume-line-after)"; sleep 7

say "5. The live stream is the other way in: the same notice, dispatched"; sleep 4
e "(demo-live-notice)"; sleep 8
e "(demo-goto-notice-after)"; sleep 5

say "No turn opened, nothing dropped.  That is the whole of fix/task-notification-prompt."; sleep 6

e "(demo-save-log \"/tmp/ecc-demo-task-notification-log.txt\")"; sleep 2
