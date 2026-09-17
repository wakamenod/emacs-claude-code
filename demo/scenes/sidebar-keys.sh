# The order of the scene of demo/scenes/sidebar-keys.el, and how long
# each step is held.  Read by demo/record.sh, which defines `e' (run a
# form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh sidebar-keys
#
# Four real sessions and two worktrees.  One session is sent a prompt
# that makes the CLI ask to write a file, so that `a' and `d' have
# something to answer; nothing else is sent.

say "0.3.0 -- the sidebar, and every key that works in it"; sleep 4
e "(demo-frame)"; sleep 1
e "(demo-open-source)"; sleep 4

say "1. The two keys that swapped: C-c c b is the sidebar now, C-c c B the dashboard"; sleep 6
e "(demo-report-the-two-keys)"; sleep 7
e "(demo-show-sidebar)"; sleep 4
e "(demo-frame)"; sleep 2
e "(demo-report-window)"; sleep 7
say "28 columns, a side window, no-other-window -- and C-x o never lands there"; sleep 6

say "2. Nothing is running yet.  A session in the repository"; sleep 4
e "(demo-start-here \"alpha\")"; sleep 10
e "(demo-frame)"; sleep 2
e "(demo-report-rows)"; sleep 8

say "3. W in the sidebar makes a worktree of the Space at point"; sleep 5
e "(demo-point-on \"ecc-demo-sidebar-keys\")"; sleep 4
e "(demo-say-sidebar-key \"W\")"; sleep 4
e "(demo-sidebar-key \"W\" \"feat/one\")"; sleep 14
e "(demo-frame)"; sleep 3
e "(demo-report-rows)"; sleep 8
say "The worktree hangs on a tree line under the repository it came from"; sleep 6

say "4. A second worktree, so the tree has two branches and the fold has a reason"; sleep 6
e "(demo-point-on \"ecc-demo-sidebar-keys\")"; sleep 3
e "(demo-sidebar-key \"W\" \"feat/two\")"; sleep 14
e "(demo-frame)"; sleep 3
e "(demo-report-rows)"; sleep 9

say "5. TAB folds the worktrees away -- the arrow turns, and the numbers with it"; sleep 6
e "(demo-point-on \"ecc-demo-sidebar-keys\")"; sleep 3
e "(demo-say-sidebar-key \"TAB\")"; sleep 4
e "(demo-sidebar-key \"TAB\")"; sleep 4
e "(demo-frame)"; sleep 3
e "(demo-report-rows)"; sleep 8
say "TAB again brings them back"; sleep 4
e "(demo-sidebar-key \"TAB\")"; sleep 4
e "(demo-frame)"; sleep 3

say "6. The numbers go to a Space: 1-9, as the sidebar prints them"; sleep 6
e "(demo-sidebar-key \"2\")"; sleep 5
e "(demo-frame)"; sleep 2
e "(demo-report-current)"; sleep 8
e "(demo-sidebar-key \"1\")"; sleep 5
e "(demo-frame)"; sleep 2
e "(demo-report-current)"; sleep 8

say "7. n and p walk the rows, over the headings and the detail lines"; sleep 6
e "(demo-sidebar-key \"n\")"; sleep 3
e "(demo-report-point)"; sleep 5
e "(demo-sidebar-key \"n\")"; sleep 3
e "(demo-report-point)"; sleep 5
e "(demo-sidebar-key \"p\")"; sleep 3
e "(demo-report-point)"; sleep 5

say "8. RET goes to what the row stands for -- a session, in its own Space"; sleep 6
e "(demo-point-on \"feat/one\")"; sleep 4
e "(demo-sidebar-key \"RET\")"; sleep 5
e "(demo-frame)"; sleep 2
e "(demo-report-current)"; sleep 8

say "9. c starts another session in the Space at point"; sleep 5
e "(demo-point-on \"ecc-demo-sidebar-keys\")"; sleep 3
e "(demo-say-sidebar-key \"c\")"; sleep 4
e "(demo-sidebar-key \"c\")"; sleep 12
e "(demo-frame)"; sleep 3
e "(demo-report-rows)"; sleep 9

say "10. Something to answer: the session is asked to write a file"; sleep 5
e "(demo-goto-space demo-root)"; sleep 3
e "(demo-send \"alpha\" \"Write a file called scratch.txt in this project containing the single word hello. Use the Write tool.\")"; sleep 20
e "(demo-frame)"; sleep 3
e "(demo-report-pending)"; sleep 8
e "(demo-report-rows)"; sleep 9
say "The sidebar says what it is waiting for, wherever the transcript is"; sleep 6

say "11. a allows it, after saying what is being allowed"; sleep 5
e "(demo-expect (quote (\"Allow\" . t)))"; sleep 2
e "(demo-point-on \"alpha\")"; sleep 3
e "(demo-say-sidebar-key \"a\")"; sleep 4
e "(demo-sidebar-key \"a\")"; sleep 8
e "(demo-report-asked)"; sleep 7
e "(demo-report-pending)"; sleep 7
e "(demo-frame)"; sleep 3

say "12. And d denies, with a reason typed into the minibuffer"; sleep 5
e "(demo-send \"alpha\" \"Now delete scratch.txt with the Bash tool: rm scratch.txt\")"; sleep 20
e "(demo-report-pending)"; sleep 7
e "(demo-expect (quote (\"Deny\" . t)))"; sleep 2
e "(demo-point-on \"alpha\")"; sleep 3
e "(demo-sidebar-key \"d\" \"leave it where it is\")"; sleep 8
e "(demo-report-asked)"; sleep 7
e "(demo-report-pending)"; sleep 7

say "13. g asks git again and draws afresh"; sleep 5
e "(demo-sidebar-key \"g\")"; sleep 4
e "(demo-frame)"; sleep 2
e "(demo-report-rows)"; sleep 8

say "14. k stops the session the row stands for -- and the last one in a worktree offers the worktree"; sleep 8
e "(demo-expect (quote (\"Stop \" . t)) (quote (\"Remove the worktree\" . t)))"; sleep 2
e "(demo-point-on \"feat/two\")"; sleep 4
e "(demo-sidebar-key \"k\")"; sleep 12
e "(demo-report-asked)"; sleep 9
e "(demo-frame)"; sleep 3
e "(demo-report-rows)"; sleep 9

say "15. X removes the worktree of the Space at point, sessions and all"; sleep 6
e "(demo-expect (quote (\"Stop \" . t)) (quote (\"Remove the worktree\" . t)) (quote (\"not committed\" . t)))"; sleep 2
e "(demo-point-on \"feat/one\")"; sleep 4
e "(demo-say-sidebar-key \"X\")"; sleep 4
e "(demo-sidebar-key \"X\")"; sleep 12
e "(demo-report-asked)"; sleep 9
e "(demo-frame)"; sleep 3
e "(demo-report-rows)"; sleep 9

say "16. x closes a Space, stopping what is running in it"; sleep 5
e "(demo-expect (quote (\"Stop \" . t)) (quote (\".*\" . t)))"; sleep 2
e "(demo-point-on \"ecc-demo-sidebar-keys\")"; sleep 4
e "(demo-sidebar-key \"x\")"; sleep 12
e "(demo-frame)"; sleep 3
e "(demo-report-rows)"; sleep 8

say "17. q hides the sidebar, and C-c c b is the way back in"; sleep 6
e "(demo-sidebar-key \"q\")"; sleep 4
e "(demo-frame)"; sleep 3
e "(demo-report-window)"; sleep 6
e "(demo-show-sidebar)"; sleep 4
e "(demo-frame)"; sleep 3
e "(demo-report-window)"; sleep 7

e "(demo-save-log \"/tmp/ecc-demo-sidebar-keys-log.txt\")"; sleep 2
e "(demo-cleanup)"; sleep 5
say "That is the whole of the sidebar's keys."; sleep 5

