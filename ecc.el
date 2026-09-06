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
(require 'ecc-visual)
(require 'ecc-dispatch)
(require 'ecc-render)
(require 'ecc-session)
(require 'ecc-prompt)
(require 'ecc-perm)
(require 'ecc-plan)
(require 'ecc-review)
(require 'ecc-sync)
(require 'ecc-inbox)
(require 'ecc-registry)
(require 'ecc-history)
(require 'ecc-dashboard)
(require 'ecc-window)
(require 'ecc-context)
(require 'ecc-notify)
(require 'ecc-hint)
(require 'ecc-mcp)
(require 'ecc-inline)
(require 'ecc-tui)
(require 'ecc-transient)

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

(defcustom ecc-notify-on-start t
  "Non-nil turns `ecc-notify-mode' on with the first session (FR-NOTIFY-1)."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-track-source-buffer t
  "Non-nil follows the buffer the user last worked in (FR-CTX-1).
That is what `ecc-send-region' and the `@region' reference quote from
when the current buffer is a transcript or a prompt."
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
     ;; The second session of a project is told from the first by a name
     ;; the user gives it (FR-WIN-3).
     (let ((root (ecc-project-root)))
       (list root (ecc-window-read-session-name root)))))
  (let ((session (ecc-model-create-session
                  :project-root (or directory (ecc-project-root))
                  :name (and name (not (string-empty-p name)) name))))
    (ecc-session-ensure-buffer session)
    (ecc-prompt-ensure-buffer session)
    (ecc-proc-start session)
    (when ecc-inbox-indicator
      (ecc-inbox-indicator-mode 1))
    (when ecc-notify-on-start
      (ecc-notify-mode 1))
    (when ecc-tab-line
      (ecc-tab-line-mode 1))
    ;; The timers that sum a conversation up cost a turn when they fire,
    ;; so they only start once a session exists and only when the recap
    ;; is wanted at all (FR-HINT-1, NFR-3).
    (when ecc-recap-enabled
      (ecc-hint-mode 1))
    (when ecc-track-source-buffer
      (ecc-track-source-buffer-mode 1))
    (ecc-display-prompt session)
    session))

;;;###autoload
(defun ecc-resume (session &optional fork)
  "Start SESSION again with --resume, forking it when FORK is non-nil.
Interactively, resume the session of the current buffer; a prefix
argument forks it into a new conversation (FR-SES-4)."
  (interactive (list (ecc-read-session "Resume: ") current-prefix-arg))
  ;; What the recording holds is read first, so that the stream is
  ;; appended to the conversation rather than starting an empty one
  ;; (FR-HIST-3).  `ecc-history-resume' refuses a live process.
  (ecc-history-resume session fork)
  (ecc-prompt-ensure-buffer session)
  (ecc-display-session session)
  session)

(defun ecc--session-candidates (&optional project-root)
  "Return (LABEL . SESSION-ID) for every session worth resuming.
The sessions of this Emacs come first, then the recordings under
PROJECT-ROOT, most recently used first.  A session another process is
running is labelled as such rather than hidden: it can still be read,
and resuming it asks first (FR-TUI-5)."
  (let ((seen (make-hash-table :test #'equal))
        candidates)
    (dolist (session (ecc-model-sessions))
      (let ((id (ecc-session-id session)))
        (unless (gethash id seen)
          (puthash id t seen)
          (push (cons (format "%-28s  %-10s %s"
                              (ecc--truncate (ecc-session-name session) 28)
                              (if (process-live-p (ecc-session-process session))
                                  "running" "in this Emacs")
                              (abbreviate-file-name
                               (or (ecc-session-cwd session) "")))
                      id)
                candidates))))
    (dolist (info (ecc-history-recordings project-root))
      (let* ((id (alist-get 'session-id info))
             (entry (and id (ecc-registry-session id))))
        (unless (or (null id) (gethash id seen))
          (puthash id t seen)
          (push (cons (format "%-28s  %-10s %s"
                              (ecc--truncate (or (alist-get 'title info) id) 28)
                              (cond (entry (format "pid %s"
                                                   (or (alist-get 'pid entry) "?")))
                                    (t (ecc-dashboard--time-label
                                        (or (alist-get 'time info)
                                            (alist-get 'mtime info)))))
                              (ecc--truncate (or (alist-get 'prompt info) "") 60))
                      id)
                candidates))))
    (nreverse candidates)))

(defun ecc-read-session (&optional prompt)
  "Return a session to work on, asking with PROMPT when there is a choice.
The session of the current buffer wins.  Otherwise the sessions of this
Emacs and the recordings of the current project are offered, and the
recordings of every project when this one has none.  A recording that
is picked is read back into an archived session (FR-DASH-3, FR-HIST-1)."
  (or ecc-render--session
      (let* ((root (ecc-project-root))
             (candidates (or (ecc--session-candidates root)
                             (ecc--session-candidates)))
             (choice (progn
                       (unless candidates
                         (user-error "No session and no recorded conversation"))
                       (if (= 1 (length candidates))
                           (car candidates)
                         (let ((label (completing-read (or prompt "Session: ")
                                                       (mapcar #'car candidates)
                                                       nil t)))
                           (assoc label candidates))))))
        (or (ecc-model-session (cdr choice))
            (ecc-history-session (cdr choice))))))

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
          (y-or-n-p (format "%s exited with code %s.  Resume it? "
                            (ecc-session-name session) status)))
      (ecc-resume session)
    (message "%s: R, or M-x ecc-resume, starts it again"
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
  (ecc-window-forget-session session)
  (ecc-image-cleanup-session session)
  (dolist (buffer (list (ecc-session-buffer session)
                        (ecc-session-prompt-buffer session)
                        (ecc-session-stream-buffer session)))
    (when (buffer-live-p buffer)
      (kill-buffer buffer)))
  (message "Stopped %s" (ecc-session-name session)))

(provide 'ecc)

;;; ecc.el ends here
