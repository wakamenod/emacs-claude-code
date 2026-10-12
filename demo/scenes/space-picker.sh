# The order of the scene of demo/scenes/space-picker.el.
#
#   demo/record.sh space-picker
#
# A repository and two worktrees, a session in each; nothing is sent to
# any of them.  The picker is opened from a timer and answered from
# timers, because Emacs does not answer the server while it reads.

say "feat/space-picker-groups -- C-c c j groups the Spaces and draws them like the sidebar"; sleep 4
e "(demo-frame)"; sleep 1

say "1. A repository with two worktrees, a session in each"; sleep 3
e "(demo-start-session)"; sleep 9
e "(demo-start-worktree \"feat/restart-session\")"; sleep 12
e "(demo-start-worktree \"feat/prompt-queue-view\")"; sleep 12
e "(demo-report-picker)"; sleep 4

say "2. C-c c j: Open, then Past; then feat narrows to the worktrees"; sleep 3
e "(demo-open-picker \"feat\")"; sleep 13

e "(demo-save-log \"/tmp/ecc-demo-space-picker-log.txt\")"; sleep 2
e "(demo-cleanup)"; sleep 4
say "That is the whole of feat/space-picker-groups."; sleep 3
