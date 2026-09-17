# The order of the scene of demo/scenes/worktree-removal-offer.el, and
# how long each step is held.  Read by demo/record.sh, which defines `e'
# (run a form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh worktree-removal-offer
#
# Seven real sessions are started and nothing is sent to any of them:
# the scene is about what is asked when one goes, and what git has left
# afterwards.  The pauses are generous because a session takes a second
# or two to come up, and because every question is held on the screen
# long enough to read before it is answered.

say "feat/worktree -- the worktree is offered wherever its Space ends, and the branch is never taken"; sleep 6
e "(demo-frame)"; sleep 1
e "(demo-open-source)"; sleep 5
e "(demo-report-git)"; sleep 5

say "1. A worktree with one session in it: feat/one"; sleep 4
e "(demo-start-worktree \"feat/one\")"; sleep 12
e "(demo-frame)"; sleep 2
e "(demo-report-spaces)"; sleep 5
e "(demo-report-git)"; sleep 6

say "Stopping that session -- from Lisp, not from a command.  Before this, the directory was left behind"; sleep 7
e "(demo-expect (quote (\"Remove the worktree\" . t)))"; sleep 2
e "(demo-kill-session \"feat/one\")"; sleep 10
e "(demo-frame)"; sleep 2
e "(demo-report-asked)"; sleep 6
e "(demo-report-git)"; sleep 7
say "feat/one is gone from git worktree list -- and the branch feat/one is still there"; sleep 7

say "2. Two sessions in one worktree: feat/two.  Stopping one of them is no reason to take the tree from the other"; sleep 8
e "(demo-start-worktree \"feat/two\")"; sleep 12
e "(demo-start-second-session \"feat/two\")"; sleep 12
e "(demo-frame)"; sleep 2
e "(demo-report-spaces)"; sleep 6
e "(demo-expect (quote (\"Remove the worktree\" . t)))"; sleep 2
e "(demo-kill-session \"feat/two-b\")"; sleep 8
e "(demo-report-asked)"; sleep 7
say "Nothing was asked: one of the two is still working there"; sleep 5

say "And now the last one -- answering no this time, to show that no leaves it standing"; sleep 7
e "(demo-expect (quote (\"Remove the worktree\" . nil)))"; sleep 2
e "(demo-kill-session \"feat/two\")"; sleep 10
e "(demo-report-asked)"; sleep 7
e "(demo-report-git)"; sleep 7
say "feat/two is still on disk, with nothing running in it"; sleep 5

say "3. A worktree git does not find clean takes a second question"; sleep 5
e "(demo-dirty \"feat/two\")"; sleep 6
e "(demo-expect (quote (\"Remove the worktree\" . t)) (quote (\"not committed\" . nil)))"; sleep 2
say "C-c c ? M -- ecc-remove-worktree.  Yes to the first question; git refuses, and its refusal is the second"; sleep 8
e "(demo-remove-worktree \"feat/two\")"; sleep 12
e "(demo-report-asked)"; sleep 8
e "(demo-report-git)"; sleep 6
say "No to git's question leaves the tree and the file in it alone"; sleep 5

say "The same again, answering both -- this is the only way anything uncommitted is lost"; sleep 7
e "(demo-expect (quote (\"Remove the worktree\" . t)) (quote (\"not committed\" . t)))"; sleep 2
e "(demo-remove-worktree \"feat/two\")"; sleep 10
e "(demo-report-asked)"; sleep 8
e "(demo-report-git)"; sleep 7

say "4. Closing the Space of a worktree offers the directory that closed with it"; sleep 7
e "(demo-start-worktree \"feat/three\")"; sleep 12
e "(demo-frame)"; sleep 2
e "(demo-expect (quote (\"Stop \" . t)) (quote (\"Remove the worktree\" . t)))"; sleep 2
say "C-c c ? X -- ecc-space-close.  One question for the sessions, then one for the worktree"; sleep 7
e "(demo-close-space (demo-worktree \"feat/three\"))"; sleep 10
e "(demo-frame)"; sleep 2
e "(demo-report-asked)"; sleep 8
e "(demo-report-git)"; sleep 7
say "Before this, closing a Space left the directory where it was, with no Space and nothing running in it"; sleep 7

say "5. A repository takes its worktrees with it, and asks about them in ONE question"; sleep 7
e "(demo-start-worktree \"feat/four\")"; sleep 12
e "(demo-start-worktree \"feat/five\")"; sleep 12
e "(demo-goto-space demo-root)"; sleep 3
e "(demo-frame)"; sleep 2
e "(demo-report-spaces)"; sleep 7
e "(demo-report-git)"; sleep 6
e "(demo-expect (quote (\"Stop \" . t)) (quote (\"Remove the worktrees\" . t)))"; sleep 2
e "(demo-close-space demo-root)"; sleep 12
e "(demo-frame)"; sleep 2
e "(demo-report-asked)"; sleep 9
e "(demo-report-spaces)"; sleep 6
e "(demo-report-git)"; sleep 8
say "Both worktrees named in one question, both gone -- and both branches still in git branch"; sleep 7

say "6. A session in a project of its own INSIDE the worktree is stopped with it"; sleep 7
e "(demo-start-worktree \"feat/six\")"; sleep 12
e "(demo-start-nested-session \"feat/six\")"; sleep 12
e "(demo-frame)"; sleep 2
e "(demo-report-agents)"; sleep 7
say "vendor/lib is a repository of its own, so project.el calls that session a project of its own"; sleep 7
e "(demo-report-git)"; sleep 5
say "It is also a directory git has never seen, so the removal takes git's second question as well"; sleep 7
e "(demo-expect (quote (\"Stop \" . t)) (quote (\"not committed\" . t)))"; sleep 2
e "(demo-remove-worktree \"feat/six\")"; sleep 12
e "(demo-frame)"; sleep 2
e "(demo-report-asked)"; sleep 8
e "(demo-report-agents)"; sleep 8
say "Both sessions gone.  This one used to be left in the model -- a row in the sidebar pointing at a deleted directory"; sleep 8

say "7. What git has at the end"; sleep 4
e "(demo-report-git)"; sleep 10
say "No worktrees left, and every branch still there.  No branch is ever deleted -- git branch -d is yours"; sleep 9

e "(demo-save-log \"/tmp/ecc-demo-worktree-removal-offer-log.txt\")"; sleep 2
