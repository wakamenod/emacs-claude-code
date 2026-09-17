# The order of the scene of demo/scenes/review-ediff-sides.el, and how
# long each step is held.  Read by demo/record.sh, which defines `e'
# (run a form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh review-ediff-sides
#
# One real session; the files are changed by a shell command, because a
# review compares two git trees and does not care what changed them.

say "0.3.0 -- ecc-review-style 'ediff: every file of the review as two sides"; sleep 6
e "(demo-frame)"; sleep 1
e "(demo-open-source)"; sleep 5

say "1. A session, and work no Edit or Write did"; sleep 4
e "(demo-start-session)"; sleep 10
e "(demo-do-the-work)"; sleep 7
e "(demo-remember-windows)"; sleep 6

say "2. D opens the review.  It takes the frame -- two texts too narrow to read code in was the report"; sleep 8
e "(demo-open-review)"; sleep 6
e "(demo-place-panel)"; sleep 2
e "(demo-frame)"; sleep 4
e "(demo-report-windows)"; sleep 8

say "3. One ediff session over every file of the review, under a separator each"; sleep 7
e "(demo-report-files)"; sleep 9
e "(demo-report-sides)"; sleep 10
say "Both sides read-only: a review reads, comments and sends"; sleep 6

say "4. And each file is coloured by its own major mode, carried in as text properties"; sleep 8
e "(demo-report-fontified)"; sleep 10

say "5. n and p walk the differences across the file boundaries"; sleep 6
e "(demo-key \"n\")"; sleep 4
e "(demo-frame)"; sleep 2
e "(demo-key \"n\")"; sleep 4
e "(demo-frame)"; sleep 2
e "(demo-key \"n\")"; sleep 4
e "(demo-frame)"; sleep 3
e "(demo-key \"p\")"; sleep 4
e "(demo-frame)"; sleep 2

say "6. a and b are ediff's copy commands.  Here they say what a review is"; sleep 7
e "(demo-report-copy-binding)"; sleep 8
e "(demo-copy-with \"a\")"; sleep 6
e "(demo-report-message)"; sleep 9
say "Before this they signalled ediff-copy-diff: buffer-read-only, about a buffer nobody asked about"; sleep 9
e "(demo-copy-with \"b\")"; sleep 6
e "(demo-report-sides)"; sleep 9

say "7. q closes the review without a question, and the windows come back"; sleep 7
e "(demo-say-key \"q\")"; sleep 5
e "(demo-key \"q\")"; sleep 6
e "(demo-frame)"; sleep 3
e "(demo-report-windows)"; sleep 9

e "(demo-save-log \"/tmp/ecc-demo-review-ediff-sides-log.txt\")"; sleep 2
e "(demo-cleanup)"; sleep 5
say "That is the ediff review's own screen."; sleep 5
