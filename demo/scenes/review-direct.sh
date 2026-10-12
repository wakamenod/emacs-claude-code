# The order of the scene of demo/scenes/review-direct.el, and how long
# each step is held.  Read by demo/record.sh, which defines `e' (run a
# form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh review-direct
#
# No CLI is started and no model is asked anything: the review belongs
# to an archived session with no process.

say "Phase 8 of the review comments: read an ediff review in its own two windows"; sleep 5
e "(demo-frame)"; sleep 1
e "(demo-open-session)"; sleep 1

say "1. The review opens with the keyboard in the right window; each window says its keys"; sleep 4
e "(demo-open-ediff)"; sleep 4
e "(demo-report \"open\")"; sleep 1
e "(demo-report-headers)"; sleep 5

say "2. n in the right window goes to the first difference"; sleep 3
e "(demo-type 'B \"n\")"; sleep 3
e "(demo-report \"after n\")"; sleep 3

say "3. c on a line of the right window comments on that line"; sleep 3
e "(demo-goto 'B 12)"; sleep 2
e "(demo-type 'B \"c\" \"Name the generator\")"; sleep 4
e "(demo-report-comments)"; sleep 4

say "   ... and the other side counts the comment's rows: point on the left, right above it the right has a comment"; sleep 5
e "(demo-goto 'A 13)"; sleep 3
e "(demo-report \"point on left L13, a comment above right L13\")"; sleep 4
e "(demo-goto 'A 45)"; sleep 2
e "(demo-type 'A \"c\" \"Why drop these?\")"; sleep 4
e "(demo-goto 'B 50)"; sleep 2
e "(demo-goto 'B 46)"; sleep 3
e "(demo-report \"point on right L46, a comment above left L46\")"; sleep 4

say "4. Point into another difference: it becomes current, the left side follows, the right does not scroll"; sleep 5
e "(demo-goto 'B 31)"; sleep 3
e "(demo-report \"point on right L31, in a difference\")"; sleep 4

say "   ... and between differences the left side shows the same line of the file"; sleep 4
e "(demo-goto 'B 50)"; sleep 3
e "(demo-report \"point on right L50, between differences\")"; sleep 4

say "   ... and from the left: a line taken out stands against where it was"; sleep 4
e "(demo-goto 'A 44)"; sleep 3
e "(demo-report \"point on left L44, a line taken out\")"; sleep 4

say "5. isearch: the other side follows once the search ends"; sleep 4
e "(demo-search 'B \"return total\")"; sleep 4
e "(demo-report \"after C-s return total RET\")"; sleep 4

say "6. v scrolls both windows"; sleep 3
e "(demo-type 'B \"v\")"; sleep 3
e "(demo-report \"after v\")"; sleep 4

say "7. RET opens the file at that line, in a frame of its own; the review stays"; sleep 4
e "(demo-goto 'B 31)"; sleep 2
e "(demo-report-frames \"before RET\")"; sleep 1
e "(demo-type 'B \"RET\")"; sleep 4
e "(demo-report-frames \"after RET\")"; sleep 1
e "(demo-report \"after RET\")"; sleep 4

e "(demo-save-log \"/tmp/ecc-demo-review-direct-log.txt\")"; sleep 2
e "(demo-close)"; sleep 2
say "That is Phase 8."; sleep 4
