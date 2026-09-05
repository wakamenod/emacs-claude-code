;;; ecc-history.el --- Read a recorded conversation back  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; The CLI keeps every conversation as one JSON object per line under
;; ~/.claude/projects.  This module reads such a file back into the model
;; of section 3, so that a past session can be read in the same buffer as
;; a live one and then resumed (FR-HIST-1 to 3, section 6.8 of
;; IMPLEMENTATION_PLAN.md).
;;
;; The file is read from the end: opening it costs the last
;; `ecc-history-page-turns' turns, and the button at the top of the
;; buffer adds the page before that.  Only the lines of the page are
;; parsed; the rest is walked as text (plan section 9, item 14).
;;
;; Recorded lines go through `ecc-dispatch' exactly like live ones, with
;; the hooks that act on the world switched off: a replay must not revert
;; a buffer, fill the Inbox or raise a notification.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ecc-core)
(require 'ecc-protocol)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-dispatch)

(declare-function ecc-render-refresh "ecc-render" (session))
(declare-function ecc-session-ensure-buffer "ecc-session" (session))
(declare-function ecc-display-session "ecc-window" (session))

(defcustom ecc-history-directory "~/.claude/projects/"
  "Directory the CLI keeps its recorded conversations in.
It holds one subdirectory per working directory, each with one jsonl
file per session."
  :type 'directory
  :group 'ecc)

(defcustom ecc-history-page-turns 50
  "Number of turns read when a recorded conversation is opened (FR-HIST-1)."
  :type 'integer
  :group 'ecc)

(defcustom ecc-history-include-sidechain nil
  "Non-nil replays the subagent lines of a recorded conversation.
The CLI of this version writes none: a subagent leaves its transcript
beside the session file instead, so the lines are skipped and only
counted (FR-HIST-2).  See docs/verified.md."
  :type 'boolean
  :group 'ecc)

(defconst ecc-history-suppressed-hooks
  '(ecc-sync-file-changed-hook
    ecc-request-added-hook
    ecc-request-resolved-hook
    ecc-session-exited-hook
    ecc-compact-hook)
  "Hooks silenced while a recorded conversation is replayed.
These are the ones that act on the world rather than describe the
model: reverting a buffer, filling the Inbox, raising a notification.
Everything the renderer listens to is left alone, and a replay simply
draws once at the end.")

(defvar ecc-history--files (make-hash-table :test #'equal)
  "Hash mapping a session id to the history file it was read from.")

;;;; Finding the files

(defun ecc-history-project-directory (root)
  "Return the name the CLI gives the history directory of ROOT.
Every character that is not a letter, a digit or a dash becomes a dash,
which turns a path into one flat name.  The path is the one with the
symbolic links resolved, which is what the CLI writes: a session
started in /var/folders is recorded under /private/var/folders on
macOS.  Checked against every recording on this machine, see
docs/verified.md."
  (let ((path (directory-file-name (file-truename (expand-file-name root)))))
    (replace-regexp-in-string "[^A-Za-z0-9-]" "-" path)))

(defun ecc-history-files ()
  "Return every recorded conversation under `ecc-history-directory'.
Only the files one level down are session files; a subdirectory holds
the working files of a session, not another conversation."
  (let ((root (expand-file-name ecc-history-directory)))
    (when (file-directory-p root)
      (seq-mapcat (lambda (directory)
                    (directory-files directory t "\\.jsonl\\'"))
                  (seq-filter #'file-directory-p
                              (directory-files root t directory-files-no-dot-files-regexp))))))

(defun ecc-history-file (session-id)
  "Return the recorded conversation of SESSION-ID, or nil.
The directory a session was recorded in follows its working directory,
which Emacs may not know, so the file is looked for by name."
  (or (gethash session-id ecc-history--files)
      (car (file-expand-wildcards
            (expand-file-name (format "*/%s.jsonl" session-id)
                              (expand-file-name ecc-history-directory))))))

;;;; Reading the file (plan section 9, item 14)

(defun ecc-history-lines (file)
  "Return the non-empty lines of FILE as a list of strings."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents file))
    (split-string (buffer-string) "\n" t)))

(defun ecc-history-turn-starts (lines)
  "Return the indices of LINES that open a turn, oldest first.
A line is only parsed when its type says it might be a prompt, which
is what makes paging over a long recording cheap."
  (let ((index -1) starts)
    (dolist (line lines (nreverse starts))
      (cl-incf index)
      (when (and (ecc-protocol-history-user-line-p line)
                 (when-let* ((message (ecc-protocol-history-parse line)))
                   (ecc-protocol-history-prompt message)))
        (push index starts)))))

(defun ecc-history-page-start (starts n &optional before)
  "Return the index the last N turns of STARTS begin at.
With BEFORE, only the turns that start before that index are counted,
which is what reading one page further back asks for.  Returns nil
when there is no turn left to read."
  (let ((earlier (if before (seq-filter (lambda (i) (< i before)) starts) starts)))
    (when earlier
      (nth (max 0 (- (length earlier) n)) earlier))))

(defun ecc-history--offset (starts from)
  "Return the paging position of a page that starts at line FROM.
Zero when no turn of STARTS begins before FROM: the lines left over are
the bookkeeping the CLI writes before the first prompt, and offering to
read them would offer nothing (FR-HIST-1)."
  (if (seq-find (lambda (index) (< index from)) starts) from 0))

;;;; Replaying (plan section 6.8)

(defun ecc-history--close-turn (session time)
  "Close the turn SESSION is in at TIME, without counting a cost.
A recording holds no result message, so the turn is closed by the
prompt that follows it or by the end of the page."
  (when-let* ((turn (ecc-session-current-turn session)))
    (setf (ecc-turn-end-time turn) (or time (current-time)))
    (setf (ecc-session-current-turn session) nil)
    turn))

(defun ecc-history--note-sidechain (session count)
  "Note in SESSION that COUNT subagent lines were skipped (FR-HIST-2)."
  (when (> count 0)
    (ecc-model-add-node session :type 'system :status 'done
                        :data (list (cons 'kind 'sidechain)
                                    (cons 'text (format "サイドチェーン %d 行を省略"
                                                        count))))))

(defun ecc-history--note-turn-duration (session message)
  "Take the length of the turn SESSION is in from MESSAGE.
A recording has no result message, so `system/turn_duration' is the
only place the time the CLI measured is written down."
  (when-let* ((turn (ecc-session-current-turn session))
              (ms (alist-get 'durationMs message)))
    (setf (ecc-turn-result turn) (list (cons 'duration_ms ms)))))

(defun ecc-history--note-system (session message)
  "Keep the recording-only system MESSAGE of SESSION as a folded note.
The stream never sends these, so handing them to `ecc-dispatch' would
file them among the messages this version does not understand; they are
bookkeeping and belong out of the way (FR-HIST-2)."
  (ecc-model-add-node session :type 'system :status 'done
                      :data (list (cons 'kind 'history)
                                  (cons 'text (or (alist-get 'content message)
                                                  (alist-get 'subtype message)
                                                  "system"))
                                  (cons 'message message))))

(defun ecc-history--replay-line (session message prompt time)
  "Apply the recorded MESSAGE, timestamped TIME, to SESSION.
PROMPT is what the message opens a turn with, or nil."
  (cond
   (prompt
    (ecc-history--close-turn session time)
    (let ((turn (ecc-model-begin-turn session prompt)))
      (when time (setf (ecc-turn-start-time turn) time))))
   ((equal (alist-get 'type message) "system")
    (pcase (alist-get 'subtype message)
      ("turn_duration" (ecc-history--note-turn-duration session message))
      ((pred (lambda (subtype) (member subtype ecc-dispatch-system-subtypes)))
       (ecc-dispatch session message))
      (_ (ecc-history--note-system session message))))
   (t (ecc-dispatch session message))))

(defun ecc-history--replay-lines (session lines)
  "Feed LINES of a recorded conversation to SESSION and return the turns made.
Each prompt opens a turn, everything else goes through `ecc-dispatch'."
  (let ((made 0) (sidechain 0) (time nil))
    (dolist (line lines)
      (when-let* ((message (ecc-protocol-history-parse line)))
        (when-let* ((stamp (ecc-protocol-history-timestamp message)))
          (setq time stamp))
        (if (and (ecc-protocol-history-sidechain-p message)
                 (not ecc-history-include-sidechain))
            (cl-incf sidechain)
          (let ((prompt (ecc-protocol-history-prompt message)))
            (when prompt
              ;; The skipped lines belong to the turn they were in.
              (ecc-history--note-sidechain session sidechain)
              (setq sidechain 0)
              (cl-incf made))
            (ecc-history--replay-line session message prompt time)))))
    (ecc-history--note-sidechain session sidechain)
    (ecc-history--close-turn session time)
    made))

(defun ecc-history--replay (session lines)
  "Replay LINES into SESSION with the hooks of the outside world off.
The state SESSION was in is put back afterwards, so that replaying into
a live session cannot make it look busy."
  (let ((state (ecc-session-state session))
        (current (ecc-session-current-turn session))
        (made 0))
    (cl-progv ecc-history-suppressed-hooks
        (make-list (length ecc-history-suppressed-hooks) nil)
      (setf (ecc-session-current-turn session) nil)
      (unwind-protect
          (setq made (ecc-history--replay-lines session lines))
        (setf (ecc-session-current-turn session) current)
        (ecc-model-set-state session state)))
    made))

;;;; Loading a page (FR-HIST-1)

(defun ecc-history-load (session &optional n-turns file)
  "Read the last N-TURNS turns of the recording of SESSION into it.
N-TURNS defaults to `ecc-history-page-turns' and FILE to the recording
of the session id.  Returns the number of turns read.  The line the
page starts at is kept as the paging position, so that the button at
the top of the buffer can read the page before it (FR-HIST-1)."
  (let* ((file (or file (ecc-history-file (ecc-session-id session))
                   (user-error "No recorded conversation for %s"
                               (ecc-session-id session))))
         (lines (ecc-history-lines file))
         (starts (ecc-history-turn-starts lines))
         (from (or (ecc-history-page-start starts
                                           (or n-turns ecc-history-page-turns))
                   0)))
    (puthash (ecc-session-id session) file ecc-history--files)
    (setf (ecc-session-history-offset session) (ecc-history--offset starts from))
    (prog1 (ecc-history--replay session (nthcdr from lines))
      (ecc-history--redraw session))))

(defun ecc-history-load-more (session &optional n-turns)
  "Read the N-TURNS turns before the ones SESSION already shows.
The turns are put in front of the ones already there, and the buffer
is drawn again from the top (FR-HIST-1).  Returns the number read."
  (interactive (list (or (bound-and-true-p ecc-render--session)
                         (user-error "This buffer is not a session"))))
  (let* ((offset (ecc-session-history-offset session))
         (file (ecc-history-file (ecc-session-id session))))
    (cond
     ((or (null offset) (null file) (<= offset 0))
      (message "これ以上古いメッセージはありません")
      0)
     (t
      (let* ((lines (ecc-history-lines file))
             (starts (ecc-history-turn-starts lines))
             (from (or (ecc-history-page-start
                        starts (or n-turns ecc-history-page-turns) offset)
                       0))
             (older (seq-subseq lines from offset))
             (existing (ecc-session-turns session))
             (made 0))
        ;; The model appends, so the older turns are replayed into an
        ;; empty list and the turns already read are put back after them.
        (setf (ecc-session-turns session) nil)
        (unwind-protect
            (setq made (ecc-history--replay session older))
          (setf (ecc-session-turns session)
                (append (ecc-session-turns session) existing)))
        (setf (ecc-session-history-offset session) (ecc-history--offset starts from))
        (ecc-history--redraw session)
        (message "古い %d ターンを読み込みました" made)
        made)))))

(defun ecc-history--redraw (session)
  "Draw the buffer of SESSION again, if it has one.
A page read at the front moves every turn, so the whole buffer is
drawn rather than the live region alone."
  (when (buffer-live-p (ecc-session-buffer session))
    (require 'ecc-render)
    (ecc-render-refresh session)))

(defun ecc-history-more-p (session)
  "Return non-nil when SESSION has an older page left to read."
  (let ((offset (ecc-session-history-offset session)))
    (and offset (> offset 0))))

;;;; Opening a recorded conversation (FR-DASH-3)

(defun ecc-history-scan-file (file &optional head tail)
  "Return what FILE says about itself, without reading all of it.
The first HEAD lines say where the session ran, the last TAIL ones how
it ended; the CLI repeats its title, its cost and the prompt after
every turn, so the tail holds the current values (plan section 6.7).
The alist also carries `file', `session-id' and `mtime'."
  (let* ((head (or head 5))
         (tail (or tail 40))
         (lines (ecc-history-lines file))
         (info (list (cons 'file file)
                     (cons 'session-id (file-name-base file))
                     (cons 'mtime (file-attribute-modification-time
                                   (file-attributes file))))))
    (dolist (line (seq-take lines head))
      (setq info (ecc-protocol-history-info line info)))
    (dolist (line (last lines tail))
      (setq info (ecc-protocol-history-info line info)))
    info))

(defun ecc-history-session (session-id &optional file)
  "Return a session that shows the recording of SESSION-ID, reading it.
FILE is the recording to read, or nil to look for the one of SESSION-ID.
An existing session with that id is returned as it is; otherwise an
archived session is made, so that the recording can be read in the
same kind of buffer as a live conversation and resumed from there."
  (or (ecc-model-session session-id)
      (let* ((file (or file (ecc-history-file session-id)
                       (user-error "No recorded conversation for %s" session-id)))
             (info (ecc-history-scan-file file))
             (root (or (alist-get 'cwd info) default-directory))
             (session (ecc-model-create-session
                       :id session-id
                       :name (or (alist-get 'title info)
                                 (file-name-nondirectory
                                  (directory-file-name root)))
                       :project-root root
                       :kind 'archived)))
        (puthash session-id file ecc-history--files)
        (ecc-model-set-state session 'exited)
        (setf (ecc-session-total-cost session) (or (alist-get 'cost info) 0))
        session)))

;;;###autoload
(defun ecc-history-open (session-id)
  "Show the recorded conversation SESSION-ID in a session buffer (FR-DASH-3).
Interactively the recordings are offered by name."
  (interactive
   (list (let* ((files (ecc-history-files))
                (names (mapcar (lambda (file)
                                 (cons (format "%s  %s" (file-name-base file)
                                               (abbreviate-file-name
                                                (directory-file-name
                                                 (file-name-directory file))))
                                       (file-name-base file)))
                               files)))
           (unless names (user-error "No recorded conversation"))
           (cdr (assoc (completing-read "Session: " (mapcar #'car names) nil t)
                       names)))))
  (let ((session (ecc-history-session session-id)))
    (require 'ecc-session)
    (ecc-session-ensure-buffer session)
    (when (null (ecc-session-turns session))
      (ecc-history-load session))
    (require 'ecc-window)
    (ecc-display-session session)
    session))

;;;; Resuming what was read (FR-HIST-3, FR-SES-4)

;;;###autoload
(defun ecc-history-resume (session &optional fork)
  "Start SESSION again, keeping what the recording said (FR-HIST-3).
The turns already read stay at the top of the buffer and the stream is
appended to them.  FORK asks the CLI for a new conversation branching
off this one (FR-SES-4).  A session whose process is still alive is
never resumed: the CLI would run twice on the same recording."
  (when (process-live-p (ecc-session-process session))
    (user-error "%s はまだ動いています" (ecc-session-name session)))
  (when (and (null (ecc-session-turns session))
             (ecc-history-file (ecc-session-id session)))
    (ecc-history-load session))
  (setf (ecc-session-kind session) 'own)
  (require 'ecc-session)
  (ecc-session-ensure-buffer session)
  (ecc-proc-start session t fork)
  session)

(provide 'ecc-history)

;;; ecc-history.el ends here
