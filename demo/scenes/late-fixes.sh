# The order of the scene of demo/scenes/late-fixes.el, and how long each
# step is held.  Read by demo/record.sh, which defines `e' (run a form
# in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh late-fixes
#
# Two real sessions, one of them in a worktree, and one prompt each that
# makes the CLI ask for a tool -- a Write, which the rows may answer,
# and a Bash, which they may not.

say "The fixes that went onto release/0.3.0 after the pull request was opened"; sleep 6
e "(demo-frame)"; sleep 1
e "(demo-open-source)"; sleep 4

say "1. ecc-sidebar-width is a setting now; ecc-worktree-directory is a variable again"; sleep 7
e "(demo-report-settings)"; sleep 9
e "(demo-widen-the-sidebar 36)"; sleep 4
e "(demo-frame)"; sleep 4
e "(demo-widen-the-sidebar 28)"; sleep 4
e "(demo-frame)"; sleep 3

say "2. A session in a worktree is named by its branch"; sleep 5
e "(demo-start-here \"alpha\")"; sleep 10
e "(demo-start-worktree \"feat/one\")"; sleep 14
e "(demo-frame)"; sleep 3
e "(demo-report-names)"; sleep 9
say "The Space and the session under it read the same -- it was feat/one over feat-one"; sleep 8
e "(demo-report-rows)"; sleep 9

say "3. Something to answer: alpha is asked to write a file"; sleep 5
e "(demo-send \"alpha\" \"Write a file called scratch.txt in this project containing the single word hello. Use the Write tool.\")"; sleep 5
e "(demo-wait-for-a-request 40)"; sleep 8
e "(demo-frame)"; sleep 3

say "4. The sidebar's a asks what it is about to allow"; sleep 5
e "(demo-expect (quote (\"Allow\" . t)))"; sleep 2
e "(demo-sidebar-do \"alpha\" \"a\")"; sleep 9
e "(demo-report-asked)"; sleep 8
e "(demo-report-pending)"; sleep 6

say "5. And a Bash request is not answered from a row at all"; sleep 6
e "(demo-send \"alpha\" \"Now delete scratch.txt by running this with the Bash tool: rm scratch.txt\")"; sleep 5
e "(demo-wait-for-a-request 40)"; sleep 8
e "(demo-expect (quote (\"Allow\" . t)))"; sleep 2
e "(demo-sidebar-do \"alpha\" \"a\")"; sleep 7
e "(demo-report-message)"; sleep 9
e "(demo-report-asked)"; sleep 7
say "A shell command is read in the transcript -- RET on the row -- not from a summary cut to 28 columns"; sleep 9
e "(demo-report-pending)"; sleep 7

say "6. The dashboard is the same list, and now it answers the same way"; sleep 6
e "(demo-open-dashboard)"; sleep 5
e "(demo-dashboard-point-on \"alpha\")"; sleep 4
e "(demo-dashboard-key \"a\")"; sleep 6
e "(demo-report-message)"; sleep 9
say "It used to allow whatever the row was waiting on, Bash included, without a word"; sleep 8

say "7. And the dashboard's k asks before it stops a session"; sleep 6
e "(demo-expect (quote (\"Stop \" . nil)))"; sleep 2
e "(demo-dashboard-point-on \"alpha\")"; sleep 3
e "(demo-dashboard-key \"k\")"; sleep 8
e "(demo-report-asked)"; sleep 8
e "(demo-report-names)"; sleep 8
say "No left it where it was -- it used to stop the session with no question at all"; sleep 8

e "(demo-save-log \"/tmp/ecc-demo-late-fixes-log.txt\")"; sleep 2
e "(demo-cleanup)"; sleep 6
say "That is the whole of what came after the pull request."; sleep 5
