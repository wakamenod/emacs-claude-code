# The tail of demo/scenes/sidebar-keys.sh: the keys that answer, stop
# and remove.  The long scene was cut short by the recorder on
# 2026-09-17 before it reached them, and they are the destructive half.
#
#   demo/record.sh sidebar-tail

say "0.3.0 -- the sidebar's answering and stopping keys"; sleep 4
e "(demo-frame)"; sleep 1
e "(demo-open-source)"; sleep 3
e "(demo-show-sidebar)"; sleep 3
e "(demo-start-here \"alpha\")"; sleep 10
e "(demo-frame)"; sleep 2

say "1. A worktree with a session of its own"; sleep 4
e "(demo-point-on \"ecc-demo-sidebar-tail\")"; sleep 3
e "(demo-sidebar-key \"W\" \"feat/one\")"; sleep 14
e "(demo-frame)"; sleep 2
e "(demo-report-rows)"; sleep 8

say "2. Something to answer: alpha is asked to write a file, in default permission mode"; sleep 6
e "(demo-goto-space demo-root)"; sleep 3
e "(demo-send \"alpha\" \"Write a file called scratch.txt in this project containing the single word hello. Use the Write tool.\")"; sleep 22
e "(demo-frame)"; sleep 2
e "(demo-report-pending)"; sleep 8
e "(demo-report-rows)"; sleep 8

say "3. a allows it, saying first what is being allowed"; sleep 5
e "(demo-expect (quote (\"Allow\" . t)))"; sleep 2
e "(demo-point-on \"alpha\")"; sleep 3
e "(demo-sidebar-key \"a\")"; sleep 9
e "(demo-report-asked)"; sleep 7
e "(demo-report-pending)"; sleep 7
e "(demo-frame)"; sleep 2

say "4. And d denies, with a reason"; sleep 5
e "(demo-send \"alpha\" \"Now delete scratch.txt with the Bash tool: rm scratch.txt\")"; sleep 22
e "(demo-report-pending)"; sleep 7
e "(demo-expect (quote (\"Deny\" . t)))"; sleep 2
e "(demo-point-on \"alpha\")"; sleep 3
e "(demo-sidebar-key \"d\" \"leave it where it is\")"; sleep 9
e "(demo-report-asked)"; sleep 7
e "(demo-report-pending)"; sleep 7

say "5. g asks git again and draws afresh"; sleep 5
e "(demo-sidebar-key \"g\")"; sleep 4
e "(demo-report-rows)"; sleep 7

say "6. k stops the session at point -- the last one in a worktree offers the worktree"; sleep 7
e "(demo-expect (quote (\"Stop \" . t)) (quote (\"Remove the worktree\" . t)))"; sleep 2
e "(demo-point-on-session \"feat/one\")"; sleep 4
e "(demo-sidebar-key \"k\")"; sleep 12
e "(demo-report-asked)"; sleep 9
e "(demo-frame)"; sleep 2
e "(demo-report-rows)"; sleep 8

say "7. K removes the worktree, and the row goes with it -- no g, no session event"; sleep 8
e "(demo-report-rows)"; sleep 7
e "(demo-expect (quote (\"Stop \" . t)) (quote (\"Remove the worktree\" . t)) (quote (\"not committed\" . t)))"; sleep 2
e "(demo-point-on \"feat/one\")"; sleep 4
e "(demo-sidebar-key \"K\")"; sleep 12
e "(demo-report-asked)"; sleep 8
e "(demo-frame)"; sleep 2
e "(demo-report-rows)"; sleep 9

say "8. q hides the sidebar, and C-c c b is the way back in"; sleep 6
e "(demo-sidebar-key \"q\")"; sleep 4
e "(demo-report-window)"; sleep 6
e "(demo-show-sidebar)"; sleep 4
e "(demo-report-window)"; sleep 6

e "(demo-save-log \"/tmp/ecc-demo-sidebar-tail-log.txt\")"; sleep 2
e "(demo-cleanup)"; sleep 5
say "That is the destructive half of the sidebar's keys."; sleep 4
