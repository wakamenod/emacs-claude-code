# The order of the scene of demo/scenes/worktree-guard.el.
#
#   demo/record.sh worktree-guard
#
# One real session with the Emacs MCP server on, and one piece of work
# handed to a worktree of its own.  The control requests are handed to
# the dispatcher the way the stream brings them.

say "0.3.0 -- handing a piece of work to a worktree, and the two ways turned back"; sleep 6
e "(demo-frame)"; sleep 1

say "1. A session with the Emacs MCP server on: the model is offered start_worktree_session"; sleep 6
e "(demo-start)"; sleep 10
e "(demo-report-tool)"; sleep 9

say "2. In an auto permission mode the CLI asks Emacs nothing, so a draft that says worktree carries one line of reminder"; sleep 8
e "(demo-report-hint \"worktree を切って直して\")"; sleep 10
e "(demo-report-hint \"ワークツリーでやって\")"; sleep 9
say "and a draft that does not speak of one costs nothing at all"; sleep 5
e "(demo-report-no-hint)"; sleep 8

say "3. That line is sent, but nobody wrote it -- so the transcript parts it from the prompt"; sleep 7
e "(demo-send-a-worktree-prompt)"; sleep 20
e "(demo-goto-the-aside)"; sleep 8
say "A folded heading under the band: 1 line Emacs added.  TAB opens it like any other"; sleep 7
e "(demo-unfold-the-aside)"; sleep 8
e "(demo-goto-the-aside)"; sleep 6

say "4. EnterWorktree, which a stream-json session carries, is refused before anybody is asked"; sleep 7
e "(demo-enter-worktree)"; sleep 8
e "(demo-report-refusal)"; sleep 10
e "(demo-report-pending)"; sleep 7

say "5. And so is git worktree add in Bash -- cd first or not"; sleep 5
e "(demo-bash-worktree-add)"; sleep 8
e "(demo-report-pending)"; sleep 7
say "Another git command is none of the guard's business: that one is put in front of the user"; sleep 6
e "(demo-bash-worktree-list)"; sleep 6
e "(demo-report-pending)"; sleep 8

say "6. The way that is left: Emacs makes the worktree, opens it as a Space and sends the brief"; sleep 7
e "(demo-delegate)"; sleep 14
e "(demo-report-handed)"; sleep 9
e "(demo-show-the-brief)"; sleep 10
say "The brief carries what Emacs knows too -- the files touched, the plans, the uncommitted changes, and where the recording is"; sleep 9

e "(demo-cleanup)"; sleep 6
say "That is the worktree hand-off of 0.3.0."; sleep 5
