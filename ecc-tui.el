;;; ecc-tui.el --- Hand a session over to the real terminal UI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jun

;; Author: Jun <wakamenod@gmail.com>
;; Keywords: tools, processes
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; Section 6.14 of IMPLEMENTATION_PLAN.md (FR-TUI-1 to FR-TUI-5).  The
;; terminal client can do things this one cannot, so a conversation can
;; be carried on there and taken back afterwards.
;;
;; The CLI has no lock on a session: two processes resuming the same id
;; write into the same recording and the conversation quietly grows a
;; second branch (docs/verified.md).  The hand-off is therefore not a
;; second window on the session but a change of hands: the process
;; Emacs runs is interrupted and stopped first, and the terminal is only
;; started once it is gone (FR-TUI-5).
;;
;; While the terminal has it, the buffer follows the recording the CLI
;; writes (FR-TUI-3): the lines the terminal appends are replayed
;; through `ecc-history', so the transcript keeps up without a process
;; of its own.  When the terminal is left, the session comes back
;; headless with --resume (FR-TUI-4).
;;
;; The terminal is ghostel, which draws the CLI's full screen interface
;; with the same engine Ghostty uses.  It takes the command as argv
;; rather than as a shell line, so nothing has to survive quoting, and
;; it hands back the process, which is what tells Emacs the terminal is
;; over.  There is one terminal and no choice of terminal: a window
;; outside Emacs would leave nothing to watch but the session registry,
;; and a terminal that never registers there would strand the session
;; (the decisions list has the reasoning).

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'filenotify)
(require 'ecc-core)
(require 'ecc-model)
(require 'ecc-proc)
(require 'ecc-render)
(require 'ecc-registry)
(require 'ecc-history)

(declare-function ecc-session-ensure-buffer "ecc-session" (session))
(declare-function ecc-window-resolve-session "ecc-window" (&optional force-ask))
(declare-function ghostel-exec "ghostel" (buffer program &optional args identity))

;;;; Options

(defcustom ecc-tui-extra-args nil
  "Extra arguments passed to the CLI started in a terminal."
  :type '(repeat string)
  :group 'ecc)

(defcustom ecc-tui-interrupt-timeout 10
  "Seconds to wait for a running turn to stop before the process is killed."
  :type 'number
  :group 'ecc)

(defcustom ecc-tui-follow t
  "Non-nil follows the recording while a session is open in a terminal.
This is what keeps the transcript current during a hand-off
\(FR-TUI-3); turning it off leaves the buffer as it was until the
session comes back."
  :type 'boolean
  :group 'ecc)

(defcustom ecc-tui-poll-interval 2
  "Seconds between the checks made while a session is in a terminal.
A file notification is a courtesy rather than a promise, so the timer
runs even when the recording is being watched, and it is also what
notices a terminal that ended without its sentinel being called."
  :type 'number
  :group 'ecc)

(defcustom ecc-tui-return-on-exit t
  "Non-nil resumes a session in Emacs once its terminal is left (FR-TUI-4)."
  :type 'boolean
  :group 'ecc)

;;;; What is being handed over

(defvar ecc-tui--handoffs (make-hash-table :test #'equal)
  "Hash mapping a session id to the state of its hand-off.
The value is a plist with `:file' and `:position' for the recording
being followed, `:watch' its file notification descriptor, `:timer'
the poll timer, and `:buffer' and `:process' of the terminal.")

(defun ecc-tui-state (session)
  "Return the hand-off state of SESSION, or nil."
  (gethash (ecc-session-id session) ecc-tui--handoffs))

(defun ecc-tui--put (session key value)
  "Set KEY of the hand-off state of SESSION to VALUE."
  (puthash (ecc-session-id session)
           (plist-put (or (ecc-tui-state session) nil) key value)
           ecc-tui--handoffs))

(defun ecc-tui-handoff-p (session)
  "Return non-nil when SESSION is being driven from a terminal."
  (and (ecc-tui-state session) t))

(defun ecc-tui-sessions ()
  "Return the sessions that are open in a terminal."
  (seq-filter #'ecc-tui-handoff-p (ecc-model-sessions)))

;;;; The command the terminal runs

(defun ecc-tui-arguments (session)
  "Return the command line that opens SESSION in a terminal.
It is the interactive CLI, not the headless one this package drives:
no stream-json, no permission prompt tool, only the session to resume
and the options that decide what it costs.

The hand-off is a resume, so the model is the one the recording ends on
and --model is left out unless this session was given one of its own:
the terminal is where `/model' is easiest to reach, and a model named
here would take the change back on the way in as well as on the way
out (`ecc-proc--model')."
  (append (list ecc-executable "--resume" (ecc-session-id session))
          (when-let* ((model (ecc-proc--model session t)))
            (list "--model" model))
          ecc-tui-extra-args))

;;;; Making sure nobody else has it (FR-TUI-5)

(defun ecc-tui--other-process (session)
  "Return the registry entry of another process running SESSION, or nil.
The process this Emacs runs is not another process."
  (let* ((entry (ecc-registry-session (ecc-session-id session)))
         (pid (and entry (alist-get 'pid entry)))
         (process (ecc-session-process session))
         (ours (and (processp process) (process-live-p process)
                    (process-id process))))
    (and pid (not (equal pid ours)) entry)))

(defun ecc-tui--release (session)
  "Stop the process Emacs runs for SESSION, so a terminal may have it.
A running turn is interrupted first and given `ecc-tui-interrupt-timeout'
seconds to come to an end, because a turn stopped mid-tool leaves the
CLI to write the result of a call that will never finish.  Signals when
the process cannot be stopped: two processes on one session id branch
the conversation without saying so (FR-TUI-5)."
  (let ((process (ecc-session-process session)))
    (when (process-live-p process)
      (when (eq (ecc-session-state session) 'running)
        (ecc-proc-interrupt session)
        (let ((deadline (+ (float-time) ecc-tui-interrupt-timeout)))
          (while (and (eq (ecc-session-state session) 'running)
                      (process-live-p process)
                      (< (float-time) deadline))
            (accept-process-output process 0.2))))
      (ecc-proc-stop session))
    (when (process-live-p (ecc-session-process session))
      (user-error "%s could not be stopped; the terminal would branch the conversation"
                  (ecc-session-name session)))))

;;;; Opening the terminal (FR-TUI-1, FR-TUI-2)

(defun ecc-tui-buffer-name (session)
  "Return the name of the terminal buffer of SESSION."
  (format "*ecc-tui: %s*" (ecc-session-name session)))

(defun ecc-tui-directory (session)
  "Return the directory a terminal for SESSION should start in."
  (or (ecc-session-cwd session) (ecc-session-project-root session)
      default-directory))

(defun ecc-tui--open-ghostel (session)
  "Open SESSION in a ghostel buffer and return (BUFFER . PROCESS).
The CLI is the process of the buffer, so leaving it ends the buffer
and Emacs is told without having to ask (FR-TUI-4)."
  (unless (require 'ghostel nil t)
    (user-error "ghostel is not installed; the hand-off needs it"))
  (unless (fboundp 'ghostel-exec)
    (user-error "This ghostel has no `ghostel-exec'; please update it"))
  (let* ((name (ecc-tui-buffer-name session))
         (stale (get-buffer name)))
    ;; A buffer left over from an earlier hand-off is reused; one that
    ;; still runs something is not touched.
    (when (buffer-live-p stale)
      (when (process-live-p (get-buffer-process stale))
        (user-error "%s already has a terminal running" name))
      (kill-buffer stale))
    (let ((buffer (get-buffer-create name))
          (arguments (ecc-tui-arguments session)))
      (with-current-buffer buffer
        (setq default-directory (ecc-tui-directory session)))
      ;; Shown before the CLI starts, and selected: ghostel sizes the
      ;; terminal to the window the buffer is in when it execs, and the
      ;; point of a hand-off is that the user types in there next.
      (pop-to-buffer buffer)
      (with-current-buffer buffer
        (let ((process (ghostel-exec buffer (car arguments) (cdr arguments))))
          (unless process
            (error "ghostel started no process for %s" (ecc-session-name session)))
          (cons buffer process))))))

;;;###autoload
(defun ecc-tui-open (&optional session)
  "Carry on with SESSION in the real terminal UI (FR-TUI-1).
The turn in flight is interrupted, the process Emacs runs is stopped,
and the terminal resumes the same conversation.  The transcript
follows along and the session comes back when the terminal is left."
  (interactive)
  (let ((session (or session (ecc-window-resolve-session))))
    (when-let* ((entry (ecc-tui--other-process session)))
      (user-error "%s is already running as pid %s; stop it before handing over"
                  (or (alist-get 'name entry) (ecc-session-name session))
                  (or (alist-get 'pid entry) "?")))
    (when (ecc-tui-handoff-p session)
      (user-error "%s is already open in a terminal" (ecc-session-name session)))
    (ecc-tui--release session)
    (setf (ecc-session-kind session) 'handoff)
    (ecc-tui-follow-start session)
    (let* ((opened (ecc-tui--open-ghostel session))
           (buffer (car opened))
           (process (cdr opened)))
      (ecc-tui--put session :buffer buffer)
      (ecc-tui--put session :process process)
      (ecc-tui--watch-process session process))
    (ecc-tui--start-timer session)
    (ecc-render-refresh session)
    (message "%s is in the terminal now; it comes back when you leave it"
             (ecc-session-name session))
    session))

;;;; Following the recording (FR-TUI-3)

(defun ecc-tui-follow-start (session)
  "Start following the recording of SESSION from where it stands now.
What the recording already holds is on screen; only what the terminal
appends from here on is replayed."
  (let ((file (ecc-history-file (ecc-session-id session))))
    (ecc-tui--put session :file file)
    (ecc-tui--put session :position (if file (ecc-tui--file-size file) 0))
    (when (and file ecc-tui-follow)
      (ecc-tui--watch session file))
    file))

(defun ecc-tui--file-size (file)
  "Return the size of FILE in bytes, or 0 when it is not there."
  (or (file-attribute-size (file-attributes file)) 0))

(defun ecc-tui--watch (session file)
  "Watch FILE and read what is appended to it into SESSION."
  (let ((id (ecc-session-id session)))
    (ecc-tui--put session :watch
                  (ignore-errors
                    (file-notify-add-watch
                     file '(change)
                     (lambda (&rest _)
                       (when-let* ((session (ecc-model-session id)))
                         (ecc-tui-read-new-lines session))))))))

(defun ecc-tui-read-new-lines (session)
  "Replay into SESSION whatever the terminal appended to its recording.
Returns the number of lines read.  Only whole lines are taken: a
notification can arrive while the CLI is halfway through writing one."
  (let* ((state (ecc-tui-state session))
         (file (or (plist-get state :file)
                   (let ((found (ecc-history-file (ecc-session-id session))))
                     (when found
                       (ecc-tui--put session :file found)
                       ;; The recording is joined where it stands, as
                       ;; `ecc-tui-follow-start' joins one that was
                       ;; already there: what it holds is on screen
                       ;; already, and reading it from the top would put
                       ;; the whole conversation in a second time.
                       (ecc-tui--put session :position
                                     (ecc-tui--file-size found))
                       (when ecc-tui-follow (ecc-tui--watch session found))
                       found))))
         (from (or (plist-get state :position) 0))
         (size (and file (ecc-tui--file-size file))))
    (cond
     ((or (null file) (null size)) 0)
     ;; The recording was replaced under us; start again from its end
     ;; rather than replaying a file that has nothing to do with what is
     ;; on screen.
     ((< size from) (ecc-tui--put session :position size) 0)
     ((= size from) 0)
     (t
      (let* ((text (with-temp-buffer
                     (let ((coding-system-for-read 'utf-8-unix))
                       (insert-file-contents file nil from size))
                     (buffer-string)))
             (cut (string-match-p "\n[^\n]*\\'" text))
             (whole (if cut (substring text 0 (1+ cut)) nil))
             (lines (and whole (split-string whole "\n" t))))
        (if (null lines)
            0
          (ecc-tui--put session :position (+ from (string-bytes whole)))
          (prog1 (length lines)
            ;; A batch of new lines is not a turn: it is the middle of
            ;; one, so the turn the last batch left open carries on.
            (ecc-history--replay session lines nil t)
            (ecc-render-refresh session))))))))

(defun ecc-tui-follow-stop (session)
  "Stop following the recording of SESSION and forget the hand-off."
  (when-let* ((state (ecc-tui-state session)))
    (when-let* ((watch (plist-get state :watch)))
      (ignore-errors (file-notify-rm-watch watch)))
    (when-let* ((timer (plist-get state :timer)))
      (cancel-timer timer)))
  (remhash (ecc-session-id session) ecc-tui--handoffs))

;;;; Noticing that the terminal is done (FR-TUI-4)

(defun ecc-tui--start-timer (session)
  "Start the timer that watches over the hand-off of SESSION."
  (let ((id (ecc-session-id session)))
    (ecc-tui--put session :timer
                  (run-with-timer ecc-tui-poll-interval ecc-tui-poll-interval
                                  (lambda ()
                                    (if-let* ((session (ecc-model-session id)))
                                        (ecc-tui--tick session)
                                      (ecc-tui--forget id)))))))

(defun ecc-tui--forget (id)
  "Cancel the hand-off of the session ID that is no longer there."
  (when-let* ((state (gethash id ecc-tui--handoffs)))
    (when-let* ((watch (plist-get state :watch)))
      (ignore-errors (file-notify-rm-watch watch)))
    (when-let* ((timer (plist-get state :timer)))
      (cancel-timer timer))
    (remhash id ecc-tui--handoffs)))

(defun ecc-tui--tick (session)
  "Read what the terminal wrote for SESSION and see whether it is over."
  (condition-case err
      (progn
        (when ecc-tui-follow (ecc-tui-read-new-lines session))
        (when (ecc-tui-finished-p session)
          (if ecc-tui-return-on-exit
              (ecc-tui-return session)
            (ecc-tui-follow-stop session))))
    (error (ecc-log (ecc-session-name session) "hand-off: %s"
                    (error-message-string err)))))

(defun ecc-tui-finished-p (session)
  "Return non-nil when the terminal that had SESSION is gone.
The process is asked first and the buffer second: whether the buffer
is killed when the process dies is the terminal's own setting, and a
hand-off with neither left is over by any reading."
  (let* ((state (ecc-tui-state session))
         (process (plist-get state :process))
         (buffer (plist-get state :buffer)))
    (cond
     ((processp process) (not (process-live-p process)))
     ((bufferp buffer) (not (buffer-live-p buffer)))
     (t t))))

(defun ecc-tui--watch-process (session process)
  "Come back to SESSION as soon as PROCESS, its terminal, ends.
The sentinel the terminal installed is called first: it is what tears
down the terminal's own timers and kills its buffer."
  (let ((previous (process-sentinel process))
        (id (ecc-session-id session)))
    (set-process-sentinel
     process
     (lambda (proc event)
       (when previous (ignore-errors (funcall previous proc event)))
       (unless (process-live-p proc)
         (when-let* ((session (ecc-model-session id)))
           (when (and (ecc-tui-handoff-p session) ecc-tui-return-on-exit)
             ;; Out of the sentinel: taking the session back starts a
             ;; process and draws, and a sentinel is no place for that.
             (run-at-time 0 nil #'ecc-tui-return session))))))))

;;;###autoload
(defun ecc-tui-return (&optional session)
  "Take SESSION back from the terminal and run it in Emacs again (FR-TUI-4).
Whatever the terminal added is read first, so that nothing is missed,
and the session is then resumed headless.  A terminal that is still
running keeps the session: resuming it now would branch the
conversation."
  (interactive)
  (let ((session (or session (ecc-window-resolve-session))))
    (cond
     ;; Already back.
     ((process-live-p (ecc-session-process session))
      (ecc-tui-follow-stop session)
      (setf (ecc-session-kind session) 'own)
      session)
     ;; Somebody is still writing to this session.  The hand-off is left
     ;; as it is, so that the watch keeps looking and takes it back once
     ;; the terminal is really gone (FR-TUI-5).
     ((ecc-registry-live-p (ecc-session-id session))
      (message "%s is still open in a terminal" (ecc-session-name session))
      nil)
     (t
      (when (ecc-tui-handoff-p session)
        (when ecc-tui-follow (ecc-tui-read-new-lines session))
        (ecc-tui-follow-stop session))
      (setf (ecc-session-kind session) 'own)
      (require 'ecc-session)
      (ecc-session-ensure-buffer session)
      (ecc-proc-start session t)
      (message "%s is back in Emacs" (ecc-session-name session))
      session))))

(provide 'ecc-tui)

;;; ecc-tui.el ends here
