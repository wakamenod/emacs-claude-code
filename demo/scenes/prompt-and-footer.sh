# The order of the scene of demo/scenes/prompt-and-footer.el, and how
# long each step is held.  Read by demo/record.sh, which defines `e' (run
# a form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh prompt-and-footer
#
# Two real sessions and one short round trip: the footer before the CLI
# has said anything, and after.

say "0.3.0 -- the footer names the model before the session has answered"; sleep 6
e "(demo-frame)"; sleep 2

say "1. A session, just started.  Nothing has been sent and the CLI has said nothing"; sleep 6
e "(demo-start-session)"; sleep 8
e "(demo-frame)"; sleep 2
e "(demo-report-footer-before)"; sleep 11
say "That comes from .claude/settings.json -- the moment to change the model is BEFORE the first prompt"; sleep 9

say "2. One prompt.  The first answer replaces the stand-in with what really ran"; sleep 6
e "(demo-send-something)"; sleep 14
e "(demo-frame)"; sleep 3
e "(demo-report-footer-after)"; sleep 11

say "3. ANTHROPIC_MODEL beats a settings file naming something else (verified 2026-09-14)"; sleep 7
e "(demo-start-env-session)"; sleep 9
e "(demo-frame)"; sleep 2
e "(demo-report-env-footer)"; sleep 11

say "4. The prompt history.  C-c C-r was resend-last; it picks from the history now"; sleep 7
e "(demo-fill-the-history)"; sleep 7

say "M-p walks it one at a time, replacing the whole region as it goes"; sleep 6
e "(demo-clear-region)"; sleep 1
e "(demo-key \"M-p\")"; sleep 3
e "(demo-report-region)"; sleep 7
e "(demo-key \"M-p\")"; sleep 3
e "(demo-report-region)"; sleep 8

say "5. C-c C-r picks one from a list instead -- and puts it beside what is already written"; sleep 7
e "(demo-half-written)"; sleep 4
e "(demo-frame)"; sleep 2
e "(demo-key \"C-c C-r\" \"rename\")"; sleep 7
e "(demo-frame)"; sleep 2
e "(demo-report-region)"; sleep 10
say "The whole of the prompt chosen, at point, with the half-written sentence still in front of it"; sleep 9

e "(demo-clear-region)"; sleep 2
e "(demo-cleanup)"; sleep 5
say "That is the footer and the prompt history."; sleep 6
