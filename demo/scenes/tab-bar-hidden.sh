# The order of the scene of demo/scenes/tab-bar-hidden.el, and how long
# each step is held.  Read by demo/record.sh, which defines `e' (run a
# form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh tab-bar-hidden
#
# Three real sessions are started and nothing is sent to any of them:
# the scene is about the tab bar, the echo area and the frames.  The
# pauses are generous because a session takes a second or two to come
# up, and because most of what is being shown is a line of text that
# has to be read.

say "feat/worktree -- a Space is a tab, and whether the bar is drawn is the user's"; sleep 6
e "(demo-frame)"; sleep 1
e "(demo-open-source)"; sleep 6

say "1. tab-bar-show is nil here.  Nothing is running yet"; sleep 5
e "(demo-report-bar)"; sleep 7
say "No strip at the top of the frame, and tab-bar-mode is off.  ecc used to turn it on the moment a session started"; sleep 8

say "2. First, what tab-bar says when nobody quiets it -- the plain commands, on their own account"; sleep 7
e "(demo-raw-tab-talk)"; sleep 7
say "That is tab-bar.el talking: with no bar to show what it did, it says it"; sleep 7
e "(demo-raw-tab-quiet-again)"; sleep 7
say "And again on the way out.  Every move between Spaces used to arrive with one of those over ecc's own message"; sleep 8

e "(demo-mark-messages)"; sleep 6

say "3. A session in the repository.  Watch the echo area, and the top of the frame"; sleep 6
e "(demo-start-here)"; sleep 12
e "(demo-frame)"; sleep 2
e "(demo-report-bar)"; sleep 8
say "A tab was made and named.  Still no strip, still no mode -- and nothing said it"; sleep 8

say "4. A worktree of the same repository, which opens the repository behind it"; sleep 6
e "(demo-start-worktree \"feat/one\")"; sleep 14
e "(demo-frame)"; sleep 2
e "(demo-report-spaces)"; sleep 8

say "5. Round the Spaces, twice.  Each one comes back the way it was left"; sleep 6
e "(demo-cycle-spaces 2)"; sleep 12
e "(demo-report-quiet)"; sleep 9
say "That is the whole point of the quieting: ecc says where you are, and nobody talks over it"; sleep 8

say "6. The zoom is kept per Space.  It was keyed on tab-bar-mode, which is off here -- so every Space shared one key"; sleep 9
e "(demo-goto-space demo-root)"; sleep 4
e "(demo-report-zoom)"; sleep 8
e "(demo-report-windows)"; sleep 7
say "Filling the tab with the window point is in"; sleep 4
e "(demo-zoom)"; sleep 3
e "(demo-frame)"; sleep 2
e "(demo-report-zoom)"; sleep 9

say "Now to the worktree's own Space, which was never zoomed"; sleep 6
e "(demo-goto-branch \"feat/one\")"; sleep 4
e "(demo-frame)"; sleep 2
e "(demo-report-zoom)"; sleep 9
say "A different key, and not zoomed.  Before, both Spaces answered to 'frame and this one would have come up zoomed"; sleep 9

say "And back, where it still is"; sleep 4
e "(demo-goto-space demo-root)"; sleep 4
e "(demo-frame)"; sleep 2
e "(demo-report-zoom)"; sleep 8
e "(demo-zoom)"; sleep 3
e "(demo-frame)"; sleep 2
e "(demo-report-windows)"; sleep 7

say "7. A tab belongs to a frame.  A second frame opens now -- off camera, since only this window is recorded"; sleep 9
e "(demo-open-second-frame)"; sleep 10
say "It has no tabs of ours at all.  The Spaces on this frame are this frame's"; sleep 8

say "Going to the worktree's Space FROM the other frame.  This is where one table for the whole Emacs came apart"; sleep 9
e "(demo-open-space-on-the-other-frame \"feat/one\")"; sleep 10
say "Each frame keeps its own.  Before, this frame's record was dropped and its tab was left with nothing pointing at it"; sleep 9
e "(demo-report-spaces)"; sleep 8

say "8. Closing that Space from the other frame.  Watch this frame's tabs"; sleep 7
e "(demo-close-space-from-the-other-frame \"feat/one\")"; sleep 12
e "(demo-frame)"; sleep 2
e "(demo-report-spaces)"; sleep 9
say "The tab went from both frames.  A Space is closed on its own account -- its sessions stopped wherever they were shown"; sleep 9
e "(demo-close-second-frame)"; sleep 4

say "9. And the bar, for whoever wants it"; sleep 5
e "(demo-show-the-bar)"; sleep 10
e "(demo-report-bar)"; sleep 9

say "That is the whole of the tab-bar work: ecc makes the tabs, and the strip is nobody's business but the user's."; sleep 8
