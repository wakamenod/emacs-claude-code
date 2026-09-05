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
(require 'ecc-history)
(require 'ecc-dashboard)
(require 'ecc-window)

(defcustom ecc-resume-on-abnormal-exit 'ask
  "What to do when the CLI of a session stops on its own (FR-SES-7).
`ask' offers to resume it, `auto' resumes it without asking and nil
only leaves the state in the buffer.  An exit the user asked for, and
an exit with status zero, are never resumed."
  :type '(choice (const :tag "Offer to resume" ask)
                 (const :tag "Resume at once" auto)
                 (const :tag "Say nothing" nil))
  :group 'ecc)

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
  ;; What the recording holds is read first, so that the stream is
  ;; appended to the conversation rather than starting an empty one
  ;; (FR-HIST-3).  `ecc-history-resume' refuses a live process.
  (ecc-history-resume session fork)
  (ecc-prompt-ensure-buffer session)
  (ecc-display-session session)
  session)

(defun ecc--offer-resume (session status)
  "Offer to resume SESSION, whose CLI stopped with STATUS (FR-SES-7).
The state is in the buffer already; this is the offer that goes with
it.  Only an exit the user did not ask for is offered, and only when
there is a recording to resume from.  The offer is made from a timer:
a sentinel is no place to ask a question or start a process."
  (when (and ecc-resume-on-abnormal-exit
             (integerp status)
             (/= status 0)
             (not (ecc-proc-stopped-on-request-p session))
             (ecc-history-file (ecc-session-id session)))
    (run-at-time 0 nil #'ecc-offer-resume-now session status)))

(defun ecc-offer-resume-now (session status)
  "Ask whether to resume SESSION, which stopped with STATUS (FR-SES-7)."
  (if (or (eq ecc-resume-on-abnormal-exit 'auto)
          (y-or-n-p (format "%s が code %s で終了しました。resume しますか? "
                            (ecc-session-name session) status)))
      (ecc-resume session)
    (message "%s: R または M-x ecc-resume で再開できます"
             (ecc-session-name session))))

(add-hook 'ecc-session-exited-hook #'ecc--offer-resume)

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
