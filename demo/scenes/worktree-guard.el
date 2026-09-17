;;; worktree-guard.el --- Handing work to a worktree, and the two ways turned back  -*- lexical-binding: t; -*-

;;; Commentary:

;; The half of the worktree work that is about the model rather than
;; the user: `start_worktree_session', the line Emacs adds to a draft
;; that speaks of a worktree (drawn as an aside under the band, not
;; inside it), and the two other ways to a worktree -- the CLI's own
;; `EnterWorktree' and `git worktree add' in Bash -- refused with a
;; sentence naming the tool.
;;
;; A real session, with the Emacs MCP server on, so that the tool is
;; really published and the guard is really armed.  The control
;; requests are handed to the dispatcher the way the stream brings
;; them.
;;
;; Played by demo/scenes/worktree-guard.sh through demo/record.sh.

;;; Code:

(require 'ecc)
(require 'ecc-mcp)
(require 'ecc-worktree)
(require 'ecc-prompt)

(defvar demo-session nil "The session the guard is shown in.")
(defvar demo-handed nil "The session the work is handed to.")
(defvar demo-source "greet.py" "A file, so the Space has something beside it.")

(defun demo-scene-build ()
  "Build the project, with the MCP server on.  Called by demo.el."
  (demo-fresh-repository)
  (demo-write demo-source "def greet(name):\n    return \"hi \" + name\n")
  (demo-write "README.md" "# demo\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (setq ecc-mcp-enabled t
        ecc-worktree-directory ".claude/worktrees")
  (find-file (expand-file-name demo-source demo-root))
  (demo-say (format "ecc from %s · ecc-mcp-enabled %s"
                    (abbreviate-file-name (locate-library "ecc"))
                    ecc-mcp-enabled))
  nil)

;;;; The tool

(defun demo-start ()
  "Start a real session in the project."
  (let ((default-directory demo-root))
    (setq demo-session (ecc-start demo-root "asking")))
  (ecc-window-select-session demo-session)
  (demo-frame)
  nil)

(defun demo-report-tool ()
  "Say whether this session really has the tool the guard points at."
  (demo-say (format "start_worktree_session published to this session: %s · tools from Emacs: %s"
                    (if (ecc-worktree-tool-published-p demo-session) "yes" "NO")
                    (mapconcat #'ecc-mcp-tool-name (ecc-mcp-published-tools) ", ")))
  nil)

;;;; The line added to a draft

(defun demo-report-hint (text)
  "Say what TEXT would be sent as."
  (demo-say (format "%S is sent as %S"
                    text
                    (substring-no-properties
                     (ecc-worktree-prompt-hint demo-session text))))
  nil)

(defun demo-report-no-hint ()
  "Say that a draft with no worktree in it costs nothing."
  (demo-report-hint "テストを通して"))

(defun demo-send-a-worktree-prompt ()
  "Send a prompt that speaks of a worktree, so the aside is on camera."
  (ecc-send "worktree の話はしなくていいので、今いるディレクトリだけ一言で答えて。何も変更しないで。"
            demo-session)
  nil)

(defun demo-goto-the-aside ()
  "Put point on the folded line Emacs added under the band."
  (when-let* ((buffer (ecc-session-buffer demo-session))
              (window (get-buffer-window buffer t)))
    (with-selected-window window
      (goto-char (point-min))
      (if (re-search-forward "Emacs added" nil t)
          (progn (goto-char (match-beginning 0)) (recenter 6))
        (goto-char (point-max)))))
  nil)

(defun demo-unfold-the-aside ()
  "Open the fold the added line waits under."
  (demo-run-key-in (buffer-name (ecc-session-buffer demo-session)) "TAB"))

;;;; The two ways turned back

(defun demo-request (tool input)
  "Hand the dispatcher a can_use_tool request for TOOL with INPUT."
  (ecc-dispatch demo-session
                `((type . "control_request")
                  (request_id . ,(format "demo-req-%s" (random 100000)))
                  (request . ((subtype . "can_use_tool")
                              (tool_name . ,tool)
                              (display_name . ,tool)
                              (input . ,input)
                              (tool_use_id . ,(format "toolu_demo%s" (random 1000)))))))
  (ecc-render-flush demo-session)
  (when-let* ((window (get-buffer-window (ecc-session-buffer demo-session) t)))
    (with-selected-window window (goto-char (point-max)) (recenter -4)))
  nil)

(defun demo-enter-worktree ()
  "The CLI's own EnterWorktree, which a stream-json session carries."
  (demo-request "EnterWorktree" '((branch . "feat/its-own-idea"))))

(defun demo-bash-worktree-add ()
  "`git worktree add' in Bash -- the same request with a step in front."
  (demo-request "Bash" '((command . "cd /tmp && git worktree add ../x -b feat/x"))))

(defun demo-bash-worktree-list ()
  "Another git command, which is none of the guard's business."
  (demo-request "Bash" '((command . "git worktree list"))))

(defun demo-report-pending ()
  "Say how many of those requests were put in front of anybody."
  (demo-say (format "Waiting for an answer from a person: %d · %s"
                    (length (ecc-session-pending demo-session))
                    (mapconcat (lambda (request)
                                 (ecc-request-tool-name request))
                               (ecc-session-pending demo-session) ", ")))
  nil)

(defun demo-report-refusal ()
  "Say what the refusal reads."
  (demo-say (format "The refusal: %s" ecc-worktree-refusal-text))
  nil)

;;;; Handing a piece of work over

(defun demo-delegate ()
  "Hand a piece of work to a session in a worktree of its own."
  (let ((default-directory demo-root))
    (setq demo-handed
          (ecc-worktree-delegate
           demo-root "feat/handed"
           "Reply in one sentence with the directory you are working in and the branch it is on.  Change nothing.")))
  (demo-frame)
  nil)

(defun demo-report-handed ()
  "Say where the session that was handed the work is."
  (demo-say (format "%s is in %s · on %s · Spaces: %s"
                    (ecc-session-name demo-handed)
                    (abbreviate-file-name (ecc-session-project-root demo-handed))
                    (or (ecc-worktree-branch (ecc-session-project-root demo-handed)) "?")
                    (mapconcat #'ecc-space-name (ecc-space-list) " | ")))
  nil)

(defun demo-show-the-brief ()
  "Put point at the top of the brief the new session was sent."
  (when-let* ((buffer (ecc-session-buffer demo-handed))
              (window (get-buffer-window buffer t)))
    (with-selected-window window
      (goto-char (point-min))
      (recenter 2)))
  nil)

;;;; Putting the machine back

(defun demo-cleanup ()
  "Stop every session and leave the worktrees where the user can see them."
  (dolist (session (ecc-model-sessions))
    (ecc-proc-stop session))
  (demo-say (format "Every session stopped · worktrees: %s"
                    (mapconcat (lambda (entry)
                                 (abbreviate-file-name
                                  (ecc-worktree-entry-path entry)))
                               (ecc-worktree-list demo-root) ", ")))
  nil)

(provide 'worktree-guard)
;;; worktree-guard.el ends here
