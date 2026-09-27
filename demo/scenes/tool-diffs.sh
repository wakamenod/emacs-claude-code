# The order of the scene of demo/scenes/tool-diffs.el, and how long each
# step is held.  Read by demo/record.sh, which defines `e' (run a form in
# the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh tool-diffs
#
# No CLI: every message is fed to `ecc-dispatch', the door a live one
# comes in by.  What is on camera is the renderer.

say "feat/tool-diffs -- what a call that changes a file shows"; sleep 4
# demo.el has already run `demo-scene-build'; calling it again here
# rebuilds the project under the buffer that is visiting greet.py, and
# Emacs asks whether to reread it -- a minibuffer, which is the one
# thing a scene must never open: no step reaches the Emacs again
# (2026-09-22).
e "(demo-frame)"; sleep 1
e "(demo-open-session)"; sleep 4

say "1. A Read, so the session knows what greet.py holds"; sleep 4
e "(demo-read)"; sleep 2
e "(demo-show-transcript)"; sleep 4

say "2. An Edit.  It comes up open, with the lines of the file around it"; sleep 6
e "(demo-edit)"; sleep 2
e "(demo-show-transcript)"; sleep 8
say "Before this branch that was a heading with a TAB behind it"; sleep 5
e "(demo-report-folds)"; sleep 7

say "3. A MultiEdit.  This one used to draw a file path and nothing under it"; sleep 7
e "(demo-multi-edit)"; sleep 2
e "(demo-show-transcript)"; sleep 9
e "(demo-report-multi-edit)"; sleep 8

say "4. A Write over the file that is there"; sleep 5
e "(demo-write-call)"; sleep 2
e "(demo-show-transcript)"; sleep 9

say "5. A NotebookEdit, which had no diff of any kind"; sleep 6
e "(demo-notebook-edit)"; sleep 2
e "(demo-show-transcript)"; sleep 9

say "6. A file nobody read: the CLI's own structuredPatch, with its real line numbers"; sleep 7
e "(demo-patch-wins)"; sleep 2
e "(demo-show-transcript)"; sleep 9
e "(demo-finish-turn)"; sleep 3

say "7. Every heading counts the change, the way the Files rows do"; sleep 6
e "(demo-report-headings)"; sleep 10
e "(demo-report-diffs)"; sleep 8
e "(demo-show-files)"; sleep 9

say "8. The permission prompt for a MultiEdit -- it now says what it would change"; sleep 7
e "(demo-permission-multi-edit)"; sleep 3
e "(demo-show-transcript)"; sleep 10

say "9. TAB still folds one, and what the reader folded is remembered"; sleep 6
e "(demo-point-on-tool \"MultiEdit\")"; sleep 5
e "(demo-fold-at-point)"; sleep 4
e "(demo-report-folds)"; sleep 8
e "(demo-fold-at-point)"; sleep 4
e "(demo-show-transcript)"; sleep 5

say "10. ecc-render-inhibit-inline-diff t puts them all back behind their headings"; sleep 6
e "(demo-diff-inline-off)"; sleep 5
e "(demo-report-folds)"; sleep 9
e "(demo-report-headings)"; sleep 9
say "The heading still counts the change -- that is the line the reader has either way"; sleep 7
e "(demo-diff-inline-on)"; sleep 5
e "(demo-show-transcript)"; sleep 6

e "(demo-save-log \"/tmp/ecc-demo-tool-diffs-log.txt\")"; sleep 2
e "(demo-cleanup)"; sleep 2
say "That is the whole of it."; sleep 4
