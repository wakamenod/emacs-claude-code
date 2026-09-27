# The order of the scene of demo/scenes/visit-source.el, and how long each
# step is held.  Read by demo/record.sh, which defines `e' (run a form in
# the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh visit-source
#
# No CLI: every message is fed to `ecc-dispatch'.  greet.py on disk is
# what both Edits left, so the line that flashes can be read against the
# one asked for: the first Edit changed line 20, and the second put three
# lines above it, so it is at 23 now.

say "feat/visit-source -- RET and a click on code open the file at the line"; sleep 4
e "(demo-frame)"; sleep 1
e "(demo-open-session)"; sleep 3
e "(demo-calls)"; sleep 5

say "1. RET on the added line of the first Edit, drawn as line 20"; sleep 4
e "(demo-point-on \"✓ Edit\" \"+    return \\\"hello\")"; sleep 3
e "(demo-key \"RET\")"; sleep 3
e "(demo-report-opened)"; sleep 5
e "(demo-report-selected)"; sleep 3

say "2. RET on the removed line: where it was taken out"; sleep 3
e "(demo-back)"; e "(demo-park)"; sleep 1
e "(demo-point-on \"✓ Edit\" \"-    return \\\"hi\")"; sleep 3
e "(demo-key \"RET\")"; sleep 3
e "(demo-report-opened)"; sleep 5

say "3. RET on the heading of the Edit: its first changed line"; sleep 3
e "(demo-back)"; e "(demo-park)"; sleep 1
e "(demo-point-on \"✓ Read\" \"✓ Edit\")"; sleep 3
e "(demo-key \"RET\")"; sleep 3
e "(demo-report-opened)"; sleep 5

say "4. RET on the heading of the Read: its offset, 15"; sleep 3
e "(demo-back)"; e "(demo-park)"; sleep 1
e "(demo-point-on \"〉\" \"✓ Read\")"; sleep 3
e "(demo-key \"RET\")"; sleep 3
e "(demo-report-opened)"; sleep 5

say "5. RET on a line of the Files section"; sleep 3
e "(demo-back)"; e "(demo-park)"; sleep 1
e "(demo-point-on \"greet.py\" \"+    return \\\"hello\" t)"; sleep 3
e "(demo-key \"RET\")"; sleep 3
e "(demo-report-opened)"; sleep 5

say "6. RET on a path in the reply: greet.py:23"; sleep 3
e "(demo-back)"; e "(demo-park)"; sleep 1
e "(demo-point-on \"Done.\" \"greet.py:23\")"; sleep 3
e "(demo-key \"RET\")"; sleep 3
e "(demo-report-opened)"; sleep 5

say "7. A path that is not there: an error when it is followed"; sleep 3
e "(demo-back)"; sleep 1
e "(demo-point-on \"Done.\" \"missing.py\")"; sleep 3
e "(demo-ret-safely)"; sleep 4

say "8. A click on a context line (def farewell, drawn as 23): no mouse-face, follow-link says yes"; sleep 4
e "(demo-back)"; e "(demo-park)"; sleep 1
e "(demo-point-on \"✓ Edit\" \" def farewell\")"; sleep 3
e "(demo-click)"; sleep 3
e "(demo-report-opened)"; sleep 5

say "9. A click on the result line under it: nothing to follow"; sleep 3
e "(demo-back)"; sleep 1
e "(demo-point-on \"✓ Edit\" \"has been updated\")"; sleep 3
e "(demo-click)"; sleep 4

say "10. RET on the Bash heading still lays the node open"; sleep 3
e "(demo-back)"; sleep 1
e "(demo-close-detail)"; e "(demo-point-on \"✓ Edit\" \"✓ Bash\")"; sleep 3
e "(demo-key \"RET\")"; sleep 3
e "(demo-report-detail)"; sleep 4

say "11. o on the Edit heading does too"; sleep 3
e "(demo-back)"; sleep 1
e "(demo-point-on \"✓ Read\" \"✓ Edit\")"; sleep 3
e "(demo-close-detail)"; e "(demo-key \"o\")"; sleep 3
e "(demo-report-detail)"; sleep 4

e "(demo-save-log \"/tmp/ecc-demo-visit-source-log.txt\")"; sleep 2
e "(demo-cleanup)"; sleep 2
say "That is the whole of it."; sleep 3
