# The order of the scene of demo/scenes/review-ediff-help.el, and how
# long each step is held.  Read by demo/record.sh, which defines `e' (run
# a form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh review-ediff-help
#
# A step is written in the seconds it should last: the camera is running
# the whole time, and a caption nobody can finish reading is the usual
# thing to get wrong.

say "feat/review-ediff-help -- the ediff review's own help, in the real configuration"; sleep 4
e "(demo-frame)"; sleep 1
e "(demo-open-source)"; sleep 4

say "1. Start a session in this project (ecc-review-style is 'ediff here)"; sleep 3
e "(demo-start-session)"; sleep 6
e "(demo-frame)"; sleep 3

say "2. The session's work: greet.py and README.md changed, NOTES.md written"; sleep 3
e "(demo-change-files)"; sleep 2

say "3. D -- ecc-review -- opens it side by side, with a control panel of its own"; sleep 3
e "(demo-open-review)"; sleep 4
e "(demo-frame)"; sleep 2
e "(demo-place-panel)"; sleep 1
e "(demo-frame)"; sleep 3

say "Before: the panel said ' Type ? for help'.  Now it names the keys of the review"; sleep 5
e "(demo-report-help)"; sleep 6

say "4. ? shows the long help"; sleep 3
e "(demo-say-key \"?\")"; sleep 3
e "(demo-key \"?\")"; sleep 5
say "Only what works here: no a/b, no rx, no wx/wd, no ~ -- both buffers are read-only"; sleep 7
say "And the review's own keys are on it: c, d, l, C-c C-c, C-c C-k, q"; sleep 7

say "5. RET and mouse-2 over a line of the help used to answer: Undocumented command!"; sleep 5
e "(demo-point-on-help)"; sleep 2
e "(demo-key \"RET\")"; sleep 3
e "(demo-report-ret)"; sleep 7

say "6. ? again puts the short help back"; sleep 3
e "(demo-key \"?\")"; sleep 5

say "7. n walks the differences of every file in the review"; sleep 3
e "(demo-key \"n\")"; sleep 3
e "(demo-key \"n\")"; sleep 3
e "(demo-key \"p\")"; sleep 3

say "8. c comments the difference we are on"; sleep 3
e "(demo-key \"c\" \"f-strings everywhere, please\")"; sleep 6
e "(demo-comments)"; sleep 5
e "(demo-key \"n\")"; sleep 2
e "(demo-key \"c\" \"keep the old wording here\")"; sleep 6
e "(demo-comments)"; sleep 5

say "9. l lists the comments and jumps to the one picked"; sleep 3
e "(demo-key \"l\" \"\")"; sleep 6

say "10. d takes the comment on this difference off again"; sleep 3
e "(demo-key \"d\")"; sleep 3
e "(demo-comments)"; sleep 5

say "11. C-u C-c C-c shows the prompt the comments become before it goes"; sleep 4
e "(demo-key \"C-c C-c\" nil (quote (4)))"; sleep 3
e "(demo-float)"; sleep 3
say "C-c C-k there goes back to the review without sending"; sleep 4
e "(demo-cancel-message)"; sleep 5

say "12. q closes the review -- no question asked -- and the windows come back"; sleep 4
e "(demo-say-key \"q\")"; sleep 3
e "(demo-key \"q\")"; sleep 5
say "That is the whole of feat/review-ediff-help."; sleep 5
