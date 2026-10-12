# The order of the scene of demo/scenes/ime-placeholder.el, and how long
# each step is held.  Read by demo/record.sh, which defines `e' (run a
# form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh ime-placeholder
#
# One session, nothing sent: the empty prompt, composed into without the
# fix and with it.

say "The placeholder and the macOS input method, at an empty prompt"; sleep 5
e "(demo-frame)"; sleep 1
e "(demo-start-session)"; sleep 8
e "(demo-frame)"; sleep 1
e "(demo-goto-prompt)"; sleep 1
e "(demo-report \"empty prompt\")"; sleep 5

say "1. Before the fix: composing にほんご"; sleep 4
e "(demo-advice-off)"; sleep 3
e "(demo-mark \"に\")"; sleep 1
e "(demo-mark \"にほ\")"; sleep 1
e "(demo-mark \"にほん\")"; sleep 1
e "(demo-mark \"にほんご\")"; sleep 2
e "(demo-report \"without the fix\")"; sleep 7
say "The composing text is drawn behind the whole placeholder; the cursor stays in front"; sleep 6
e "(demo-cancel)"; sleep 1
e "(demo-clear)"; sleep 2

say "2. With the fix: the placeholder gives way as soon as composing starts"; sleep 4
e "(demo-advice-on)"; sleep 3
e "(demo-mark \"に\")"; sleep 1
e "(demo-report \"after に\")"; sleep 3
e "(demo-mark \"にほ\")"; sleep 1
e "(demo-mark \"にほん\")"; sleep 1
e "(demo-mark \"にほんご\")"; sleep 1
e "(demo-report \"composing\")"; sleep 5
e "(demo-mark \"日本語\")"; sleep 1
e "(demo-report \"converted\")"; sleep 5

say "3. Esc cancels composing, and the placeholder comes back"; sleep 4
e "(demo-cancel)"; sleep 1
e "(demo-report \"cancelled\")"; sleep 6

say "4. Composing and committing: the committed text is the draft"; sleep 4
e "(demo-mark \"にほんご\")"; sleep 2
e "(demo-mark \"日本語\")"; sleep 2
e "(demo-commit \"日本語\")"; sleep 1
e "(demo-report \"committed\")"; sleep 6
e "(demo-clear)"; sleep 2

say "5. The other path the NS port has, ns-insert-working-text"; sleep 4
e "(demo-work \"かな\")"; sleep 1
e "(demo-report \"working text\")"; sleep 5
e "(demo-cancel)"; sleep 1
e "(demo-report \"cancelled\")"; sleep 5

e "(demo-save-log \"/tmp/ecc-demo-ime-placeholder-log.txt\")"; sleep 1
e "(demo-cleanup)"; sleep 3
say "That is the placeholder and the input method."; sleep 4
