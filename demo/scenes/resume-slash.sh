# The order of the scene of demo/scenes/resume-slash.el.
#
#   demo/record.sh resume-slash
#
# Two real sessions, one prompt sent.  The pauses around the send are
# generous: the answer has to come back before the session is stopped,
# or there is no conversation to come back to.

say "0.3.0 -- /resume carries this window on with another conversation"; sleep 5
e "(demo-frame)"; sleep 1

say "1. This morning's session, with something in it"; sleep 4
e "(demo-start-first)"; sleep 9
e "(demo-say-something)"; sleep 20
e "(demo-stop-first)"; sleep 6
e "(demo-kill-first)"; sleep 5
say "Nothing is running in the project now -- only the recording is left"; sleep 6

say "2. This afternoon: going to the project starts a fresh session"; sleep 5
e "(demo-start-second)"; sleep 9
e "(demo-report-second \"Before\")"; sleep 9
e "(demo-report-command)"; sleep 8

say "3. /resume, typed in the session itself"; sleep 4
e "(demo-type-resume)"; sleep 5
e "(demo-send)"; sleep 3
e "(demo-answer-later \"kettle\" 6)"; sleep 16
e "(demo-show-the-transcript)"; sleep 8
say "The conversation of this morning, in the window of this afternoon"; sleep 6
e "(demo-report-second \"After\")"; sleep 9
e "(demo-report-what-moved)"; sleep 10
say "The window, the buffer and the name did not move.  The id is the recording's, which is what --resume was given"; sleep 9

say "4. /resume <session-id> takes one by id without asking"; sleep 6
e "(demo-type-resume-with-id)"; sleep 6
e "(demo-send)"; sleep 14
e "(demo-report-second \"After the second one\")"; sleep 9
e "(demo-show-the-transcript)"; sleep 8

e "(demo-cleanup)"; sleep 5
say "That is /resume of 0.3.0."; sleep 5
