# The order of the scene of demo/scenes/jev-verdicts.el, and how long
# each step is held.  Read by demo/record.sh, which defines `e' (run a
# form in the demo Emacs) and `say' (a caption in the echo area).
#
#   demo/record.sh jev-verdicts
#
# Four real sessions in one project and real requests to Jev: the
# Keychain holds the key and demo-jev-setup puts jev.el on the
# load-path.  One turn ends in a question, one finishes the job, one
# cannot go on, and one asks with the AskUserQuestion tool -- which
# leaves it waiting rather than idle, and Jev with nothing to say.

say "ecc-jev -- what a finished turn meant, in the sidebar's left mark"; sleep 5
e "(demo-frame)"; sleep 1
e "(demo-jev-setup)"; sleep 9

say "1. The sidebar, and three sessions in one project"; sleep 5
e "(demo-show-sidebar)"; sleep 3
e "(demo-frame)"; sleep 2
e "(demo-start-here \"alpha\")"; sleep 9
e "(demo-start-here \"beta\")"; sleep 9
e "(demo-start-here \"gamma\")"; sleep 9
e "(demo-frame)"; sleep 2
e "(demo-report-rows)"; sleep 7

say "2. Jev is off -- the default.  Three prompts that end three different ways"; sleep 7
e "(demo-send \"alpha\" \"Do not use any tool, and do not use AskUserQuestion. In plain text: greet.py has one function. Propose two possible new names for it, and end your message by asking me which of the two I want.\")"; sleep 2
e "(demo-send \"beta\" \"Read greet.py and tell me in one sentence what it does.\")"; sleep 2
e "(demo-send \"gamma\" \"Read the file config.yml in this project and summarise it in one sentence. Do not create it and do not guess what it might contain.\")"; sleep 40
e "(demo-frame)"; sleep 3
e "(demo-report-rows)"; sleep 9
say "Three sessions, one word between them: idle.  That is everything the CLI knows"; sleep 8
e "(demo-report-verdicts)"; sleep 9

say "3. Now turn it on"; sleep 4
e "(demo-jev-on)"; sleep 6

say "4. The same three, asked again -- each finished turn goes to Jev"; sleep 6
e "(demo-send \"alpha\" \"Again, in plain text and with no tool at all: name the two candidates once more and end by asking me which one to use.\")"; sleep 2
e "(demo-send \"beta\" \"Read README.md and tell me in one sentence what it says.\")"; sleep 2
e "(demo-send \"gamma\" \"Try again: read config.yml and summarise it. Do not create it.\")"; sleep 45
e "(demo-frame)"; sleep 3
e "(demo-report-rows)"; sleep 10
e "(demo-report-verdicts)"; sleep 12
say "The marks, and what they were read from:"; sleep 4
e "(demo-report-said \"alpha\")"; sleep 9
e "(demo-report-said \"beta\")"; sleep 9
e "(demo-report-said \"gamma\")"; sleep 9

say "5. A new turn forgets it: what the last one meant says nothing about this one"; sleep 7
e "(demo-send \"alpha\" \"The first one is fine. Say ok, and nothing else.\")"; sleep 25
e "(demo-frame)"; sleep 3
e "(demo-report-rows)"; sleep 8
e "(demo-report-verdicts)"; sleep 10

say "6. A session waiting on a tool is not idle, and not Jev's to speak about"; sleep 7
e "(demo-start-here \"delta\")"; sleep 9
e "(demo-send \"delta\" \"Use the AskUserQuestion tool to ask me whether to rename the function in greet.py.\")"; sleep 30
e "(demo-frame)"; sleep 3
e "(demo-report-rows)"; sleep 9
e "(demo-report-verdicts)"; sleep 10
say "It wears the tab line's own mark, and Jev is not consulted at all"; sleep 7
e "(demo-answer-question \"delta\")"; sleep 15
e "(demo-frame)"; sleep 3
e "(demo-report-rows)"; sleep 8

e "(demo-save-log \"/tmp/ecc-demo-jev-verdicts-log.txt\")"; sleep 2
e "(demo-cleanup)"; sleep 6
say "Four sessions, one column, and only what a person has to answer is marked."; sleep 6
