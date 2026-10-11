# The order of the scene of demo/scenes/at-path-completion.el, and how
# long each step is held.  Read by demo/record.sh.
#
#   demo/record.sh at-path-completion
#
# TAB after @ through the configuration's own completion, then one short
# round trip with a path completed outside the project.

T=/tmp/ecc-demo-at-path-completion/tree/

say "TAB after @: project files, and paths from anywhere"; sleep 4
e "(demo-start-session)"; sleep 6
e "(demo-frame)"; sleep 1

say "1. A plain word after @: the special words and the project's files, as before"; sleep 4
e "(demo-project-report)"; sleep 2
e "(demo-write-prompt \"Look at @rea\")"; sleep 1
e "(demo-tab)"; sleep 3
e "(demo-shown t)"; sleep 1
e "(demo-capf-says t)"; sleep 3
e "(demo-quit-completion)"; sleep 1

say "2. @../ is relative to the session's project"; sleep 4
e "(demo-write-prompt \"Look at @../\")"; sleep 1
e "(demo-tab)"; sleep 3
e "(demo-shown t)"; sleep 1
e "(demo-capf-says t)"; sleep 3
e "(demo-quit-completion)"; sleep 1

say "3. An absolute path, one directory at a time"; sleep 4
e "(demo-write-prompt \"Look at @$T\")"; sleep 1
e "(demo-tab)"; sleep 3
e "(demo-shown t)"; sleep 1
e "(demo-capf-says t)"; sleep 3
e "(demo-quit-completion)"; sleep 1
e "(demo-write-prompt \"Look at @${T}su\")"; sleep 1
e "(demo-tab)"; sleep 3
e "(demo-shown t)"; sleep 1
e "(demo-quit-completion)"; sleep 1
e "(demo-tab)"; sleep 3
e "(demo-shown t)"; sleep 3
e "(demo-quit-completion)"; sleep 1

say "4. ~/ is the home directory, and stays ~/ in the prompt"; sleep 4
e "(demo-write-prompt \"Look at @~/\")"; sleep 1
e "(demo-tab)"; sleep 2
e "(demo-shown)"; sleep 1
e "(demo-capf-says)"; sleep 1
e "(demo-quit-completion)"; sleep 1
e "(demo-write-prompt \"Look at @~/.emacs.d/early-in\")"; sleep 1
e "(demo-tab)"; sleep 3
e "(demo-shown t)"; sleep 3
e "(demo-quit-completion)"; sleep 1

say "5. A remote path: nothing offered, nothing connected"; sleep 4
e "(demo-tramp-state)"; sleep 2
e "(demo-write-prompt \"Look at @/ssh:\")"; sleep 1
e "(demo-tab)"; sleep 3
e "(demo-shown t)"; sleep 1
e "(demo-capf-says t)"; sleep 1
e "(demo-write-prompt \"Look at @/ssh:example.invalid:/etc/\")"; sleep 1
e "(demo-tab)"; sleep 3
e "(demo-shown t)"; sleep 1
e "(demo-capf-says t)"; sleep 1
e "(demo-tramp-state)"; sleep 3
e "(demo-quit-completion)"; sleep 1

say "6. A path completed outside the project, sent: the CLI reads it"; sleep 4
e "(demo-write-prompt \"Reply with only the first line of @../sib\")"; sleep 1
e "(demo-tab)"; sleep 3
e "(demo-shown t)"; sleep 2
e "(demo-quit-completion)"; sleep 1
e "(with-current-buffer (demo-buffer) (goto-char (ecc-chat-prompt-end)) (insert \"no\") (set-window-point (get-buffer-window (current-buffer) t) (point)))"; sleep 1
e "(demo-tab)"; sleep 3
e "(demo-shown t)"; sleep 2
e "(demo-quit-completion)"; sleep 1
e "(demo-send)"; sleep 25
e "(demo-frame)"; sleep 1
e "(demo-answer)"; sleep 5

e "(demo-cleanup)"; sleep 3
e "(demo-save-log \"/tmp/ecc-demo-at-path-completion-log.txt\")"; sleep 1
say "That is the @ completion of paths."; sleep 3
