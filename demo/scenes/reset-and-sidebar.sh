# The order of the scene of demo/scenes/reset-and-sidebar.el.
#
#   demo/record.sh reset-and-sidebar
#
# Three real sessions and a worktree.  Nothing is sent to any of them:
# the scene is about the windows, the key that deals them out again and
# the sidebar's own keys.

say "0.3.0 -- ecc-space-reset-windows, and the sidebar"; sleep 5
e "(demo-frame)"; sleep 1

say "1. Three sessions in one project: they stand side by side, never stacked"; sleep 6
e "(demo-start-session \"one\")"; sleep 9
e "(demo-start-session \"two\")"; sleep 9
e "(demo-start-session \"three\")"; sleep 9
e "(demo-report-windows)"; sleep 8
e "(demo-report-spaces)"; sleep 7

say "2. And then a morning's work: split, zoomed, one transcript filling the tab, the sidebar put away"; sleep 7
e "(demo-mess-it-up)"; sleep 5
e "(demo-report-windows)"; sleep 8
e "(demo-report-spaces)"; sleep 7
say "The windows of a Space are the user's, and nothing rearranges them on its own -- which left no way to say start again"; sleep 8

say "3. C-c c V puts the Space back to the arrangement a new tab gets"; sleep 6
e "(demo-reset)"; sleep 5
e "(demo-report-windows)"; sleep 9
e "(demo-report-spaces)"; sleep 7
say "The source on the left, the transcripts beside it most recently used first -- and the sidebar is back, because a new tab has one"; sleep 9

say "4. C-c c z fills the tab with the window point is in"; sleep 5
e "(demo-zoom)"; sleep 5
e "(demo-report-windows)"; sleep 7
say "and the same key puts the windows back"; sleep 4
e "(demo-zoom)"; sleep 5
e "(demo-report-windows)"; sleep 7

say "5. A worktree, so the sidebar has a tree to draw"; sleep 5
e "(demo-start-worktree \"feat/sidebar\")"; sleep 14
e "(demo-report-spaces)"; sleep 8

say "6. C-c c b goes into the sidebar -- the same key comes back out"; sleep 6
e "(demo-sidebar-focus)"; sleep 5
e "(demo-report-sidebar)"; sleep 10
say "n and p move"; sleep 3
e "(demo-sidebar-key \"n\")"; sleep 3
e "(demo-report-sidebar-row)"; sleep 5
e "(demo-sidebar-key \"n\")"; sleep 3
e "(demo-report-sidebar-row)"; sleep 5
say "TAB folds a repository's worktrees away"; sleep 4
e "(demo-sidebar-key \"TAB\")"; sleep 4
e "(demo-report-sidebar)"; sleep 8
e "(demo-sidebar-key \"TAB\")"; sleep 4
say "g asks git again"; sleep 3
e "(demo-sidebar-key \"g\")"; sleep 4
e "(demo-report-sidebar)"; sleep 8

say "7. The numbers go to a Space by its number -- 1 to 9"; sleep 5
e "(demo-jump 1)"; sleep 5
e "(demo-report-spaces)"; sleep 6
e "(demo-jump 2)"; sleep 5
e "(demo-report-spaces)"; sleep 6

say "8. q hides the sidebar"; sleep 4
e "(demo-sidebar-key \"q\")"; sleep 4
e "(demo-report-spaces)"; sleep 6

e "(demo-cleanup)"; sleep 5
say "That is the reset key and the sidebar of 0.3.0."; sleep 5
