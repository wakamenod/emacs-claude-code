# The order of the scene of demo/scenes/rename-command.el.
#
#   demo/record.sh rename-command
#
# One real session.  `/rename' is answered by the CLI itself, so the
# pauses around the send only have to cover a round trip of the pipe,
# not a turn of the model.

say "/rename, and the R that renamed a session to NAME<2>"; sleep 5
e "(demo-frame)"; sleep 1

say "1. A session, called after nothing in particular"; sleep 4
e "(demo-start)"; sleep 9
e "(demo-report \"Before\")"; sleep 9

say "2. /rename, typed in the session itself -- the CLI's own command"; sleep 6
e "(demo-type-rename)"; sleep 5
e "(demo-send)"; sleep 8
e "(demo-show-the-transcript)"; sleep 6
say "The CLI renamed its conversation.  Emacs used to stop here, still calling it morning"; sleep 8
e "(demo-report \"After\")"; sleep 10
e "(demo-report-last-turn)"; sleep 10
say "A command node, not a reply the model wrote"; sleep 6

say "3. C-c c R offers the name the session has.  RET takes it"; sleep 6
e "(demo-press-rename-key)"; sleep 6
e "(demo-report \"After pressing RET on the offered name\")"; sleep 10
say "afternoon, not afternoon<2>"; sleep 6

say "4. A name typed over it still renames"; sleep 5
e "(demo-press-rename-key-with-a-name)"; sleep 6
e "(demo-report \"After typing a new one\")"; sleep 10

e "(demo-cleanup)"; sleep 4
e "(demo-save-log \"/tmp/ecc-demo-rename-command-log.txt\")"; sleep 2
say "That is /rename reaching Emacs."; sleep 5
