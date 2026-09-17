;;; session-cwd.el --- A session stays where it was started  -*- lexical-binding: t; -*-

;;; Commentary:

;; 0.3.0 stopped a session following the cwd the CLI reports.  CLI
;; 2.1.272 reports as the session cwd whatever directory the last Bash
;; tool call left it in, so a model that ran `cd somewhere && ...' moved
;; the session: out of its Space and its tab line, into a project nobody
;; had started it in, where the sidebar and `C-c c j' could not find it
;; and started a second one instead (confirmed 2026-09-16).
;;
;; Where a session lives is the root it was started in, and the only
;; thing that moves it is a `/cd <dir>' typed into the prompt region --
;; which moves the root, the transcript's `default-directory' and the
;; Space with it, and says where the session went.  A directory that is
;; not there is said and ignored.
;;
;; The model really runs the `cd': the session is started in an `auto'
;; permission mode so that the Bash call goes through without anybody
;; answering for it.
;;
;; Played by demo/scenes/session-cwd.sh through demo/record.sh.

;;; Code:

(require 'cl-lib)
(require 'ecc)
(require 'ecc-space)
(require 'ecc-chat)
(require 'ecc-sidebar)

(defvar demo-session nil
  "The session that stays put.")

(defun demo-scene-build ()
  "Build the project and open it.  Called by demo.el once there is a frame."
  (setq ecc-use-spaces t
        ecc-space-always-session t
        ;; The Bash call has to run without anybody answering for it.
        ecc-permission-mode "auto")
  (demo-fresh-repository)
  (demo-write "greet.py" "def greet(name):\n    return f\"hello {name}!\"\n")
  (demo-write "elsewhere/notes.md" "# elsewhere\n")
  (demo-git "add" ".")
  (demo-git "commit" "-q" "-m" "first")
  (demo-open-source))

(defun demo-open-source ()
  "Show the project, and say which ecc this is."
  (find-file (expand-file-name "greet.py" demo-root))
  (ecc-sidebar-show)
  (demo-say (format "ecc from %s   --   the project is %s"
                    (abbreviate-file-name (locate-library "ecc-prompt"))
                    (abbreviate-file-name demo-root)))
  nil)

(defun demo-start-session ()
  "Start a real session in the project."
  (let ((default-directory demo-root))
    (setq demo-session (ecc-start demo-root "here")))
  nil)

;;;; Where the session says it is

(defun demo-report-where ()
  "Say where the session lives, where the CLI says it is, and what draws it."
  (demo-say
   (format "root: %s | CLI cwd: %s | transcript dir: %s | Space: %s"
           (abbreviate-file-name (or (ecc-session-project-root demo-session) "?"))
           (abbreviate-file-name (or (ecc-session-cwd demo-session) "-"))
           (abbreviate-file-name
            (or (buffer-local-value 'default-directory
                                    (ecc-session-buffer demo-session))
                "?"))
           (if-let* ((key (ecc-space-current-key)))
               (ecc-space-name (ecc-space-of-root key))
             "none")))
  nil)

(defun demo-report-header ()
  "Say what the header line of the transcript says."
  (with-current-buffer (ecc-session-buffer demo-session)
    (demo-say (format "header line: %s"
                      (string-trim
                       (substring-no-properties
                        (format-mode-line header-line-format))))))
  nil)

(defun demo-report-spaces ()
  "Say what Spaces there are, which is what a moved session used to split."
  (demo-say (format "Spaces: %s      sessions: %s"
                    (mapconcat #'ecc-space-name (ecc-space-list) ", ")
                    (mapconcat #'ecc-session-name (ecc-model-sessions) ", ")))
  nil)

;;;; The model runs a cd

(defun demo-send (text)
  "Send TEXT to the session."
  (ecc-proc-send-prompt demo-session text)
  nil)

(defun demo-run-a-cd ()
  "Ask the model to run a shell command that leaves the CLI elsewhere."
  (demo-send "Run exactly this with the Bash tool, and then reply with the output: cd /tmp && pwd")
  nil)

(defun demo-wait-for-idle (&optional seconds)
  "Wait until the session is idle again, or SECONDS pass."
  (let ((deadline (+ (float-time) (or seconds 45))))
    (while (and (< (float-time) deadline)
                (ecc-session-current-turn demo-session))
      (sit-for 0.2)))
  (demo-say (format "%s is %S" (ecc-session-name demo-session)
                    (ecc-session-state demo-session)))
  nil)

;;;; The one thing that moves it

(defun demo-show-prompt ()
  "Put the transcript on the screen with point in the prompt region."
  (ecc-display-session demo-session)
  (when-let* ((window (get-buffer-window (ecc-session-buffer demo-session) t)))
    (with-selected-window window
      (goto-char (point-max))
      (recenter -1)))
  (demo-frame)
  nil)

(defun demo-type-cd (argument)
  "Type `/cd ARGUMENT' into the prompt region and send it."
  ;; `ecc-chat-goto-prompt' is where typing goes: `point-max' is past
  ;; the prompt region, in the footer, and read-only (2026-09-18).
  (let ((buffer (ecc-session-buffer demo-session)))
    (with-current-buffer buffer
      (ecc-chat-goto-prompt)
      (delete-region (point) (ecc-chat-prompt-end))
      (insert (format "/cd %s" argument))
      (when-let* ((window (get-buffer-window buffer t)))
        (set-window-point window (point))))
    (demo-say (format "typed: /cd %s" argument)))
  nil)

(defun demo-send-the-prompt ()
  "Send what is in the prompt region, the way C-c C-c does."
  (demo-run-key-in (ecc-session-buffer demo-session) "C-c C-c"))

(defun demo-report-message ()
  "Say what the last message of this Emacs was."
  (with-current-buffer "*Messages*"
    (save-excursion
      (goto-char (point-max))
      (forward-line -1)
      (demo-say (format "last message: %s"
                        (string-trim
                         (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position)))))))
  nil)

(defun demo-cleanup ()
  "Stop the session."
  (when (and demo-session (process-live-p (ecc-session-process demo-session)))
    (ignore-errors (ecc-kill demo-session)))
  nil)

(provide 'session-cwd)
;;; session-cwd.el ends here
