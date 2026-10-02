# The order of the scene of demo/scenes/review-layout.el, and how long
# each step is held.  Read by demo/record.sh, which defines `e' (run a
# form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh review-layout
#
# The review belongs to an archived session with no process.  S in the
# menu starts one real session, to which nothing is sent.

say "Phase 9 of the review comments: two layouts, the state on the header line, no panel"; sleep 5
e "(demo-frame)"; sleep 1
e "(demo-open-session)"; sleep 1

say "1. The review opens stacked, the reply pane on the right, no control panel"; sleep 4
e "(demo-open-ediff)"; sleep 4
e "(demo-report \"1 open\")"; sleep 5

say "2. n: where the review is, at the right end of the lower header line"; sleep 4
e "(demo-type 'B \"n\")"; sleep 3
e "(demo-report \"2 after n\")"; sleep 4

say "   ... and what a filter hides"; sleep 3
e "(demo-type 'B \"/\" \"table\")"; sleep 4
e "(demo-report \"2 after / table\")"; sleep 4
e "(demo-type 'B \"/\" \"\")"; sleep 3

say "3. | puts the sides side by side, the pane under them; the left keys meet the right ones"; sleep 5
e "(demo-type 'B \"|\")"; sleep 4
e "(demo-report \"3 after |\")"; sleep 6

say "4. ? shows the control panel with every key, and ? again takes it away"; sleep 4
e "(demo-type 'B \"?\")"; sleep 4
e "(demo-report \"4 after ?\")"; sleep 5
e "(demo-type 'B \"?\")"; sleep 3
e "(demo-report \"4 after ? again\")"; sleep 3

say "5. | again: stacked, the pane back on the right"; sleep 4
e "(demo-type 'B \"|\")"; sleep 4
e "(demo-report \"5 after | again\")"; sleep 5
e "(demo-close)"; sleep 2

say "6. The reply pane in a frame of its own, which never takes the focus"; sleep 4
e "(demo-reply-in-a-frame)"; sleep 4
e "(demo-report \"6 reply in a frame\")"; sleep 4
e "(demo-close)"; sleep 2
e "(demo-report-closed \"6 closed\")"; sleep 3

say "7. C-c c D, S: + new session comes first; it starts here and gets the comments"; sleep 5
e "(demo-open-menu)"; sleep 4
e "(demo-report-menu \"7 opened\")"; sleep 3
e "(demo-new-session)"; sleep 8
e "(demo-report-menu \"7 after S + new session\")"; sleep 6
e "(demo-close-menu)"; sleep 1

e "(demo-save-log \"/tmp/ecc-demo-review-layout-log.txt\")"; sleep 2
e "(demo-cleanup)"; sleep 2
say "That is Phase 9."; sleep 4
