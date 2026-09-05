;;; ecc.el --- Run Claude Code from Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (magit-section "4.0"))
;; URL: https://github.com/wakamenod/emacs-claude-code

;;; Commentary:

;; An Emacs client for the Claude Code CLI: it runs `claude' headless
;; with the stream-json protocol and shows the conversation as a
;; magit-section transcript.
;;
;; Start one with \\[ecc-start].  See REQUIREMENTS.md and
;; IMPLEMENTATION_PLAN.md in the repository for what is built when.

;;; Code:

(require 'cl-lib)
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-diff)
(require 'ecc-markdown)
(require 'ecc-dispatch)
(require 'ecc-render)
(require 'ecc-session)
(require 'ecc-prompt)
(require 'ecc-perm)
(require 'ecc-plan)
(require 'ecc-review)
(require 'ecc-sync)
(require 'ecc-inbox)
(require 'ecc-window)

(defcustom ecc-inbox-indicator t
  "Non-nil shows the number of requests waiting in every mode line.
`ecc-inbox-indicator-mode' is turned on by the first session started
\(FR-PERM-4)."
  :type 'boolean
  :group 'ecc)

(defun ecc-project-root ()
  "Return the root of the project of the current buffer, or its directory."
  (ecc-window-project-root))

;;;###autoload
(defun ecc-start (&optional directory name)
  "Start a Claude Code session in DIRECTORY under NAME (FR-SES-1, 3).
Interactively the project of the current buffer is used, and a prefix
argument asks for the directory and the name."
  (interactive
   (if current-prefix-arg
       (list (read-directory-name "Directory: " (ecc-project-root))
             (read-string "Session name: "))
     (list (ecc-project-root) nil)))
  (let ((session (ecc-model-create-session
                  :project-root (or directory (ecc-project-root))
                  :name (and name (not (string-empty-p name)) name))))
    (ecc-session-ensure-buffer session)
    (ecc-prompt-ensure-buffer session)
    (ecc-proc-start session)
    (when ecc-inbox-indicator
      (ecc-inbox-indicator-mode 1))
    (ecc-display-prompt session)
    session))

;;;###autoload
(defun ecc-resume (session &optional fork)
  "Start SESSION again with --resume, forking it when FORK is non-nil.
Interactively, resume the session of the current buffer; a prefix
argument forks it into a new conversation (FR-SES-4)."
  (interactive (list (or ecc-render--session
                         (car (ecc-model-sessions))
                         (user-error "No session to resume"))
                     current-prefix-arg))
  (when (process-live-p (ecc-session-process session))
    (user-error "%s is still running" (ecc-session-name session)))
  (ecc-session-ensure-buffer session)
  (ecc-prompt-ensure-buffer session)
  (ecc-proc-start session t fork)
  (ecc-display-session session)
  session)

;;;###autoload
(defun ecc-kill (session)
  "Stop SESSION and forget it (FR-SES-3)."
  (interactive (list (or ecc-render--session
                         (car (ecc-model-sessions))
                         (user-error "No session to kill"))))
  (ecc-proc-stop session)
  (ecc-model-remove-session session)
  (dolist (buffer (list (ecc-session-buffer session)
                        (ecc-session-prompt-buffer session)
                        (ecc-session-stream-buffer session)))
    (when (buffer-live-p buffer)
      (kill-buffer buffer)))
  (message "%s を終了しました" (ecc-session-name session)))

;;;###autoload
(defun ecc-send (text &optional session)
  "Send TEXT to SESSION, or to the most recently used one (FR-CTX-5)."
  (interactive (list (read-string "Claude: ")))
  (let ((session (or session ecc-render--session (car (ecc-model-sessions)))))
    (unless session
      (user-error "No session is running"))
    (ecc-proc-send-prompt session text)))

(provide 'ecc)

;;; ecc.el ends here
