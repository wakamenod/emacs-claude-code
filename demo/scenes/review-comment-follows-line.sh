# The order of the scene of demo/scenes/review-comment-follows-line.el,
# and how long each step is held.  Read by demo/record.sh, which defines
# `e' (run a form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh review-comment-follows-line
#
# One real session is started and nothing is sent to it: the prompt of
# C-c C-c is caught and logged, and the edits are written to the file
# directly, so the scene costs nothing.

say "A sent line comment follows its line when lines are put in above it"; sleep 5
e "(demo-frame)"; sleep 1
e "(demo-catch-prompts)"; sleep 1
e "(demo-start-session)"; sleep 8
e "(demo-frame)"; sleep 2
e "(demo-claude-writes demo-share \"Claude adds share() to summary.py\")"; sleep 3
e "(demo-open-review)"; sleep 5

say "1. A comment on the return of share(), L10, sent with C-c C-c"; sleep 5
e "(demo-go-to-review-line \"+        return part / total\")"; sleep 3
e "(demo-key \"c\" \"rows is 0 for an empty file: return 0.0 then\")"; sleep 4
e "(demo-key \"C-c C-c\")"; sleep 4
e "(demo-report \"1 sent\")"; sleep 6

say "2. Claude puts a guard in, two lines right above that line"; sleep 5
e "(demo-claude-writes (string-replace \"        total = self.total()\n\" \"        total = self.total()\n        if total == 0:\n            return 0.0\n\" demo-share) \"Claude puts two lines in above the return\")"; sleep 6
e "(demo-report \"2 after the review followed the file\")"; sleep 8

e "(demo-save-log \"/tmp/ecc-demo-review-comment-follows-line-log.txt\")"; sleep 2
e "(demo-cleanup)"; sleep 3
say "The comment stayed on its line, L12 now, still sent."; sleep 4
