;;; ecc.el --- Run Claude Code from Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/wakamenod/emacs-claude-code

;;; Commentary:

;; An Emacs client for the Claude Code CLI: it runs `claude' headless
;; with the stream-json protocol and shows the conversation in one
;; buffer, the transcript above and the prompt below.
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
(require 'ecc-chat)
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
(require 'ecc-usage)
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

(defun ecc--enable-session-modes ()
  "Turn on the global modes a session wants, as the options ask.
Every way into a session comes through here, and not `ecc-start'
alone: an Emacs that only resumed a session was left without the hook
that follows the source buffer, and `@region' and its like then had
nothing to read (FR-CTX-1)."
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
    (ecc-track-source-buffer-mode 1)))

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
    (ecc-proc-start session)
    (ecc--enable-session-modes)
    (ecc-window-select-session session)
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
  (ecc--enable-session-modes)
  (ecc-display-session session)
  session)

(defconst ecc--session-time-units
  '((31536000 . "year") (2592000 . "month") (604800 . "week")
    (86400 . "day") (3600 . "hour") (60 . "minute"))
  "Seconds and the name of the unit, largest first.
The month and the year are the rounded ones a reader expects of \"3
months ago\"; nothing here is meant to be a calendar.")

(defun ecc--session-time-label (time)
  "Return how long ago TIME was, in words, or an empty string when nil.
The list of sessions is read to tell one conversation from another, and
which one was last worked in is what tells them apart; the reading is
kept to a single unit (\"3 hours ago\") for that reason."
  (if (null time)
      ""
    (let ((age (float-time (time-subtract (current-time) time))))
      (if (< age 60)
          "just now"
        (let ((unit (seq-find (lambda (u) (>= age (car u)))
                              ecc--session-time-units)))
          (let ((n (floor (/ age (car unit)))))
            (format "%d %s%s ago" n (cdr unit) (if (= n 1) "" "s"))))))))

(defun ecc--session-time (session)
  "Return when SESSION was last worked in, or nil.
A session this Emacs started carries the time of its last result.  One
that has not answered yet -- a session just started, or one read back
from a recording -- falls back to when its recording was last written."
  (or (ecc-session-last-result-time session)
      (when-let* ((file (ecc-history-file (ecc-session-id session)))
                  (attributes (file-attributes file)))
        (file-attribute-modification-time attributes))))

(defface ecc-session-running-face
  '((t :inherit success))
  "Face for the icon of a session this Emacs is running."
  :group 'ecc)

(defface ecc-session-own-face
  '((t :inherit font-lock-keyword-face))
  "Face for the icon of a stopped session this Emacs still holds."
  :group 'ecc)

(defface ecc-session-elsewhere-face
  '((t :inherit warning))
  "Face for the icon of a session another process is running."
  :group 'ecc)

(defface ecc-session-recorded-face
  '((t :inherit shadow))
  "Face for the icon of a conversation that is only a recording."
  :group 'ecc)

(defcustom ecc-session-status-icons
  '((running "nf-cod-triangle_right" ">" ecc-session-running-face)
    (own "nf-cod-circle_small_filled" "*" ecc-session-own-face)
    (elsewhere "nf-cod-broadcast" "@" ecc-session-elsewhere-face)
    (recorded "nf-cod-history" "-" ecc-session-recorded-face))
  "Icon of each state a session can be offered in.
Each entry is (STATE NERD-ICON-NAME ASCII FACE).  `running' is a
session this Emacs is running, `own' one it holds that has stopped,
`elsewhere' one another process is running, and `recorded' a
conversation that is only a recording.  The nerd icon is used when
`nerd-icons' is installed and the ASCII stand-in otherwise, as in
`ecc-visual-icon-alist'."
  :type '(alist :key-type symbol
                :value-type (list string string face))
  :group 'ecc)

(defcustom ecc-session-icon-height 0.8
  "How tall the icon of a session is, as a share of the normal height.
Only a graphical display scales an icon; on a terminal it is one cell
whatever this says."
  :type 'number
  :group 'ecc)

(declare-function nerd-icons-codicon "nerd-icons" (name &rest args))

(defun ecc--session-status-icon (status)
  "Return the one-column icon of STATUS, a key of `ecc-session-status-icons'.
It is drawn in the face of its state, so that a running session is told
from a recording before the line is read at all."
  (let* ((entry (or (alist-get status ecc-session-status-icons)
                    (alist-get 'recorded ecc-session-status-icons)))
         (face (nth 2 entry))
         (glyph (and (ecc-visual-nerd-icons-p)
                     (condition-case nil
                         (nerd-icons-codicon (nth 0 entry)
                                             :face face
                                             :height ecc-session-icon-height)
                       (error nil)))))
    (or glyph (propertize (nth 1 entry) 'face face))))

(defun ecc--session-label (status name time rest)
  "Return the line a session is offered on.
STATUS is the icon it opens with, NAME the conversation, TIME how long
ago it was worked in and REST whatever is left to say about it.  The
fields are measured in columns rather than in characters, so that a
Japanese title leaves the ones after it where they are."
  (format "%s %s  %s  %s"
          (ecc--session-status-icon status)
          (ecc--column name 36)
          (ecc--column (ecc--session-time-label time) 14)
          (ecc--fit rest 60)))

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
          (push (cons (ecc--session-label
                       (if (process-live-p (ecc-session-process session))
                           'running 'own)
                       (ecc-session-name session)
                       (ecc--session-time session)
                       (abbreviate-file-name (or (ecc-session-cwd session) "")))
                      id)
                candidates))))
    (dolist (info (ecc-history-recordings project-root))
      (let* ((id (alist-get 'session-id info))
             (entry (and id (ecc-registry-session id))))
        (unless (or (null id) (gethash id seen))
          (puthash id t seen)
          (push (cons (ecc--session-label
                       (if entry 'elsewhere 'recorded)
                       (or (alist-get 'title info) id)
                       (or (alist-get 'time info) (alist-get 'mtime info))
                       (or (alist-get 'prompt info) ""))
                      id)
                candidates))))
    (nreverse candidates)))

(defun ecc--session-table (candidates)
  "Return a completion table over the labels of CANDIDATES.
The candidates are already in the order they should be read in -- the
sessions of this Emacs first, then the recordings, most recently used
first -- so the table says so, rather than leaving the completion UI
to sort them by name or by length."
  (let ((labels (mapcar #'car candidates)))
    (lambda (string predicate action)
      (if (eq action 'metadata)
          '(metadata (category . ecc-session)
                     (display-sort-function . identity)
                     (cycle-sort-function . identity))
        (complete-with-action action labels string predicate)))))

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
                         (let ((label (completing-read
                                       (or prompt "Session: ")
                                       (ecc--session-table candidates)
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
                        (ecc-session-stream-buffer session)))
    (when (buffer-live-p buffer)
      (kill-buffer buffer)))
  (message "Stopped %s" (ecc-session-name session)))

(provide 'ecc)

;;; ecc.el ends here
