# The order of the scene of demo/scenes/resume-key.el, and how long each
# step is held.  Read by demo/record.sh, which defines `e' (run a form in
# the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh resume-key
#
# Everything is in the one frame -- the session windows, the minibuffer
# the prompt is read in, the transient -- so the window the recorder
# takes is the whole of the scene.
#
# The two presses of the key are the scene: each holds its prompt six
# seconds before it is answered, because the prompt -- Resume: or Fork: --
# is the only place the choice can be seen from a key.

say "feat/resume-key -- C-c c r resumes, C-u C-c c r forks, in the real configuration"; sleep 4
e "(demo-frame)"; sleep 1
e "(demo-show-source)"; sleep 4

say "Before: C-c c r opened ecc-resume-menu, and resuming took C-c c r r"; sleep 5
e "(demo-report-key)"; sleep 6

say "1. Two real sessions, so that there is a conversation to resume"; sleep 3
e "(demo-start-session \"alpha\")"; sleep 6
e "(demo-send \"Reply with exactly: alpha ready\")"; sleep 10
e "(demo-frame)"; sleep 2
e "(demo-start-session \"beta\")"; sleep 6
e "(demo-send \"Reply with exactly: beta ready\")"; sleep 10
e "(demo-frame)"; sleep 3

say "2. Stop them both -- what is left is two conversations to go back to"; sleep 3
e "(demo-stop-sessions)"; sleep 5
e "(demo-show-source)"; sleep 3

say "3. C-c c r, from a file buffer.  One press, and the prompt says Resume:"; sleep 5
e "(demo-ids)"; sleep 5
e "(demo-resume-key nil \"alpha\" 7)"; sleep 9
e "(demo-frame)"; sleep 4
e "(demo-report-prompt)"; sleep 7
say "alpha is the same conversation, carried on: the id under it has not changed"; sleep 4
e "(demo-ids)"; sleep 6

say "4. C-u C-c c r is the fork.  The same key, and the prompt says Fork:"; sleep 5
e "(demo-show-source)"; sleep 2
e "(demo-resume-key (quote (4)) \"beta\" 7)"; sleep 9
e "(demo-frame)"; sleep 4
e "(demo-report-prompt)"; sleep 7
say "beta is forked: a new conversation off the old one, not the old one continued"; sleep 4
e "(demo-ids)"; sleep 7

say "5. The menu keeps the switch: r in ecc-menu still opens ecc-resume-menu"; sleep 5
e "(demo-open-resume-menu)"; sleep 8
say "-f is worth one place where it is seen before it is pressed.  q closes it"; sleep 6
e "(demo-close-menu)"; sleep 3

e "(demo-cleanup)"; sleep 4
say "That is the whole of feat/resume-key."; sleep 5
