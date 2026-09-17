# The order of the scene of demo/scenes/keys-and-menu.el, and how long
# each step is held.  Read by demo/record.sh, which defines `e' (run a
# form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh keys-and-menu
#
# Nothing is started: every step is a question put to a keymap in the
# buffer the key would be pressed in, and the two menus.  The pauses are
# long because what is being shown is a line of text to read.

say "0.3.0 -- the keys the Spaces took, in the real configuration"; sleep 5
e "(demo-frame)"; sleep 1
e "(demo-open-source)"; sleep 4
e "(demo-report-setting)"; sleep 6

say "1. The four lower-case keys are the Spaces now"; sleep 4
e "(demo-report-spaces-keys)"; sleep 9
say "Before: C-c c j focused a project, C-c c b was the dashboard, and V showed the source"; sleep 8

say "2. B is the dashboard -- the same list, in the form that does not stay on the screen"; sleep 6
e "(demo-report-moved-keys)"; sleep 9
say "C-c c r resumes at once now; C-u C-c c r forks.  b and B are the pair to watch"; sleep 8

say "3. The two reviews: since the session started, and since the last commit"; sleep 5
e "(demo-report-review-keys)"; sleep 8

say "4. And the keys whose commands went away"; sleep 4
e "(demo-report-gone-keys)"; sleep 8
e "(demo-report-gone-commands)"; sleep 10
e "(demo-report-kept-command)"; sleep 8

say "5. A session buffer's own keys: C-c C-r is the prompt history now, not resend-last"; sleep 6
e "(demo-open-chat)"; sleep 3
e "(demo-report-chat-keys)"; sleep 9

say "6. ecc-menu: the Spaces column, and W for the worktrees"; sleep 5
e "(demo-open-source)"; sleep 2
e "(demo-open-menu)"; sleep 12
say "j b V z X W down the Spaces column; w rewrites the region, where W used to"; sleep 8

say "7. W -- the three worktree commands that belong together"; sleep 5
e "(demo-open-worktree-menu)"; sleep 10
say "c makes one and starts a session there, o opens one that exists, k removes one"; sleep 8
e "(demo-close-menu)"; sleep 3

say "That is the whole of the keyboard 0.3.0 rearranged."; sleep 6
