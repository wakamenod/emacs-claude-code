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
(require 'ecc-registry)

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

(defvar ecc-history--abandoned (make-hash-table :test #'equal)
  "Hash mapping a session id to the uuids of its abandoned branches.
Worked out once when the recording is opened and used again by every
page read after that.")

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

(defun ecc-history-turn-starts (lines &optional abandoned)
  "Return the indices of LINES that open a turn, oldest first.
A line is only parsed when its type says it might be a prompt, which
is what makes paging over a long recording cheap.  ABANDONED, when
given, is the hash of uuids of a branch nobody continued; a turn of
one of those is not a turn of this conversation (FR-HIST-1)."
  (let ((index -1) starts)
    (dolist (line lines (nreverse starts))
      (cl-incf index)
      (when (and (ecc-protocol-history-user-line-p line)
                 (when-let* ((message (ecc-protocol-history-parse line)))
                   (and (ecc-protocol-history-prompt message)
                        (not (and abandoned
                                  (gethash (alist-get 'uuid message)
                                           abandoned))))))
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

;;;; Branches (FR-HIST-1)

;; A recording is a tree, not a list.  Editing an earlier message in the
;; interactive CLI, interrupting a turn, and two processes resuming the
;; same session all hang a new message off an older parent, and the
;; abandoned branch stays in the file.  Reading the lines in the order
;; they were written would show both branches at once.
;;
;; The CLI writes which message the conversation now hangs from into a
;; `last-prompt' line after every turn; the last one is the branch a
;; resume would continue.  Walking up from there gives the current
;; series.  What is left over is only dropped when it hangs off that
;; series: a compaction starts a fresh root, and everything before it is
;; a different tree, not an abandoned branch, so it stays (verified
;; against every recording on this machine, see docs/verified.md).

(defun ecc-history--links (lines)
  "Return a hash mapping the uuid of each of LINES to that of its parent."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (line lines table)
      (when-let* ((link (ecc-protocol-history-link line)))
        (puthash (car link) (cdr link) table)))))

(defun ecc-history--leaf (lines)
  "Return the uuid LINES last said the conversation hangs from, or nil."
  (let (leaf)
    (dolist (line lines leaf)
      (when-let* ((uuid (ecc-protocol-history-leaf line)))
        (setq leaf uuid)))))

(defun ecc-history--chain (links leaf)
  "Return the uuids on the way from LEAF to its root, following LINKS."
  (let ((chain (make-hash-table :test #'equal))
        (uuid leaf))
    (while (and uuid (not (gethash uuid chain)))
      (puthash uuid t chain)
      (setq uuid (gethash uuid links)))
    chain))

(defun ecc-history-abandoned (lines)
  "Return the uuids of LINES that belong to a branch nobody continued.
Nil when the recording says nothing about where it hangs from, in
which case every line is shown in the order it was written."
  (let ((leaf (ecc-history--leaf lines)))
    (when leaf
      (let* ((links (ecc-history--links lines))
             (chain (ecc-history--chain links leaf))
             (abandoned (make-hash-table :test #'equal)))
        (maphash
         (lambda (uuid _parent)
           (unless (gethash uuid chain)
             ;; Off the series: dropped only when an ancestor is on it,
             ;; which is what makes it a branch of this conversation
             ;; rather than an older tree of the same file.
             (let ((seen (make-hash-table :test #'equal))
                   (up (gethash uuid links)))
               (while (and up (not (gethash up seen)) (not (gethash up chain)))
                 (puthash up t seen)
                 (setq up (gethash up links)))
               (when (and up (gethash up chain))
                 (puthash uuid t abandoned)))))
         links)
        (and (> (hash-table-count abandoned) 0) abandoned)))))

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

(defun ecc-history--replay-lines (session lines &optional abandoned)
  "Feed LINES of a recorded conversation to SESSION and return the turns made.
Each prompt opens a turn, everything else goes through `ecc-dispatch'.
ABANDONED, when given, is the hash of uuids that belong to a branch
nobody continued; those lines are left out (FR-HIST-1)."
  (let ((made 0) (sidechain 0) (time nil))
    (dolist (line lines)
      (when-let* ((message (ecc-protocol-history-parse line)))
        (when-let* ((stamp (ecc-protocol-history-timestamp message)))
          (setq time stamp))
        (cond
         ((and abandoned (gethash (alist-get 'uuid message) abandoned)) nil)
         ((and (ecc-protocol-history-sidechain-p message)
               (not ecc-history-include-sidechain))
          (cl-incf sidechain))
         (t
          (let ((prompt (ecc-protocol-history-prompt message)))
            (when prompt
              ;; The skipped lines belong to the turn they were in.
              (ecc-history--note-sidechain session sidechain)
              (setq sidechain 0)
              (cl-incf made))
            (ecc-history--replay-line session message prompt time))))))
    (ecc-history--note-sidechain session sidechain)
    (ecc-history--close-turn session time)
    made))

(defun ecc-history--replay (session lines &optional abandoned)
  "Replay LINES into SESSION with the hooks of the outside world off.
ABANDONED is passed to `ecc-history--replay-lines'.  The state SESSION
was in is put back afterwards, so that replaying into a live session
cannot make it look busy."
  (let ((state (ecc-session-state session))
        (current (ecc-session-current-turn session))
        (made 0))
    (cl-progv ecc-history-suppressed-hooks
        (make-list (length ecc-history-suppressed-hooks) nil)
      (setf (ecc-session-current-turn session) nil)
      (unwind-protect
          (setq made (ecc-history--replay-lines session lines abandoned))
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
         (abandoned (ecc-history-abandoned lines))
         (starts (ecc-history-turn-starts lines abandoned))
         (from (or (ecc-history-page-start starts
                                           (or n-turns ecc-history-page-turns))
                   0)))
    (puthash (ecc-session-id session) file ecc-history--files)
    (puthash (ecc-session-id session) abandoned ecc-history--abandoned)
    (setf (ecc-session-history-offset session) (ecc-history--offset starts from))
    (prog1 (ecc-history--replay session (nthcdr from lines) abandoned)
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
             (abandoned (gethash (ecc-session-id session) ecc-history--abandoned))
             (starts (ecc-history-turn-starts lines abandoned))
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
            (setq made (ecc-history--replay session older abandoned))
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

(defcustom ecc-history-scan-head-bytes 8192
  "Bytes read from the start of a recording when it is only described.
Enough for the first few lines, which say where the session ran."
  :type 'integer
  :group 'ecc)

(defcustom ecc-history-scan-tail-bytes 65536
  "Bytes read from the end of a recording when it is only described.
The CLI repeats the title, the cost and the last prompt after every
turn, so the end holds the current values."
  :type 'integer
  :group 'ecc)

(defun ecc-history--edges (file)
  "Return the first and last lines of FILE without reading the middle.
A recording runs to megabytes and the session list describes dozens of
them, so only `ecc-history-scan-head-bytes' from the front and
`ecc-history-scan-tail-bytes' from the back are read.  The line the
two ranges cut through is dropped rather than guessed at."
  (let ((size (or (file-attribute-size (file-attributes file)) 0))
        (head ecc-history-scan-head-bytes)
        (tail ecc-history-scan-tail-bytes))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix))
        (if (<= size (+ head tail))
            (insert-file-contents file)
          (insert-file-contents file nil 0 head)
          ;; The last line of the head range was cut in the middle, so it
          ;; is thrown away; the newline before it is kept, because the
          ;; tail is about to be added after it.
          (goto-char (point-max))
          (if (search-backward "\n" nil t)
              (delete-region (1+ (point)) (point-max))
            (erase-buffer))
          ;; The tail range starts in the middle of a line too, so its
          ;; first whole line is the one after the first newline.
          (let ((start (point-max)))
            (goto-char start)
            (insert-file-contents file nil (- size tail) size)
            (goto-char start)
            (when (search-forward "\n" nil t)
              (delete-region start (point))))))
      (split-string (buffer-string) "\n" t))))

(defun ecc-history-scan-file (file)
  "Return what FILE says about itself, without reading all of it.
The first lines say where the session ran, the last ones how it ended
\(plan section 6.7).  The alist also carries `file', `session-id' and
`mtime'."
  (let ((info (list (cons 'file file)
                    (cons 'mtime (file-attribute-modification-time
                                  (file-attributes file))))))
    (dolist (line (ecc-history--edges file))
      (setq info (ecc-protocol-history-info line info)))
    ;; The name of the file is the id --resume takes.  What the lines say
    ;; is only what the session called itself while it was written, which
    ;; is not the same thing once a file has been copied or renamed.
    (setf (alist-get 'session-id info) (file-name-base file))
    info))

(defun ecc-history-recordings (&optional project-root)
  "Return a description of every recording, most recently used first.
With PROJECT-ROOT, only the recordings whose working directory is under
it.  Each is the alist of `ecc-history-scan-file' (FR-DASH-2 c)."
  (let* ((root (and project-root
                    (file-name-as-directory
                     (file-truename (expand-file-name project-root)))))
         (infos (mapcar #'ecc-history-scan-file (ecc-history-files))))
    (seq-sort
     (lambda (a b)
       (let ((ta (or (alist-get 'time a) (alist-get 'mtime a)))
             (tb (or (alist-get 'time b) (alist-get 'mtime b))))
         (cond ((and ta tb) (time-less-p tb ta)) (ta t) (t nil))))
     (if root
         (seq-filter (lambda (info)
                       (when-let* ((cwd (alist-get 'cwd info)))
                         (string-prefix-p root (file-name-as-directory
                                                (file-truename cwd)))))
                     infos)
       infos))))

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
(defun ecc-history--check-not-running (session)
  "Refuse to resume SESSION while another process is running it (FR-TUI-5).
There is no lock: a second CLI on the same session id writes into the
same recording, and the conversation quietly grows a second branch
\(docs/verified.md).  The way out is to stop the other one first, so
this asks rather than deciding, and names the process."
  (when-let* ((entry (ecc-registry-session (ecc-session-id session))))
    (unless (yes-or-no-p
             (format "%s は pid %s が実行中です。続けると会話が分岐します。それでも resume しますか? "
                     (or (alist-get 'name entry) (ecc-session-name session))
                     (or (alist-get 'pid entry) "?")))
      (user-error "中止しました"))))

(defun ecc-history-resume (session &optional fork)
  "Start SESSION again, keeping what the recording said (FR-HIST-3).
The turns already read stay at the top of the buffer and the stream is
appended to them.  FORK asks the CLI for a new conversation branching
off this one (FR-SES-4).  A session whose process is still alive is
never resumed: the CLI would run twice on the same recording."
  (when (process-live-p (ecc-session-process session))
    (user-error "%s はまだ動いています" (ecc-session-name session)))
  (ecc-history--check-not-running session)
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
