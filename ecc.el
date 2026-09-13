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
;; Start one with \\[ecc-start].

;;; Code:

(require 'cl-lib)
(require 'lisp-mnt)
(require 'package)
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-diff)
(require 'ecc-table)
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
(require 'ecc-answer)
(require 'ecc-registry)
(require 'ecc-history)
(require 'ecc-search)
(require 'ecc-dashboard)
(require 'ecc-window)
(require 'ecc-context)
(require 'ecc-notify)
(require 'ecc-hint)
(require 'ecc-usage)
(require 'ecc-mcp)
(require 'ecc-inline)
(require 'ecc-btw)
(require 'ecc-auth)
(require 'ecc-tui)
(require 'ecc-transient)

;; The version is written once, in the Version header above, because that
;; is the one package.el and `package-vc-install' read.  Repeating it in a
;; constant here would mean a release that says two different things, so
;; it is read back instead: from the package descriptor when ecc was
;; installed, and from the header of ecc.el itself when it was only put on
;; `load-path'.
(defconst ecc-version
  (or (ignore-errors (package-get-version))
      (ignore-errors
        (let ((file (expand-file-name
                     "ecc.el"
                     (file-name-directory (or load-file-name
                                              buffer-file-name
                                              default-directory)))))
          (and (file-readable-p file)
               (with-temp-buffer
                 (insert-file-contents file nil 0 4096)
                 (lm-header "version")))))
      "unknown")
  "The version of ecc that is loaded, as its Version header says.")

;;;###autoload
(defun ecc-version (&optional here)
  "Show which ecc, Emacs and Claude Code CLI are running.
With a prefix argument HERE, insert the line at point instead.  It is
what a bug report has to open with: nearly everything this package works
around belongs to one version of the CLI, and the CLI is the piece that
moves without anybody upgrading anything."
  (interactive "P")
  (let* ((cli (or (ecc--cli-version) "not found"))
         (line (format "ecc %s, Emacs %s, Claude Code CLI %s"
                       ecc-version emacs-version cli)))
    (if here (insert line) (message "%s" line))))

(defun ecc--cli-version ()
  "Return what `ecc-executable' says its version is, or nil.
The CLI prints something like \"2.1.268 (Claude Code)\"; only the number
is kept.  A missing or silent executable is a nil, not an error: the
point of `ecc-version' is to report on a machine that is already broken."
  (ignore-errors
    (with-temp-buffer
      (when (and (executable-find ecc-executable)
                 (eq 0 (call-process ecc-executable nil t nil "--version")))
        (goto-char (point-min))
        (when (re-search-forward "[0-9][^ \t\n]*" nil t)
          (match-string 0))))))

(defun ecc-project-root ()
  "Return the root of the project of the current buffer, or its directory."
  (ecc-window-project-root))

(defun ecc--enable-session-modes ()
  "Turn on the global modes every session wants.
Every way into a session comes through here, and not `ecc-start' alone:
an Emacs that only resumed a session was left without the hook that
follows the source buffer, and `@region' and its like then had nothing
to read.

There is deliberately no setting to leave one of them off (decided
2026-09-10): each is what makes a session visible -- the count of
waiting requests, the announcements, the tab line, the buffer the
context is quoted from -- and a session that started without them was a
session that looked broken.  A mode turned off by hand comes back with
the next session, since this runs on every one of them."
  (ecc-pending-indicator-mode 1)
  (ecc-notify-mode 1)
  (ecc-tab-line-mode 1)
  (ecc-track-source-buffer-mode 1))

;;;###autoload
(defun ecc-start (&optional directory name)
  "Start a Claude Code session in DIRECTORY under NAME.
Interactively the project of the buffer the user is working in is used,
and a prefix argument asks for the directory and the name.  Where the
session started is said in the echo area either way: it is the moment a
session in the wrong project can be caught, and the alternative is
finding it later among all the others."
  (interactive (ecc-start--read-arguments))
  (let ((session (ecc-model-create-session
                  :project-root (or directory (ecc-window-context-project-root))
                  :name (and name (not (string-empty-p name)) name))))
    (ecc-session-ensure-buffer session)
    (ecc-proc-start session)
    (ecc--enable-session-modes)
    (ecc-window-select-session session)
    (message "Started %s in %s" (ecc-session-name session)
             (abbreviate-file-name (ecc-session-project-root session)))
    session))

(defun ecc-start--read-arguments ()
  "Return the (DIRECTORY NAME) a new session should be started with.
This is the interactive form of `ecc-start\=', out here where a test can
reach it.  The directory comes from the buffer the user is working in
rather than from whichever buffer happens to be current: `ecc-start\=' is
run from a transcript, the dashboard or the scratch buffer as often as
from a file, and none of those says which project was meant."
  (let ((root (ecc-window-context-project-root)))
    (if current-prefix-arg
        (list (read-directory-name "Directory: " root)
              (read-string "Session name: "))
      ;; The second session of a project is told from the first by a name
      ;; the user gives it.
      (list root (ecc-window-read-session-name root)))))

;;;###autoload
(defun ecc-resume (session &optional fork)
  "Start SESSION again with --resume, forking it when FORK is non-nil.
A SESSION that is already running is not resumed but gone to: what the
user asked for is that conversation, and whether a process happens to
be alive under it is the package\='s business, not theirs.  Its window is
selected as a resumed one\='s is, and nothing else is touched.  FORK on a
running session is refused for now rather than guessed at: a second
process on a live recording forks the conversation, which is a real
thing to want but not the same thing as this.

Interactively, the session of the current buffer is resumed when it has
stopped -- that is the R offered after an exit -- and a choice is asked
for otherwise.  A prefix argument forks it into a new conversation."
  (interactive (list (ecc-read-session "Resume: ") current-prefix-arg))
  (if (process-live-p (ecc-session-process session))
      (progn
        (when fork
          (user-error "Cannot fork %s while it is running"
                      (ecc-session-name session)))
        (ecc--enable-session-modes)
        (ecc-window-select-session session))
    ;; What the recording holds is read first, so that the stream is
    ;; appended to the conversation rather than starting an empty one.
    ;; `ecc-history-resume' refuses a live process.
    (ecc-history-resume session fork)
    (ecc--enable-session-modes)
    ;; Like `ecc-start': the window is selected and point put in the
    ;; prompt, which is what a resumed session is opened to type in.
    (ecc-window-select-session session))
  session)

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

(defvar ecc-session-status-icons
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
`ecc-visual-icon-alist'.")

(defvar ecc-session-icon-height 0.8
  "How tall the icon of a session is, as a share of the normal height.
Only a graphical display scales an icon; on a terminal it is one cell
whatever this says.")

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
and resuming it asks first."
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
The session of the current buffer wins, but only once it has stopped:
that is the R pressed on an exit, and asking there would be a question
with one answer.  A buffer whose session is still running is asked in
like any other, so that the other sessions can be reached from inside
one.  Otherwise the sessions of this Emacs and the recordings of the
current project are offered, and the recordings of every project when
this one has none.  A recording that is picked is read back into an
archived session."
  (or (and ecc-render--session
           (not (process-live-p (ecc-session-process ecc-render--session)))
           ecc-render--session)
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
  "Offer to resume SESSION, whose CLI stopped with STATUS.
The state is in the buffer already; this is the offer that goes with
it.  Only an exit the user did not ask for is offered, and only when
there is a recording to resume from.  The offer is made from a timer:
a sentinel is no place to ask a question or start a process."
  (when (and (integerp status)
             (/= status 0)
             (not (ecc-proc-stopped-on-request-p session))
             (ecc-history-file (ecc-session-id session)))
    (run-at-time 0 nil #'ecc-offer-resume-now session status)))

(defun ecc-offer-resume-now (session status)
  "Ask whether to resume SESSION, which stopped with STATUS.
The offer is always made rather than acted on (decided 2026-09-10): an
exit nobody asked for is worth a look before it is undone.  An Emacs
that wants neither the question nor the offer takes `ecc--offer-resume'
off `ecc-session-exited-hook'."
  (if (y-or-n-p (format "%s exited with code %s.  Resume it? "
                        (ecc-session-name session) status))
      (ecc-resume session)
    (message "%s: R, or M-x ecc-resume, starts it again"
             (ecc-session-name session))))

(add-hook 'ecc-session-exited-hook #'ecc--offer-resume)

;;;###autoload
(defun ecc-kill (session)
  "Stop SESSION and forget it."
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
