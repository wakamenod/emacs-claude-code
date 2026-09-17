# The order of the scene of demo/scenes/spaces-worktree-group.el, and how
# long each step is held.  Read by demo/record.sh, which defines `e' (run
# a form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh spaces-worktree-group
#
# Five real sessions are started, and nothing is sent to any of them: the
# scene is about where the tabs and the windows go.  The pauses are
# generous because a session takes a second or two to come up.

say "feat/worktree -- a repository behind every worktree, and a Space that empties"; sleep 5
e "(demo-frame)"; sleep 1
e "(demo-open-source)"; sleep 5

say "Nothing is running yet: no session, no Space, one tab"; sleep 3
e "(demo-report-spaces)"; sleep 5

say "1. ecc-start-worktree cuts feat/one beside the repository and starts a session there"; sleep 5
e "(demo-start-worktree \"feat/one\")"; sleep 10
e "(demo-frame)"; sleep 3

say "Before: the worktree stood alone, with nothing to hang under.  Now the repository is opened behind it"; sleep 7
e "(demo-report-spaces)"; sleep 7
say "Two Spaces, two tabs -- and the worktree is the one in front, which is where the work is"; sleep 7
e "(demo-report-implicit)"; sleep 6

say "2. A second worktree of the same repository, feat/two"; sleep 4
e "(demo-start-worktree \"feat/two\")"; sleep 10
e "(demo-frame)"; sleep 2
e "(demo-report-spaces)"; sleep 7
say "The repository is not opened twice: it has a Space already"; sleep 5

say "3. The sidebar draws what git says -- both worktrees on tree lines under the repository"; sleep 6
e "(demo-goto-space demo-root)"; sleep 4
e "(demo-frame)"; sleep 4

say "4. A second session in the repository, so its Space has two transcripts abreast"; sleep 4
e "(demo-start-second-session)"; sleep 10
e "(demo-frame)"; sleep 2
e "(demo-report-windows)"; sleep 6

say "5. Killing a transcript BUFFER used to leave *scratch* standing in its window"; sleep 6
e "(demo-kill-a-transcript-buffer)"; sleep 4
e "(demo-frame)"; sleep 2
e "(demo-report-windows)"; sleep 7
say "The window is gone instead, and the transcript beside it took the room back"; sleep 6
e "(demo-report-spaces)"; sleep 6

say "6. Stopping the LAST session of a Space now closes the Space as well"; sleep 5
e "(demo-goto-session-space \"feat/two\")"; sleep 3
e "(demo-frame)"; sleep 2
say "Standing in feat/two's own tab, and stopping the one session in it"; sleep 5
say "The worktree is offered as the session goes -- this scene answers no, and the checkout stays"; sleep 6
e "(demo-kill-session \"feat/two\")"; sleep 12
e "(demo-frame)"; sleep 2
e "(demo-report-spaces)"; sleep 8
say "feat/two is gone from the tabs and from the sidebar -- an exited session would have kept its place, for /resume"; sleep 8

say "7. ecc-space-close on the repository asks once, for the whole group"; sleep 5
e "(demo-goto-space demo-root)"; sleep 2
e "(demo-close-space demo-root \"yes\")"; sleep 4
e "(demo-frame)"; sleep 3
e "(demo-report-spaces)"; sleep 8
say "The repository and the worktree under it closed together.  The checkouts are untouched -- ecc-remove-worktree is what undoes one"; sleep 8

say "8. The other half of the setting"; sleep 4
e "(demo-turn-the-setting-off)"; sleep 7
e "(demo-open-the-other-project)"; sleep 5
e "(demo-frame)"; sleep 2
e "(demo-report-spaces)"; sleep 6
say "A Space with no session at all: it was opened and nothing was started"; sleep 6
e "(demo-report-windows)"; sleep 6

say "9. With the setting off, the Space goes when the last buffer of the project does"; sleep 6
e "(demo-kill-the-other-source)"; sleep 4
e "(demo-frame)"; sleep 2
e "(demo-report-spaces)"; sleep 8

say "That is the whole of feat/worktree's Space changes."; sleep 6
