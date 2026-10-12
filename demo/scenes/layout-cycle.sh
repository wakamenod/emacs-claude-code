# The order of the scene of demo/scenes/layout-cycle.el.
#
#   demo/record.sh layout-cycle
#
# Four real sessions in one project.  Nothing is sent to any of them:
# the scene is about the windows.

say "C-c c V cycles the layouts of a Space"; sleep 5
e "(demo-frame)"; sleep 1

say "1. Four sessions in one project: each new one takes a window, none is split"; sleep 6
e "(demo-start-session \"one\")"; sleep 9
e "(demo-start-session \"two\")"; sleep 9
e "(demo-start-session \"three\")"; sleep 9
e "(demo-start-session \"four\")"; sleep 9
e "(demo-report-windows)"; sleep 7

say "2. C-c c V lays the Space out from nothing: the source and one session"; sleep 6
e "(demo-press)"; sleep 7

say "3. Pressed again right away, the next layout -- six of them, then back to the first"; sleep 7
e "(demo-press t)"; sleep 7
e "(demo-press t)"; sleep 7
e "(demo-press t)"; sleep 7
e "(demo-press t)"; sleep 7
e "(demo-press t)"; sleep 7
e "(demo-press t)"; sleep 7
e "(demo-press t)"; sleep 7
say "Every session kept its place the whole way round; with repeat-mode on, V alone goes on"; sleep 8

say "4. The tab given over to one transcript, and a fresh press puts back the layout it had"; sleep 7
e "(demo-mess-it-up)"; sleep 6
e "(demo-press)"; sleep 7

say "5. C-u C-c c V goes back to the first"; sleep 5
e "(demo-press nil '(4))"; sleep 7

e "(demo-save-log \"/tmp/ecc-demo-layout-cycle-log.txt\")"; sleep 2
e "(demo-cleanup)"; sleep 5
say "That is C-c c V."; sleep 4
